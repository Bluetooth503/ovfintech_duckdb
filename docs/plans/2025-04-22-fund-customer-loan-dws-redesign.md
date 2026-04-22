# 资金域客户贷款DWS层三层结构设计文档

**日期：** 2025-04-22
**作者：** Claude Code
**状态：** 待审批

---

## 一、背景与目标

### 1.1 现状问题

当前资金域DWS层存在以下问题：

1. **模型职责不清**：`dws_fund_customer_agg_df` 和 `dws_fund_customer_fund_snap_df` 功能高度重叠
2. **命名不统一**：主体粒度混乱（customer、customer_fund、customer_loan）
3. **依赖关系混乱**：部分模型依赖不存在的表（`dws_fund_loan_balance_snap_df`）
4. **重复计算**：相同指标在多个模型中重复计算

### 1.2 设计目标

1. **职责分离**：state（当前状态）、snap（历史快照）、agg（趋势分析）三层清晰定位
2. **命名统一**：统一使用 `customer_loan` 主体
3. **优化性能**：通过层级依赖减少重复计算
4. **易于维护**：明确的数据流向和依赖关系

### 1.3 使用场景

**主要场景：客户画像 + 历史分析 + 业务报表**

- **state**：客户维度表关联（判断是否贷款客户、授信额度等）
- **snap**：历史某天客户资金状态查询（如查询上季度末余额）
- **agg**：趋势分析、累计计算、年度汇总

---

## 二、模型设计

### 2.1 模型命名

| 新模型名 | 说明 | 替代旧模型 |
|---------|------|-----------|
| `dws_fund_customer_loan_state_df.sql` | 客户贷款当前状态表 | `dws_fund_customer_loan_balance_state_df.sql`（扩展） |
| `dws_fund_customer_loan_snap_df.sql` | 客户贷款历史快照表 | `dws_fund_customer_fund_snap_df.sql`（重命名） |
| `dws_fund_customer_loan_agg_df.sql` | 客户贷款汇总聚合表 | `dws_fund_customer_agg_df.sql`（重命名） |

### 2.2 三层定位对比

| 维度 | state_df | snap_df | agg_df |
|------|----------|---------|--------|
| **时间粒度** | 最新一天（T-1） | 完整历史时间序列 | 完整历史时间序列 |
| **保留历史** | ❌ 全量覆盖 | ✅ 保留历史 | ✅ 保留历史 |
| **主键** | customer_id | customer_id + stats_date | customer_id + stats_date |
| **更新策略** | 日全量覆盖 | 按日期追加 | 按日期追加 |
| **数据源** | DWD层直接计算 | 复用state逻辑扩展 | 从snap + DWD聚合 |
| **核心用途** | 客户画像关联、实时查询 | 历史状态查询、对账 | 趋势分析、累计计算 |

---

## 三、字段设计

### 3.1 state_df - 客户贷款当前状态表

**粒度：** customer_id（单客户最新状态）
**命名：** `dws_fund_customer_loan_state_df.sql`

```sql
-- 主键
customer_id                     -- 客户ID

-- 授信额度
total_credit_quota              -- 总授信额度
total_remain_quota              -- 总剩余额度
total_credit_used_quota         -- 总授信已用额度
credit_utilization_rate         -- 用信率（%）

-- 贷款余额（必须包含）
total_loan_balance              -- 总贷款余额
outstanding_promissory_note_cnt -- 在贷笔数
is_loan_customer                -- 是否贷款客户

-- 当日交易（T-1日）
last_daily_loan_amt            -- 最新日放款金额
last_daily_loan_cnt            -- 最新日放款笔数
last_daily_repay_amt           -- 最新日还款金额
last_daily_repay_cnt           -- 最新日还款笔数

-- 累计指标
cumulative_loan_amt            -- 累计放款金额
cumulative_repay_amt           -- 累计还款金额
year_cumulative_loan_amt       -- 年累计放款
year_cumulative_repay_amt      -- 年累计还款

-- 状态标识
has_active_loan                -- 是否有效贷款
last_transaction_date          -- 最后交易日期

-- 数仓字段
stats_date                     -- 统计日期（T-1）
dw_update_time                 -- 更新时间
```

**特点：**
- 轻量、快速、无历史
- 用于客户维度表关联
- 用于实时查询和风控判断

### 3.2 snap_df - 客户贷款历史快照表

**粒度：** customer_id + stats_date
**命名：** `dws_fund_customer_loan_snap_df.sql`

