# 饲料相关 DWS 层模型设计方案

> 参考文档：《中国牛只饲养业务数据分析专题规划报告》专题三：饲料成本优化分析
>
> 设计目标：新建饲料相关 DWS 层数据模型，同时支撑专题三的饲料成本优化分析，以及牛只生长 NLME 饲料维度分析（方案 C + 架构 B）

---

## 一、设计背景

现有数据仓库中，饲料数据分散在多个层级：

- **ODS 层**：`ods_psi_cattle_feed_detail_*`（牛只日投喂明细）、`ods_psi_livestock_consume`（栏舍日消耗计划与实际）、`ods_psi_recipe`（配方定义）、`ods_psi_commodity`（商品主数据）
- **DWD 层**：`dwd_ranch_cattle_feed_trx_i`（牛只投喂事务明细）
- **DWS 层**：`dws_ranch_cattle_adg_agg_i` 中已包含区间饲料消耗总量和料肉比，但**缺少饲料结构分层**（精料/粗料/添加剂/药品）和**配方关联信息**
- **DWS 层**：`dws_ranch_stall_performance_agg_1d_d` 中已包含栏舍日饲料成本和料肉比，但**缺少投喂计划完成率、剩料率、饲料结构分层**

因此，需要新建 3 张 DWS 表，分别面向：
1. **牛只生长分析**（NLME 第二阶段）
2. **栏舍运营效率分析**（投喂执行监控）
3. **配方效果评估分析**（配方降本增效）

---

## 二、模型总览

| 模型名称 | 粒度 | 更新策略 | 核心用途 |
|---------|------|---------|---------|
| `dws_ranch_cattle_feed_breakdown_agg_i` | 牛只 × 称重区间 | 增量追加 | **NLME 饲料维度分析**、个体饲料画像 |
| `dws_ranch_stall_feed_daily_agg_1d_d` | 栏舍 × 日期 | 增量追加 | **栏舍投喂执行监控**、计划完成率/剩料率分析 |
| `dws_ranch_recipe_performance_agg_1m_m` | 配方 × 月度 | 增量追加 | **配方效果评估**、料肉比/单位增重成本对标 |

---

## 三、模型一：dws_ranch_cattle_feed_breakdown_agg_i

### 3.1 模型定位

**牛只饲料结构区间汇总表（增量）**，与 `dws_ranch_cattle_adg_agg_i` 保持相同粒度（牛只 × 称重区间），但侧重于**饲料组成结构**和**配方关联**，是 NLME 第二阶段回归分析的核心输入。

### 3.2 数据来源

- 主数据：`dwd_ranch_cattle_feed_trx_i`（牛只投喂明细）
- 称重区间：`dws_ranch_cattle_adg_agg_i` 或 `dwd_ranch_cattle_weight_trx_i` 的区间定义
- 饲料分类：`ods_psi_commodity`（按 `type` + 名称关键词分类）
- 栏舍配方：`ods_ranch_stall`（`recipe_id`, `recipe_name`）
- 理论配方：`ods_psi_recipe`（按 `commodity_id` + 体重区间匹配）

### 3.3 饲料分类规则

基于 `ods_psi_commodity` 字段，将饲料商品划分为 5 大类：

| 分类 | 判定条件 | 示例 |
|------|---------|------|
| **精料** | `type=2` 且名称含"浓缩料""精料""玉米""豆粕" | 西门塔尔育肥浓缩料、育成精料 |
| **粗料** | `type=2` 且名称含"稻草""青贮""秸秆""干草""苜蓿" | 稻草、啤酒糟 |
| **添加剂** | `type=2` 且名称含"小苏打""益生菌""舔砖""预混料" | 小苏打、益生菌 |
| **药品** | `type=3` | 安乃近、氟苯尼考 |
| **其他** | 未匹配上的商品 | 兜底分类 |

> 分类规则以映射字典形式维护，便于后续根据业务需求调整。

### 3.4 核心字段设计

#### 标识维度

| 字段名 | 说明 |
|--------|------|
| `stats_date` | 统计日期（本次称重日期） |
| `cattle_id` | 牛只 ID |
| `stall_id` | 栏舍 ID |
| `ranch_id` | 牧场 ID |
| `customer_id` | 投资方 ID |
| `sku_id` | 品种 ID |
| `prev_weight_date` | 上次称重日期 |
| `interval_days` | 称重间隔天数 |

#### 饲料消耗总量

