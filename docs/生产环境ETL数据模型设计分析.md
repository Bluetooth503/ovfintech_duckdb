# 生产环境 ETL 数据模型设计分析

> 分析对象：海豚调度工作流导出结果（`/Users/enlai/02_光谷金信/059_海豚调度工作流_20260421`）
> 分析时间：2026-04-22

---

## 一、生产环境现状总览

| 指标 | 数值 |
|------|------|
| 工作流文件数 | 12 |
| 子流程数 | 159 |
| SQL 任务数 | 465 |
| 目标表（去重） | 207 |
| 涉及数据库（Schema） | 10 个 |
| 单 SQL 最大 JOIN 数 | 33 个 |
| 单 SQL 最大子查询嵌套 | 29 层 |
| 单 SQL 最大 UNION ALL 数 | 10 个 |

---

## 二、现有设计的优势

### 1. 初步具备分层意识

- 存在 `ods_` → `dwd_` → `dws_` → `ads_` 的命名前缀，说明团队理解数仓分层概念
- DWD 层表数量最多（154 张），承担了主要的清洗落地职责

### 2. 按业务域拆分工作流

- ranch（牧场）、fund（资金）、wms（仓储）、order（订单）等业务域有独立的工作流，隔离性尚可

### 3. 有分区处理意识

- 341/361 个有效 SQL 任务显式处理了分区（`dt=`、`partition`），说明对大数据量场景有基本认知

### 4. 增量/全量策略有区分

- `INSERT OVERWRITE`（全量）199 次，`INSERT INTO`（增量）94 次，说明有更新策略的区分

---

## 三、数据模型设计的核心劣势及痛点

### 1. 命名规范极度混乱 —— 数仓可维护性的最大杀手

**问题表现：**

- **同一工作流内多种后缀混用**，同一含义用不同词根表达：
  - `fund_workflow`：同时存在 `_1d_d`（日度）和 `_member_daily`（也是日度）
  - `wms_workflow`：同时存在 `_1d_d` 和 `_warehouse_daily`
  - `platform_workflow`：同时存在 `_1m_m`（月度）和 `_monthly_stats`（也是月度）
  - `ranch_workflow`：`_info_daily`、`_alert_record`、`_work_order` 等无规则后缀

- **55 张目标表落在 `default` 库中**，没有 Schema 隔离，如 `ads_rpt_ranch_1d_d`、`dwd_tts_order_info`

- **临时表/中间表无规范**：存在大量无分层前缀的表名

**带来的问题：**

- 新人无法从表名判断表的粒度、更新策略、业务含义
- 命名混乱导致无法建立统一的数据地图，找表靠口口相传
- 相似表无法快速识别，重复造轮子

---

### 2. 分层边界模糊，"跳层"现象严重 —— 分层形同虚设

**问题表现：**

| 违规类型 | 数量 | 典型示例 |
|---------|------|---------|
| ADS 直接查 DWD（跳层） | 12 处 | `ads_rpt_member_daily_facts_1d_d` 直接查 `dwd_invoice_relation_f_d` |
| DWD 依赖 DWS（反向） | 1 处 | `dwd_cattle_sample_weight_i_d` ← `dws_cattle_info_daily` |
| DWS 依赖 ADS（反向） | 3 处 | `dws_patrol_record_daily` ← `ads_rpt_ranch_1d_d` |

- **DWD 表被多个 ADS 直接消费**，缺乏 DWS 中间层收敛：
  - `dwd_mem_company_f_d` 被 4 个 ADS 直接消费
  - `dwd_customer_relation_f_d` 被 5 个 ADS 直接消费
  - `dwd_receipt_register_f_d` 被 4 个 ADS 直接消费

**带来的问题：**

- DWS 层没有起到"中间收敛"的作用，ADS 各自从 DWD 拉数，重复计算严重
- 底层 DWD 字段变更时，需要同时修改多个 ADS 任务，耦合度极高
- 33 个 JOIN、29 个子查询直接出现在 ADS 层 SQL 中，复杂逻辑全部下沉到报表层
- 违背了分层设计的核心目的：**复杂度应该在 DWS 层收敛，ADS 层只做轻量组装**

---

### 3. DWS 层设计极度薄弱 —— 中间层缺失

**问题表现：**

- DWS 层仅有 53 张表，远少于 DWD（154 张）和 ADS（97 张）
- DWS 表命名不统一：有的叫 `_daily`，有的叫 `_1d_d`
- 大量 ADS 报表直接基于 DWD 构建，DWS 成了"可有可无"的摆设

**带来的问题：**

- 每个 ADS 报表都从 DWD"从零开始"计算，同一指标在不同报表中计算逻辑可能不一致
- 计算资源浪费严重，同一中间结果被重复计算多次
- 指标口径无法统一管理，不同报表同一指标数值对不上时难以排查

---

### 4. 重复计算泛滥 —— 资源浪费和数据不一致的温床

**问题表现：**