```sql
-- 主键
customer_id                     -- 客户ID
stats_date                     -- 统计日期

-- 授信额度
total_credit_quota              -- 总授信额度
total_remain_quota              -- 总剩余额度
total_credit_used_quota         -- 总授信已用额度

-- 贷款余额（完整历史快照）
total_loan_balance              -- 总贷款余额
outstanding_promissory_note_cnt -- 在贷笔数

-- 快照标识
is_loan_customer                -- 是否贷款客户
snapshot_type                  -- 快照类型（auto/manual）

-- 数仓字段
dw_update_time                 -- 更新时间
```

**特点：**
- 完整历史时间序列
- 用于历史状态查询
- 用于对账和审计
- 复用 state 的聚合逻辑

### 3.3 agg_df - 客户贷款汇总聚合表

**粒度：** customer_id + stats_date
**命名：** `dws_fund_customer_loan_agg_df.sql`

```sql
-- 主键
customer_id                     -- 客户ID
stats_date                     -- 统计日期

-- 当日汇总
daily_loan_amt                 -- 当日放款金额
daily_loan_cnt                 -- 当日放款笔数
daily_repay_amt                -- 当日还款金额
daily_repay_interest_amt       -- 当日还款利息
daily_repay_cnt                -- 当日还款笔数

-- 期末余额（来自snap）
total_loan_balance             -- 期末贷款余额
outstanding_promissory_note_cnt -- 期末在贷笔数

-- 余额变动
prev_loan_balance              -- 期初余额（昨日）
daily_balance_change           -- 余额变动额

-- 累计指标
cumulative_loan_amt            -- 累计放款金额
cumulative_repay_amt           -- 累计还款金额

-- 年度累计
year_cumulative_loan_amt       -- 年累计放款
year_cumulative_repay_amt      -- 年累计还款

-- 比率指标
utilization_rate               -- 用信率（%）
month_loan_growth_rate         -- 月度余额增长率

-- 数仓字段
dw_update_time                 -- 更新时间
```

**特点：**
- 包含累计和变动指标
- 用于趋势分析和报表
- 从 snap + 交易事实聚合计算

---

## 四、数据架构

### 4.1 依赖链路

```
DWD 层（事实表）
├── dwd_fund_credit_fact_i            （授信事实）
├── dwd_fund_promissory_note_fact_i   （借据事实）
└── dwd_fund_online_loan_fact_i       （交易事实）
    ↓
DWS 层（层级依赖）
    ├── dws_fund_customer_loan_state_df  （当前状态，T-1日）
    │   └── 特点：轻量、快速、无历史
    │       ↓
    ├── dws_fund_customer_loan_snap_df   （历史快照，时间序列）
    │   └── 依赖：复用 state 逻辑扩展历史范围
    │   └── 用途：任意历史日期的状态查询
    │       ↓
    └── dws_fund_customer_loan_agg_df    （汇总聚合，分析指标）
        └── 依赖：从 snap + DWD 交易事实聚合
        └── 用途：累计指标、趋势分析、年度汇总
```

### 4.2 更新顺序

```
1. state_df（最早，计算 T-1 日最新状态）
2. snap_df（从 state 逻辑扩展到完整历史）
3. agg_df（从 snap + 交易事实聚合计算）
```

### 4.3 计算逻辑概要

**state_df：**
```sql
SELECT
  customer_id,
  SUM(credit_quota) AS total_credit_quota,
  SUM(loan_balance) AS total_loan_balance,
  ...
FROM dwd_fund_credit_fact_i
WHERE credit_result = '1'
  AND trx_date <= CURRENT_DATE - 1  -- T-1日截止
GROUP BY customer_id
```

**snap_df：**
```sql
-- 复用 state 的聚合逻辑，扩展到完整历史时间范围
WITH all_dates AS (
  SELECT DISTINCT CAST(trx_date AS DATE) AS stats_date
  FROM dwd_fund_credit_fact_i
  WHERE trx_date >= '2020-01-01'
),
daily_state AS (
  -- 每天计算一次状态（复用 state 逻辑）
  SELECT
    customer_id,
    CAST(trx_date AS DATE) AS stats_date,
    SUM(credit_quota) AS total_credit_quota,
    SUM(loan_balance) AS total_loan_balance
  FROM dwd_fund_credit_fact_i
  WHERE credit_result = '1'
  GROUP BY customer_id, CAST(trx_date AS DATE)
)
SELECT * FROM daily_state
```