| 字段名 | 说明 |
|--------|------|
| `period_feed_consumption` | 区间饲料总消耗量 |
| `period_feed_cost` | 区间饲料总成本 |
| `period_avg_feed_intake` | 日均饲料摄入量 = 总消耗 / 间隔天数 |
| `period_avg_feed_cost_per_day` | 日均饲料成本 = 总成本 / 间隔天数 |
| `period_feed_unit_price` | 饲料平均单价 = 总成本 / 总消耗 |

#### 饲料结构分层（核心）

| 字段名 | 说明 |
|--------|------|
| `period_concentrate_qty` | 精料消耗量 |
| `period_roughage_qty` | 粗料消耗量 |
| `period_additive_qty` | 添加剂消耗量 |
| `period_medicine_qty` | 药品消耗量 |
| `period_other_qty` | 其他饲料消耗量 |
| `period_concentrate_cost` | 精料成本 |
| `period_roughage_cost` | 粗料成本 |
| `period_additive_cost` | 添加剂成本 |
| `period_medicine_cost` | 药品成本 |
| `period_other_cost` | 其他饲料成本 |

#### 饲料结构占比

| 字段名 | 说明 |
|--------|------|
| `concentrate_ratio` | 精料占比 = 精料量 / 总饲料量 |
| `roughage_ratio` | 粗料占比 = 粗料量 / 总饲料量 |
| `additive_ratio` | 添加剂占比 = 添加剂量 / 总饲料量 |
| `medicine_ratio` | 药品占比 = 药品量 / 总饲料量 |
| `feed_cost_per_kg_gain` | 单位增重饲料成本 = 总饲料成本 / 区间增重 |

#### 配方关联信息

| 字段名 | 说明 |
|--------|------|
| `stall_recipe_id` | 栏舍当前绑定配方 ID（来自 `ods_ranch_stall`） |
| `stall_recipe_name` | 栏舍当前绑定配方名称 |
| `matched_recipe_id` | 理论匹配配方 ID（按品种 + 当前体重匹配 `ods_psi_recipe`） |
| `matched_recipe_name` | 理论匹配配方名称 |
| `recipe_target_fcr` | 理论配方目标料肉比 |
| `recipe_match_flag` | 配方匹配标记（1=实际配方与理论配方一致，0=不一致） |

### 3.5 业务价值

- **NLME 第二阶段输入**：通过 `cattle_id` 关联 NLME 估计出的个体参数 `A/B/C`，用上述饲料结构特征做回归，回答"精粗比如何影响生长潜力"
- **个体饲料画像**：为每头牛构建全生命周期的饲料摄入画像，支撑精准饲养策略优化

---

## 四、模型二：dws_ranch_stall_feed_daily_agg_1d_d

### 4.1 模型定位

**栏舍饲料投喂日汇总表（增量）**，粒度为栏舍 × 日期，核心支撑专题三中的"投喂执行监控"和"栏舍运营效率分析"。

### 4.2 数据来源

- 栏舍日消耗计划与实际：`ods_psi_livestock_consume`（`plan_day_consume`, `act_day_consume`）
- 栏舍在栏牛只数：`dws_ranch_cattle_snapshot_1d_d` 或 `dws_ranch_stall_capacity_agg_1d_d`
- 饲料分类：`ods_psi_commodity`
- 栏舍配方：`ods_ranch_stall`

### 4.3 核心字段设计

#### 标识维度

| 字段名 | 说明 |
|--------|------|
| `stats_date` | 统计日期 |
| `ranch_id` | 牧场 ID |
| `ranch_name` | 牧场名称 |
| `stall_id` | 栏舍 ID |
| `stall_name` | 栏舍名称 |
| `recipe_id` | 栏舍绑定配方 ID |
| `recipe_name` | 栏舍绑定配方名称 |
| `natural_week` | 自然周 |
| `natural_month` | 自然月 |

#### 在栏规模

| 字段名 | 说明 |
|--------|------|
| `total_cattle_count` | 当日在栏牛只数 |
| `system_cattle_num` | 栏舍设计容量 |
| `capacity_utilization_rate` | 容量利用率 = 在栏数 / 设计容量 |

#### 投喂执行指标（核心）

| 字段名 | 说明 |
|--------|------|
| `plan_feed_quantity` | 日计划投喂总量（来自 `plan_day_consume` 汇总） |
| `act_feed_quantity` | 日实际投喂总量（来自 `act_day_consume` 汇总） |
| `feed_plan_completion_rate` | 投喂计划完成率 = 实际 / 计划 |
| `leftover_quantity` | 剩料量 = 计划 - 实际（仅当计划 > 实际时） |
| `leftover_rate` | 剩料率 = 剩料量 / 计划量 |

> **数据说明**：`ods_psi_livestock_consume` 的粒度是 `stall_id` + `recipe_id` + `commodity_id` + `consume_date`，计划完成率需要在商品维度汇总后计算。