- **552 对**高度相似（>85%）的 SQL 对
- **57 张表**被多个任务重复写入：
  - `ads_rpt_early_warn_1d_d` 被 **12 个不同任务** 分别 `INSERT INTO`（每个预警类型一个任务）
  - `dws_fund_member_daily` 被 **6 个任务** 写入
  - `ads_rpt_warehouse_1d_d` 被 **6 个任务** 写入
- 运营订单的日/周/月/年统计 SQL 相似度达 **99%**

**带来的问题：**

- 同一张表被多次覆盖/追加，存在数据覆盖风险和时序竞争
- 计算资源大量浪费（同一逻辑跑多遍）
- 指标变更时需要修改多处，极易遗漏导致口径不一致

---

### 5. ADS 层 SQL 过度复杂 —— 报表变成了"数据加工厂"

**问题表现：**

- `platform_prd.ads_rpt_member_daily_facts_1d_d` 一个 SQL 包含 **33 个 JOIN**
- `platform_prd.ads_market_operation_1d_d` 依赖 **23 个源表**
- 多个 ADS 报表包含 **10+ 个 UNION ALL**、**15+ 个子查询**

**带来的问题：**

- ADS 层 SQL 动辄几千行，调试和维护极其困难
- 报表开发门槛高，只有原开发者能修改
- 报表性能差（大量 JOIN 和子查询在一个 SQL 中执行）
- 报错时定位问题困难，一个字段错误需要排查 33 个 JOIN 链路

---

### 6. 缺乏统一维度设计 —— DIM 层完全缺失

**问题表现：**

- 分析发现 **DIM 层表数量为 0**
- 客户、仓库、商品等维度信息分散在多个 DWD 表中
- 每个 ADS 报表都自行 `LEFT JOIN` 客户信息、仓库信息，维度退化严重

**带来的问题：**

- 维度变更（如客户名称修改）需要修改所有引用该维度的 ADS 任务
- 维度属性在每个报表中重复计算，无法保证一致性
- 无法支持"维度变化追溯"（SCD）需求

---

### 7. 更新策略混乱 —— 数据一致性风险

**问题表现：**

- 4 张表同时混用 `INSERT OVERWRITE`（全量）和 `INSERT INTO`（增量）：
  - `ads_market_operation_1d_d`：OVERWRITE=1 次，INTO=5 次
  - `dws_order_outbound_detail`：OVERWRITE=1 次，INTO=1 次
- 分区格式不统一：有的用 `p_yyyyMMdd`，有的用其他格式

**带来的问题：**

- 同一张表既被全量覆盖又被增量追加，存在数据重复或丢失风险
- 任务执行时序一旦错乱，数据结果不可预期
- 无法明确判断一张表是"日快照"还是"日增量"

---

### 8. 数据血缘混乱 —— 溯源困难

**问题表现：**

- 任务名和实际目标表不一致：如 `dwd_tts_order_daily` 实际写入 `dws_tts_order_full`
- 存在大量"copy"流程（如 `ranch_workflow_copy_20251205171235994`），和原流程并存
- 同一张 DWD 表被多个 ADS 任务消费，但无中间层收敛

**带来的问题：**

- 数据出问题时无法快速溯源（从 ADS 找到 DWD 需要跨多个工作流）
- 无法评估变更影响范围（修改一个 DWD 字段不知道会影响多少报表）
- 存在"僵尸任务"（copy 流程和原流程同时跑，浪费资源）

---

### 9. 同名指标口径不一致 —— 数据可信度的致命伤

**问题表现：**

- 全系统共发现 **142 个聚合指标** 存在同名但计算口径不一致的情况
- **30+ 个核心指标** 的不同口径会直接导致不同报表数值冲突

**典型案例：在贷余额（`loan_balance`）—— 同名完全异义**

`loan_balance` 在 10 个目标表中出现，代表至少 **7 种完全不同的业务概念**：

| 编号 | 目标表 | 业务域 | 计算逻辑 | 实际含义 |
|------|--------|--------|---------|---------|
| A | `fund_prd.dws_fund_debt_daily` | fund | 直接取 `loan_balance` | 借据未还余额 |
| B-1 | `fund_prd.dws_fund_member_credit_daily` | fund | `sum(loan_balance)` | 按授信维度汇总借据余额 |
| B-2 | `fund_prd.dws_fund_member_credit_daily` | fund | `coalesce(on_loan.loan_balance, 0)` | 从借据明细关联取单个余额 |
| C | `fund_prd.dws_fund_member_offline_daily` | fund | `累计放款 - 累计还款` | 线下借贷的推算余额 |
| D | `order_prd.dws_order_member_daily` | order | `coalesce(loan_apply.loan_balance, 0)` | 预付申请的余额 |
| E-1 | `platform_prd.ads_rpt_early_warn_1d_d` | platform | `COALESCE(piaoju.loan_balance, 0)` | 预付订单的票据贷款余额 |
| E-2 | `platform_prd.ads_rpt_early_warn_1d_d` | platform | `loan_balance` | 应收账款的贷款余额 |
| F | `ads_rpt_ranch_1d_d` | ranch | `SUM(loan_amount)` | **直接等于放款金额** |
| G | `ads_rpt_ranch_install_1d_d` | ranch | `loan_amount` | **直接等于贷款金额** |
| H | `asset_pool_prd.dws_assets_info_change_daily` | asset_pool | `today.loan_balance` | 资产池视角的余额 |