**agg_df：**
```sql
-- 从 snap 获取期末余额，从 DWD 获取当日交易，窗口函数计算累计
WITH snap_data AS (
  SELECT * FROM dws_fund_customer_loan_snap_df
),
daily_transaction AS (
  SELECT
    customer_id,
    CAST(trx_date AS DATE) AS stats_date,
    SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount END) AS daily_loan_amt
  FROM dwd_fund_online_loan_fact_i
  GROUP BY customer_id, CAST(trx_date AS DATE)
),
cumulative_calc AS (
  SELECT
    customer_id,
    stats_date,
    daily_loan_amt,
    SUM(daily_loan_amt) OVER (
      PARTITION BY customer_id ORDER BY stats_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_loan_amt,
    LAG(total_loan_balance) OVER (
      PARTITION BY customer_id ORDER BY stats_date
    ) AS prev_loan_balance
  FROM snap_data s
  LEFT JOIN daily_transaction t
    ON s.customer_id = t.customer_id AND s.stats_date = t.stats_date
)
SELECT * FROM cumulative_calc
```

---

## 五、实施策略

### 5.1 实施阶段

**阶段1：模型开发（第1-2周）**

1. **dws_fund_customer_loan_state_df**（优先级最高）
   - 从现有 `loan_balance_state` 扩展字段
   - 添加授信、交易、累计指标
   - 保留原表作为备份

2. **dws_fund_customer_loan_snap_df**
   - 复用 state 的聚合逻辑
   - 扩展到完整历史时间范围
   - 验证历史数据完整性

3. **dws_fund_customer_loan_agg_df**
   - 从 snap + 交易事实聚合计算
   - 添加累计和变动指标
   - 数据一致性校验

**阶段2：双写验证（第3-4周）**

- 新旧表并行运行
- 每日数据一致性校验
- 差异分析和修复

**阶段3：下游迁移（第5-6周）**

- 更新客户维度表关联
- 更新 ADS 层依赖
- 性能测试和优化

**阶段4：切换与清理（第7-8周）**

- 下游切换到新表
- 删除旧表和旧代码
- 文档更新

### 5.2 兼容性方案

**30天过渡期：**
- 旧表保留但标记为 `@deprecated`
- 新表正式提供服务
- 下游逐步迁移

**数据校验：**
```sql
-- 每日一致性校验
SELECT
  'state' AS table_name,
  COUNT(*) AS cnt,
  SUM(total_loan_balance) AS balance_sum
FROM dws_fund_customer_loan_state_df
UNION ALL
SELECT
  'old_state' AS table_name,
  COUNT(*) AS cnt,
  SUM(total_loan_balance) AS balance_sum
FROM dws_fund_customer_loan_balance_state_df
WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_loan_state_df)
```

### 5.3 下游影响

**受影响的模型：**
- 客户维度表：`dim_customer_member.sql`、`dim_customer_member_ranch_rel.sql`
- ADS层：客户相关 ADS 表

**迁移示例：**
```sql
-- 旧关联
LEFT JOIN dws_fund_customer_loan_balance_state_df lb
  ON lb.customer_id = customer.id

-- 新关联
LEFT JOIN dws_fund_customer_loan_state_df lb
  ON lb.customer_id = customer.id
```

---

## 六、风险评估

| 风险 | 影响 | 概率 | 缓解措施 |
|------|------|------|---------|
| 下游依赖失败 | 高 | 中 | 30天双写期，逐步迁移，保留回退方案 |
| 数据不一致 | 中 | 低 | 每日数据校验，差异告警，自动修复 |
| 性能下降 | 中 | 低 | snap/agg 表分区优化，索引优化 |
| 历史数据缺失 | 低 | 低 | 从 DWD 重新计算，备份数据 |
| 命名冲突 | 低 | 低 | 新表名不同，无冲突风险 |

---

## 七、预期收益

### 7.1 性能提升

- **state表查询性能提升 30%**：去除冗余字段，轻量化设计
- **历史查询速度提升 50%**：snap表独立索引优化
- **存储成本降低 20%**：去除重复字段，统一数据源

### 7.2 维护性提升

- **职责清晰**：三层各司其职，易于理解和维护
- **命名统一**：customer_loan主体明确，符合业务语义
- **依赖优化**：层级依赖，减少重复计算
- **扩展性强**：独立演进，互不影响

---

## 八、附录

### 8.1 命名规范

遵循项目命名规范：
```
{layer}_{domain}_{subject}_{table_type}_{update_mode}.sql
```

- `layer`：dws
- `domain`：fund（资金域）
- `subject`：customer_loan（客户贷款）
- `table_type`：state/snap/agg
- `update_mode`：df（日全量）

### 8.2 相关文档

- 项目命名规范：`CLAUDE.md`
- 资金域模型文档：`docs/fund/`
- 术语库：`glossary/`

---

**审批：**

[ ] 技术负责人
[ ] 数据仓库负责人
[ ] 业务负责人

**变更历史：**

| 日期 | 版本 | 变更内容 | 作者 |
|------|------|---------|------|
| 2025-04-22 | 1.0 | 初始版本 | Claude Code |