#### 饲料消耗结构

| 字段名 | 说明 |
|--------|------|
| `total_feed_cost` | 日饲料总成本 |
| `concentrate_quantity` | 日精料消耗量 |
| `roughage_quantity` | 日粗料消耗量 |
| `additive_quantity` | 日添加剂消耗量 |
| `medicine_quantity` | 日药品消耗量 |
| `concentrate_ratio` | 日精料占比 |
| `avg_feed_intake_per_cattle` | 头均日采食量 = 实际总量 / 在栏牛只数 |
| `avg_feed_cost_per_cattle` | 头均日饲料成本 = 总成本 / 在栏牛只数 |

#### 效率指标

| 字段名 | 说明 |
|--------|------|
| `feed_unit_price` | 当日饲料平均单价 = 总成本 / 实际总量 |
| `recipe_switch_flag` | 当日是否切换配方（与昨日 `recipe_id` 对比） |

### 4.4 业务价值

- **投喂异常预警**：当 `feed_plan_completion_rate` 偏离 100% 超过阈值（如 ±10%）或 `leftover_rate` 过高时触发预警
- **栏舍成本监控**：追踪每日栏舍饲料成本波动，识别异常高成本栏舍
- **执行质量评估**：量化不同栏舍、不同饲养员的投喂执行偏差

---

## 五、模型三：dws_ranch_recipe_performance_agg_1m_m

### 5.1 模型定位

**配方效果评估月汇总表（增量）**，粒度为配方 × 月度，核心支撑专题三中的"配方效率分析"和"配方降本增效决策"。

### 5.2 数据来源

- 配方定义：`ods_psi_recipe`
- 栏舍配方绑定：`ods_ranch_stall`
- 牛只生长绩效：`dws_ranch_cattle_adg_agg_i`
- 饲料消耗：`dws_ranch_cattle_feed_breakdown_agg_i` 或 `dwd_ranch_cattle_feed_trx_i`
- 栏舍日消耗：`dws_ranch_stall_feed_daily_agg_1d_d`

### 5.3 核心字段设计

#### 标识维度

| 字段名 | 说明 |
|--------|------|
| `stats_month` | 统计月份 |
| `recipe_id` | 配方 ID |
| `recipe_name` | 配方名称 |
| `sku_id` | 配方对应品种 ID（来自 `ods_psi_recipe.commodity_id`） |
| `sku_name` | 品种名称 |

#### 使用规模

| 字段名 | 说明 |
|--------|------|
| `stall_count` | 使用该配方的栏舍数（月末在绑定的栏舍） |
| `cattle_count` | 使用该配方的牛只数（月末在对应栏舍的牛只） |
| `cattle_count_avg` | 月均牛只数 |
| `recipe_switch_in_count` | 当月切换至该配方的栏舍数 |
| `recipe_switch_out_count` | 当月从该配方切换走的栏舍数 |

#### 生长绩效

| 字段名 | 说明 |
|--------|------|
| `total_weight_gain` | 当月总增重（使用该配方的牛只区间增重汇总） |
| `avg_period_adg` | 平均区间 ADG |
| `avg_overall_adg` | 平均整体 ADG |
| `weight_gain_per_stall` | 单栏舍月均增重 = 总增重 / 栏舍数 |

#### 饲料消耗

| 字段名 | 说明 |
|--------|------|
| `total_feed_consumption` | 当月总饲料消耗量 |
| `total_feed_cost` | 当月总饲料成本 |
| `avg_feed_intake_per_cattle_per_day` | 头均日采食量 |
| `avg_feed_cost_per_cattle_per_day` | 头均日饲料成本 |

#### 配方效率指标（核心）

| 字段名 | 说明 |
|--------|------|
| `actual_fcr` | 实际料肉比 = 总饲料消耗 / 总增重 |
| `target_fcr` | 配方目标料肉比（来自 `ods_psi_recipe.feed_meat_ratio`） |
| `fcr_deviation` | 料肉比偏差 = 实际料肉比 - 目标料肉比 |
| `feed_cost_per_kg_gain` | 单位增重成本 = 总饲料成本 / 总增重 |
| `cost_efficiency_index` | 成本效率指数 = 目标料肉比 / 实际料肉比（>1 表示优于目标） |

#### 饲料结构

| 字段名 | 说明 |
|--------|------|
| `concentrate_ratio_avg` | 平均精料占比 |
| `roughage_ratio_avg` | 平均粗料占比 |
| `additive_ratio_avg` | 平均添加剂占比 |
| `medicine_ratio_avg` | 平均药品占比 |