**严重问题拆解：**

- **同一任务内口径不一致**：`dws_fund_member_credit_daily` 同一个任务中，`loan_balance` 在 UNION ALL 两边分别用 `sum()`（授信维度聚合）和 `coalesce()`（借据维度单个值），粒度不一致
- **同名完全异义**：fund 域是"借据未还余额"，order 域是"预付申请金额"，ranch 域直接等于"放款金额"——三个数值完全不在一个量级，但表头都叫"在贷余额"
- **逻辑错误**：ranch 域的 `loan_balance = SUM(loan_amount)`，如果已还款 30%，报表仍显示全额放款，与 fund 域的余额口径无法对比

**其他严重案例：**

| 指标名 | 不同口径数 | 核心差异 |
|--------|-----------|---------|
| `year_cumulative_lending` | 7 | 从零累加 vs 从累积值增量计算 vs 历史数据补数 |
| `repay_amount` | 7 | `repay_amount`/`repay_quota`/`loan_amount` 三个字段混用 |
| `goods_value` | 6 | `latest_price`/`current_price`/`market_value` 混用 |
| `inventory_charge_num` | 7 | 单位换算（KG→吨）有的做有的没做；撤销修正逻辑遗漏 |
| `camera_online_qty` | 5 | 对已聚合字段再 `sum()` 导致数值翻倍 |
| `agreement_new` | 2 | 从子查询取 vs 直接 `COUNT(*)` |

**带来的问题：**

- **业务失去信任**：不同报表同一指标数值不一致，业务方无法判断哪个正确
- **排查成本极高**：发现差异后需要逐条比对 SQL 的 JOIN 条件和 WHERE 过滤，耗时数天
- **指标无法复用**：没有指标定义中心，每个报表各自写 SQL，口径变更需要改 10+ 处

---

## 四、为什么要进行数仓重构？

### 现有架构的核心矛盾

> **分层有名无实**：虽然表名有 `dwd_`/`dws_`/`ads_` 前缀，但实际数据流是"蜘蛛网"式的——ADS 直接抓 DWD、DWD 反向依赖 DWS、同一张表被多个任务反复覆盖。分层没有起到"解耦"和"复用"的作用。

### 不进行重构将面临的后果

| 痛点 | 当前表现 | 未来风险 |
|------|---------|---------|
| **维护成本失控** | 33 JOIN 的 ADS 报表无人能改 | 原开发者离职后报表无法迭代 |
| **口径不一致** | 142 个指标同名异义，`loan_balance` 有 7 种口径 | 同一指标在不同报表数值冲突，业务失去信任 |
| **资源浪费** | 57 张表被多任务重复写入 | 集群计算成本持续攀升 |
| **数据质量差** | 混用 OVERWRITE/INTO、反向依赖 | 数据丢失/重复难以排查，决策风险高 |
| **新人上手难** | 207 张表命名混乱、血缘不清 | 团队扩展困难，交付效率低下 |

### 重构带来的核心价值

1. **命名规范化**：统一 `layer_domain_subject_type_updatemode` 命名体系，从表名即可读取出粒度、策略、含义
2. **分层真正落地**：严格 `ODS→DWD→DWS→ADS`，ADS 只从 DWS 取数，复杂度在 DWS 收敛
3. **DWS 中间层强化**：将公共汇总逻辑沉淀为可复用的 DWS 表，消除 552 对重复 SQL
4. **指标统一管理**：建立指标定义层，同一指标（如在贷余额）在 DWS 层统一定义，ADS 层只引用不复写，根除 142 个同名异义指标
5. **维度统一**：建立 DIM 层，客户/仓库/商品等维度统一管理，变更一处全局生效
6. **血缘清晰**：每个模型有明确的单向上游，修改影响范围可评估
7. **可维护性**：ADS 层 SQL 回归"轻量组装"，单 SQL JOIN 数控制在 5 个以内

---

## 五、总结

生产环境的海豚调度工作流在**宏观上有分层的概念、按业务域隔离的意识**，这是其优势。但在**数据模型设计的微观层面**，存在**命名混乱、分层跳层、DWS 缺失、重复计算、SQL 过度复杂、维度退化、更新策略混乱、同名指标口径不一致**等严重问题。这些问题不是调度工具的问题，而是**数据模型设计层面的系统性债务**。

数仓重构的核心目的不是换一个调度工具，而是**重新定义数据模型规范、重建分层边界、消除重复计算、统一维度设计**，让数据仓库从"能跑"变成"好管、好用、可信"。