### 5.4 业务价值

- **配方性价比排名**：按月输出各配方的 `actual_fcr` 和 `feed_cost_per_kg_gain` 排名，识别高性价比配方
- **配方优化方向**：通过 `fcr_deviation` 发现实际表现与理论目标差距较大的配方，推动配方调整
- **配方 A/B 测试**：当牧场尝试新配方时，通过该表对比新旧配方的生长绩效和成本差异

---

## 六、数据血缘关系

```
ods_psi_cattle_feed_detail_* ──┐
ods_psi_commodity ─────────────┼──► dwd_ranch_cattle_feed_trx_i ───┐
                               │                                  │
                               │    ┌─────────────────────────────┘
                               │    ▼
                               │  dws_ranch_cattle_feed_breakdown_agg_i
                               │    （牛只×称重区间饲料结构）
                               │         │
                               │         ├────────► 支撑 NLME 第二阶段分析
                               │         │
                               │         ▼
                               │  dws_ranch_recipe_performance_agg_1m_m
                               │    （配方×月度效果评估）
                               │
ods_psi_livestock_consume ─────┤
ods_ranch_stall ───────────────┼──► dws_ranch_stall_feed_daily_agg_1d_d
dws_ranch_cattle_snapshot_1d_d─┘    （栏舍×日期投喂执行）
```

---

## 七、实施路径

| 阶段 | 周期 | 关键任务 | 产出 |
|------|------|---------|------|
| **第 1 周** | 数据准备 | 完成 `ods_psi_commodity` 饲料分类映射字典；梳理 `ods_psi_livestock_consume` 与现有模型的关联逻辑 | 分类字典定稿 |
| **第 2 周** | 模型一开发 | 开发 `dws_ranch_cattle_feed_breakdown_agg_i`，完成饲料结构分层聚合和配方关联 | 模型一上线 |
| **第 3 周** | 模型二三开发 | 开发 `dws_ranch_stall_feed_daily_agg_1d_d` 和 `dws_ranch_recipe_performance_agg_1m_m` | 模型二三上线 |
| **第 4 周** | 验证与打通 | 验证三张表的数据质量；与 `dws_ranch_cattle_adg_agg_i` 和 NLME 模型打通 | 全链路跑通 |

---

## 八、关键注意事项

### 8.1 饲料分类准确性

`ods_psi_commodity` 中部分饲料商品名称存在不规范或缺失问题。建议：
- 建立可维护的**饲料分类关键词映射表**，作为 DIM 层补充
- 对未匹配的商品定期review，避免大量归入"其他"类导致信息损失

### 8.2 配方匹配的时效性

`ods_ranch_stall` 中的 `recipe_id` 是栏舍的"当前绑定配方"，可能存在历史时点不准确的问题。建议：
- 短期方案：按称重日期取当天的栏舍配方（假设 `ods_ranch_stall` 为最新快照，历史配方无法追溯）
- 长期方案：若业务系统有配方变更日志，应构建 `dim_stall_recipe_history` SCD Type 2 维度表

### 8.3 计划完成率的计算口径

`ods_psi_livestock_consume` 的 `plan_day_consume` 和 `act_day_consume` 是**商品级别**的粒度。计算栏舍级计划完成率时，建议：
- 分母 = 当日该栏舍所有商品的 `plan_day_consume` 之和
- 分子 = 当日该栏舍所有商品的 `act_day_consume` 之和
- 当 `plan_day_consume = 0` 时，标记为"无计划"，不纳入完成率统计

### 8.4 与现有模型的兼容

`dws_ranch_cattle_adg_agg_i` 和 `dws_ranch_stall_performance_agg_1d_d` 现有指标（如 `period_feed_consumption`、`total_feed_cost`）应与新建模型保持**计算口径一致**，避免出现同一指标在不同表中数值不一致的情况。

---

## 九、总结

本方案设计了 3 张饲料相关 DWS 表，形成了"**个体 → 栏舍 → 配方**"的三级饲料分析体系：

- **`dws_ranch_cattle_feed_breakdown_agg_i`**：向下穿透到每头牛的饲料结构和配方匹配，**直接支撑 NLME 饲料维度分析**
- **`dws_ranch_stall_feed_daily_agg_1d_d`**：聚焦栏舍级投喂执行质量，**支撑专题三的栏舍运营效率监控**
- **`dws_ranch_recipe_performance_agg_1m_m`**：上升到配方级别的成本效益评估，**支撑专题三的配方优化决策**

三张表之间通过 `cattle_id` → `stall_id` → `recipe_id` 的血缘关联，构成了饲料成本优化分析的完整数据底座。
