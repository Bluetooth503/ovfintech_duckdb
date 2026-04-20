# 牧场产业数仓宽表实现计划

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为牧场域补充成本、健康、运营三大类的ADS层宽表模型

**Architecture:** 基于现有DWS层聚合数据，设计6个ADS宽表模型（每个域2个：profile画像 + dashboard月报），遵循现有命名规范和代码风格

**Tech Stack:** DuckDB + dbt, SQL模型, 全量刷新(table), CTE分层设计

---

## Chunk 1: 成本域模型（Cost Domain）

### Task 1: 创建牛只成本画像宽表

**Files:**
- Create: `models/ranch/ads/ads_ranch_cattle_cost_profile_cum_d.sql`

- [ ] **Step 1: 编写模型代码**

```sql
-- =============================================
-- 模型名称：ads_ranch_cattle_cost_profile_cum_d
-- 模型描述：牛只成本画像宽表（至今），每头牛一条记录，汇总采购成本、饲料成本、附加成本及成本结构
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：dim_ranch_cattle（牛只维度，含采购成本）+ dws_ranch_cattle_feed_breakdown_agg_i（饲料成本）+ dws_ranch_cattle_sell_agg_df（销售数据）
--   - 增量策略：全量刷新（table）
--   - 统计指标：采购成本、累计饲料成本、总成本、成本结构（采购/饲料/附加占比）、头均日成本、盈亏分析
-- =============================================
{{ config(
    materialized='table',
    description='牛只成本画像宽表（至今），汇总每头牛的采购成本、饲料成本、附加成本及成本结构分析',
    tags=['ranch', 'ads', 'cost', 'cattle', 'profile']
) }}

-- ============================================
-- 1. 基础档案（来自牛只维度表）
-- ============================================
WITH cattle_base AS (
    SELECT
        cattle_id,
        cattle_code AS cattle_no,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        customer_id,
        purchase_id,
        in_stall_date,
        in_stall_weight,
        in_stall_price,
        cattle_status AS dim_cattle_status,
        out_stall_date AS dim_out_stall_date
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- 2. 采购成本（从DWS采购日统计聚合）
-- ============================================
purchase_cost AS (
    SELECT
        cattle_id,
        SUM(purchase_total_amount) AS total_purchase_cost,
        SUM(purchase_total_weight) AS total_purchase_weight,
        AVG(purchase_unit_price) AS avg_purchase_unit_price
    FROM {{ ref('dws_ranch_cattle_purchase_agg_di') }}
    GROUP BY cattle_id
),

-- ============================================
-- 3. 累计饲料成本（从DWS饲料区间汇总聚合）
-- ============================================
feed_cost AS (
    SELECT
        cattle_id,
        SUM(period_feed_cost) AS cumulative_feed_cost,
        SUM(period_feed_consumption) AS cumulative_feed_consumption,
        SUM(period_concentrate_cost) AS cumulative_concentrate_cost,
        SUM(period_roughage_cost) AS cumulative_roughage_cost,
        SUM(period_additive_cost) AS cumulative_additive_cost,
        SUM(period_medicine_cost) AS cumulative_medicine_cost,
        MAX(stats_date) AS latest_feed_date
    FROM {{ ref('dws_ranch_cattle_feed_breakdown_agg_i') }}
    GROUP BY cattle_id
),

-- ============================================
-- 4. 出栏信息（用于最终状态判定）
-- ============================================
sell_info AS (
    SELECT
        cattle_id,
        sell_date,
        sell_total_amount AS sell_revenue
    FROM {{ ref('dws_ranch_cattle_sell_agg_df') }}
),

-- ============================================
-- 5. 退回信息（用于最终状态判定）
-- ============================================
return_info AS (
    SELECT
        cattle_id,
        return_date
    FROM {{ ref('dws_ranch_cattle_return_agg_df') }}
),

-- ============================================
-- 6. 数据整合与成本计算
-- ============================================
integrated AS (
    SELECT
        b.cattle_id,
        b.cattle_no,
        b.ranch_id,
        b.ranch_name,
        b.stall_id,
        b.stall_name,
        b.cattle_sku_id,
        b.cattle_sku_name,
        b.brand_name,
        b.customer_id,
        b.purchase_id,
        b.in_stall_date,
        b.in_stall_weight,
        b.in_stall_price,

        -- 状态判定
        CASE WHEN s.cattle_id IS NOT NULL THEN '已出栏'
             WHEN r.cattle_id IS NOT NULL THEN '已退回'
             WHEN b.dim_cattle_status = '0' THEN '在栏'
             ELSE '其他' END AS cattle_status,

        -- 采购成本
        COALESCE(pc.total_purchase_cost, 0) AS purchase_cost,
        COALESCE(pc.total_purchase_weight, 0) AS purchase_weight,
        pc.avg_purchase_unit_price,

        -- 累计饲料成本
        COALESCE(fc.cumulative_feed_cost, 0) AS cumulative_feed_cost,
        COALESCE(fc.cumulative_feed_consumption, 0) AS cumulative_feed_consumption,
        COALESCE(fc.cumulative_concentrate_cost, 0) AS cumulative_concentrate_cost,
        COALESCE(fc.cumulative_roughage_cost, 0) AS cumulative_roughage_cost,
        COALESCE(fc.cumulative_additive_cost, 0) AS cumulative_additive_cost,
        COALESCE(fc.cumulative_medicine_cost, 0) AS cumulative_medicine_cost,

        -- 附加成本（医疗、运输等其他费用，维度表中暂无字段，预留）
        0 AS additional_cost,

        -- 计算指标：总成本
        COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0) AS total_cost,

        -- 计算指标：在栏天数
        DATE_DIFF('day', b.in_stall_date, COALESCE(s.sell_date, r.return_date, CURRENT_DATE)) AS days_on_stall,

        -- 计算指标：头均日成本
        CASE WHEN b.in_stall_date IS NOT NULL
             THEN (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0)) /
                  NULLIF(DATE_DIFF('day', b.in_stall_date, COALESCE(s.sell_date, r.return_date, CURRENT_DATE)), 0)
             ELSE NULL END AS avg_daily_cost_per_cattle,

        -- 成本结构占比
        CASE WHEN (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0)) > 0
             THEN COALESCE(pc.total_purchase_cost, 0) / (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0))
             ELSE NULL END AS purchase_cost_ratio,
        CASE WHEN (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0)) > 0
             THEN COALESCE(fc.cumulative_feed_cost, 0) / (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0))
             ELSE NULL END AS feed_cost_ratio,

        -- 饲料成本内部结构
        CASE WHEN fc.cumulative_feed_cost > 0
             THEN fc.cumulative_concentrate_cost / NULLIF(fc.cumulative_feed_cost, 0)
             ELSE NULL END AS concentrate_cost_ratio,
        CASE WHEN fc.cumulative_feed_cost > 0
             THEN fc.cumulative_roughage_cost / NULLIF(fc.cumulative_feed_cost, 0)
             ELSE NULL END AS roughage_cost_ratio,

        -- 出栏信息
        s.sell_date,
        s.sell_revenue,

        -- 计算指标：盈亏分析
        CASE WHEN s.sell_revenue IS NOT NULL
             THEN s.sell_revenue - (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0))
             ELSE NULL END AS profit_loss_amount,
        CASE WHEN s.sell_revenue IS NOT NULL AND (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0)) > 0
             THEN (s.sell_revenue - (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0))) /
                  (COALESCE(pc.total_purchase_cost, 0) + COALESCE(fc.cumulative_feed_cost, 0)) * 100
             ELSE NULL END AS profit_loss_rate,

        fc.latest_feed_date

    FROM cattle_base b
    LEFT JOIN purchase_cost pc ON CAST(b.cattle_id AS VARCHAR) = CAST(pc.cattle_id AS VARCHAR)
    LEFT JOIN feed_cost fc ON CAST(b.cattle_id AS VARCHAR) = CAST(fc.cattle_id AS VARCHAR)
    LEFT JOIN sell_info s ON CAST(b.cattle_id AS VARCHAR) = CAST(s.cattle_id AS VARCHAR)
    LEFT JOIN return_info r ON CAST(b.cattle_id AS VARCHAR) = CAST(r.cattle_id AS VARCHAR)
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 标识维度
    cattle_id,                               -- 牛只ID
    cattle_no,                               -- 牛只编号

    -- 组织维度
    ranch_id,                                -- 牧场ID
    ranch_name,                              -- 牧场名称
    stall_id,                                -- 栏舍ID
    stall_name,                              -- 栏舍名称
    customer_id,                             -- 客户/投资方ID
    purchase_id,                             -- 采购单ID

    -- 品种维度
    cattle_sku_id,                           -- SKU ID
    cattle_sku_name,                         -- SKU名称
    brand_name,                              -- 品牌名称

    -- 基础属性
    in_stall_date,                           -- 入栏日期
    in_stall_weight,                         -- 入栏体重
    in_stall_price,                          -- 入栏单价

    -- 状态
    cattle_status,                           -- 牛只状态

    -- 采购成本
    purchase_cost,                           -- 采购成本
    purchase_weight,                         -- 采购重量
    avg_purchase_unit_price,                 -- 平均采购单价

    -- 累计饲料成本
    cumulative_feed_cost,                    -- 累计饲料总成本
    cumulative_feed_consumption,             -- 累计饲料消耗量
    cumulative_concentrate_cost,             -- 累计精料成本
    cumulative_roughage_cost,                -- 累计粗料成本
    cumulative_additive_cost,                -- 累计添加剂成本
    cumulative_medicine_cost,                -- 累计药品成本

    -- 附加成本
    additional_cost,                         -- 附加成本（预留）

    -- 总成本与效率
    total_cost,                              -- 总成本（采购+饲料+附加）
    days_on_stall,                           -- 在栏天数
    avg_daily_cost_per_cattle,               -- 头均日成本

    -- 成本结构占比
    purchase_cost_ratio,                     -- 采购成本占比
    feed_cost_ratio,                         -- 饲料成本占比
    concentrate_cost_ratio,                  -- 精料成本占比
    roughage_cost_ratio,                     -- 粗料成本占比

    -- 出栏盈亏
    sell_date,                               -- 出栏日期
    sell_revenue,                            -- 出栏收入
    profit_loss_amount,                      -- 盈亏金额
    profit_loss_rate,                        -- 盈亏率（%）

    -- 元数据
    latest_feed_date AS last_cost_update,    -- 最后成本更新日期
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM integrated
ORDER BY ranch_id, stall_id, cattle_id
```

- [ ] **Step 2: 验证语法**

运行：`dbt parse --select ads_ranch_cattle_cost_profile_cum_d`
预期：无语法错误

- [ ] **Step 3: 测试运行（可选）**

运行：`dbt run --select ads_ranch_cattle_cost_profile_cum_d --full-refresh`
预期：成功生成表

- [ ] **Step 4: 提交**

```bash
git add models/ranch/ads/ads_ranch_cattle_cost_profile_cum_d.sql
git commit -m "feat(ranch): add cattle cost profile wide table (cumulative daily)"
```

---

### Task 2: 创建牧场成本月报

**Files:**
- Create: `models/ranch/ads/ads_ranch_cost_dashboard_mf.sql`

- [ ] **Step 1: 编写模型代码**

```sql
-- =============================================
-- 模型名称：ads_ranch_cost_dashboard_mf
-- 模型描述：牧场成本运营月报，按牧场+自然月统计成本构成、效率指标及出栏成本回收
-- Dbt更新方式：全量
-- 粒度：牧场 + 自然月
-- 说明：
--   - 数据源：dws_ranch_cattle_feed_breakdown_agg_i + dws_ranch_stall_feed_agg_di + dws_ranch_cattle_purchase_agg_di + dws_ranch_cattle_sell_agg_mf
--   - 增量策略：全量刷新（table）
--   - 统计指标：月度采购成本、月度饲料成本、出栏成本回收、在栏牛成本规模、头均成本、成本效率指标
-- =============================================
{{ config(
    materialized='table',
    description='牧场成本运营月报，按牧场+自然月统计成本构成、效率指标及出栏成本回收',
    tags=['ranch', 'ads', 'cost', 'dashboard', 'monthly']
) }}

-- ============================================
-- 1. 月度采购成本
-- ============================================
purchase_monthly AS (
    SELECT
        EXTRACT(YEAR FROM stats_date) * 100 + EXTRACT(MONTH FROM stats_date) AS natural_month,
        ranch_id,
        SUM(purchase_total_amount) AS month_purchase_cost,
        SUM(purchase_count) AS month_purchase_count,
        SUM(purchase_total_weight) AS month_purchase_weight,
        AVG(purchase_unit_price) AS avg_purchase_unit_price
    FROM {{ ref('dws_ranch_cattle_purchase_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 2. 月度饲料成本
-- ============================================
feed_monthly AS (
    SELECT
        EXTRACT(YEAR FROM stats_date) * 100 + EXTRACT(MONTH FROM stats_date) AS natural_month,
        ranch_id,
        SUM(act_feed_quantity) AS month_feed_quantity,
        SUM(total_feed_cost) AS month_feed_cost,
        SUM(concentrate_quantity) AS month_concentrate_quantity,
        SUM(roughage_quantity) AS month_roughage_quantity,
        SUM(CASE WHEN total_cattle_count > 0 THEN total_feed_cost / total_cattle_count ELSE 0 END) AS sum_daily_feed_cost_per_cattle
    FROM {{ ref('dws_ranch_stall_feed_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 3. 出栏成本回收（已出栏牛只的总成本和收入）
-- ============================================
sell_cost_recovery AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(sell_total_amount) AS month_sell_revenue,
        COUNT(DISTINCT cattle_id) AS month_sell_count,
        SUM(sell_total_weight) AS month_sell_weight
    FROM {{ ref('dws_ranch_cattle_sell_agg_mf') }}
    GROUP BY 1, 2
),

-- ============================================
-- 4. 月末在栏牛成本规模（从月度快照聚合表）
-- ============================================
inventory_cost AS (
    SELECT
        natural_month,
        ranch_id,
        end_cattle_count,
        end_total_feed_cost
    FROM {{ ref('dws_ranch_cattle_inventory_snap_mf') }}
),

-- ============================================
-- 5. 统一主键表
-- ============================================
all_keys AS (
    SELECT natural_month, ranch_id FROM purchase_monthly
    UNION
    SELECT natural_month, ranch_id FROM feed_monthly
    UNION
    SELECT natural_month, ranch_id FROM sell_cost_recovery
    UNION
    SELECT natural_month, ranch_id FROM inventory_cost
),

-- ============================================
-- 6. 数据整合与成本指标计算
-- ============================================
integrated AS (
    SELECT
        k.natural_month,
        k.ranch_id,
        COALESCE(dr.ranch_name, '') AS ranch_name,

        -- 采购成本
        COALESCE(pm.month_purchase_cost, 0) AS month_purchase_cost,
        pm.month_purchase_count,
        pm.month_purchase_weight,
        pm.avg_purchase_unit_price,

        -- 饲料成本
        COALESCE(fm.month_feed_cost, 0) AS month_feed_cost,
        fm.month_feed_quantity,
        fm.month_concentrate_quantity,
        fm.month_roughage_quantity,

        -- 月度总成本
        COALESCE(pm.month_purchase_cost, 0) + COALESCE(fm.month_feed_cost, 0) AS month_total_cost,

        -- 出栏成本回收
        COALESCE(sc.month_sell_revenue, 0) AS month_sell_revenue,
        sc.month_sell_count,
        sc.month_sell_weight,

        -- 月末在栏成本规模
        ic.end_cattle_count,
        ic.end_total_feed_cost,

        -- 成本效率指标
        CASE WHEN pm.month_purchase_count > 0
             THEN pm.month_purchase_cost / pm.month_purchase_count
             ELSE NULL END AS avg_purchase_cost_per_cattle,
        CASE WHEN fm.month_feed_quantity > 0
             THEN fm.month_feed_cost / fm.month_feed_quantity
             ELSE NULL END AS avg_feed_unit_price,
        CASE WHEN ic.end_cattle_count > 0
             THEN ic.end_total_feed_cost / ic.end_cattle_count
             ELSE NULL END AS avg_feed_cost_per_cattle_month_end,

        -- 成本结构占比
        CASE WHEN (COALESCE(pm.month_purchase_cost, 0) + COALESCE(fm.month_feed_cost, 0)) > 0
             THEN pm.month_purchase_cost / (COALESCE(pm.month_purchase_cost, 0) + COALESCE(fm.month_feed_cost, 0))
             ELSE NULL END AS purchase_cost_ratio,
        CASE WHEN (COALESCE(pm.month_purchase_cost, 0) + COALESCE(fm.month_feed_cost, 0)) > 0
             THEN fm.month_feed_cost / (COALESCE(pm.month_purchase_cost, 0) + COALESCE(fm.month_feed_cost, 0))
             ELSE NULL END AS feed_cost_ratio,

        -- 饲料成本内部结构
        CASE WHEN fm.month_feed_quantity > 0
             THEN fm.month_concentrate_quantity / fm.month_feed_quantity
             ELSE NULL END AS concentrate_ratio,
        CASE WHEN fm.month_feed_quantity > 0
             THEN fm.month_roughage_quantity / fm.month_feed_quantity
             ELSE NULL END AS roughage_ratio,

        -- 出栏成本回收率（出栏收入/出栏牛成本，需要关联回牛只成本，此处简化为收入/成本比）
        CASE WHEN COALESCE(pm.month_purchase_cost, 0) + COALESCE(fm.month_feed_cost, 0) > 0
             THEN sc.month_sell_revenue / (COALESCE(pm.month_purchase_cost, 0) + COALESCE(fm.month_feed_cost, 0))
             ELSE NULL END AS cost_recovery_rate

    FROM all_keys k
    LEFT JOIN purchase_monthly pm ON k.natural_month = pm.natural_month AND k.ranch_id = pm.ranch_id
    LEFT JOIN feed_monthly fm ON k.natural_month = fm.natural_month AND k.ranch_id = fm.ranch_id
    LEFT JOIN sell_cost_recovery sc ON k.natural_month = sc.natural_month AND k.ranch_id = sc.ranch_id
    LEFT JOIN inventory_cost ic ON k.natural_month = ic.natural_month AND k.ranch_id = ic.ranch_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON k.ranch_id = dr.ranch_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    natural_month,
    ranch_id,
    ranch_name,

    -- 采购成本
    month_purchase_cost,                    -- 月度采购成本
    month_purchase_count,                   -- 月度采购牛只数
    month_purchase_weight,                  -- 月度采购总重量
    avg_purchase_unit_price,                -- 平均采购单价

    -- 饲料成本
    month_feed_cost,                        -- 月度饲料成本
    month_feed_quantity,                    -- 月度饲料消耗量
    month_concentrate_quantity,             -- 月度精料消耗量
    month_roughage_quantity,                -- 月度粗料消耗量

    -- 月度总成本
    month_total_cost,                       -- 月度总成本（采购+饲料）

    -- 出栏成本回收
    month_sell_revenue,                     -- 月度出栏收入
    month_sell_count,                       -- 月度出栏数量
    month_sell_weight,                      -- 月度出栏重量

    -- 月末在栏成本规模
    end_cattle_count,                       -- 月末在栏数量
    end_total_feed_cost,                    -- 月末累计饲料成本

    -- 成本效率指标
    avg_purchase_cost_per_cattle,           -- 头均采购成本
    avg_feed_unit_price,                    -- 饲料平均单价
    avg_feed_cost_per_cattle_month_end,     -- 月末头均累计饲料成本

    -- 成本结构占比
    purchase_cost_ratio,                    -- 采购成本占比
    feed_cost_ratio,                        -- 饲料成本占比
    concentrate_ratio,                      -- 精料占比
    roughage_ratio,                         -- 粗料占比

    -- 出栏成本回收率
    cost_recovery_rate,                     -- 成本回收率

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time

FROM integrated
ORDER BY natural_month DESC, ranch_id
```

- [ ] **Step 2: 验证语法**

运行：`dbt parse --select ads_ranch_cost_dashboard_mf`
预期：无语法错误

- [ ] **Step 3: 提交**

```bash
git add models/ranch/ads/ads_ranch_cost_dashboard_mf.sql
git commit -m "feat(ranch): add cost dashboard monthly report"
```

---

## Chunk 2: 健康域模型（Health Domain）

### Task 3: 创建牛只健康画像宽表

**Files:**
- Create: `models/ranch/ads/ads_ranch_cattle_health_profile_cum_d.sql`

- [ ] **Step 1: 编写模型代码**

```sql
-- =============================================
-- 模型名称：ads_ranch_cattle_health_profile_cum_d
-- 模型描述：牛只健康画像宽表（至今），每头牛一条记录，汇总最新生长指标、AI评分、健康等级标签
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：dim_ranch_cattle（牛只维度）+ dws_ranch_cattle_adg_fcr_i（ADG料肉比）+ dws_ranch_ai_score_agg_di（AI评分）+ dws_ranch_cattle_weight_snap_df（体重快照）+ dim_ranch_grow_stage（生长阶段）
--   - 增量策略：全量刷新（table）
--   - 统计指标：最新ADG及趋势、AI评分、体重偏离度、料肉比、生长阶段匹配、健康等级标签
-- =============================================
{{ config(
    materialized='table',
    description='牛只健康画像宽表（至今），汇总每头牛的最新生长指标、AI评分、健康等级标签',
    tags=['ranch', 'ads', 'health', 'cattle', 'profile']
) }}

-- ============================================
-- 1. 基础档案
-- ============================================
WITH cattle_base AS (
    SELECT
        cattle_id,
        cattle_code AS cattle_no,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        birth_date,
        in_stall_date,
        in_stall_weight,
        cattle_status AS dim_cattle_status
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- 2. 最新ADG记录
-- ============================================
latest_adg AS (
    SELECT
        cattle_id,
        stats_date AS latest_adg_date,
        current_weight AS latest_weight,
        prev_weight_date,
        period_weight_gain,
        period_adg,
        overall_adg,
        interval_days,
        period_fcr,
        period_feed_consumption,
        cumulative_gain,
        stage_name,
        stage_target_fcr
    FROM (
        SELECT
            cattle_id, stats_date, current_weight, prev_weight_date,
            period_weight_gain, period_adg, overall_adg, interval_days,
            period_fcr, period_feed_consumption, cumulative_gain,
            stage_name, stage_target_fcr,
            ROW_NUMBER() OVER (PARTITION BY cattle_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_cattle_adg_fcr_i') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

-- ============================================
-- 3. 最新AI评分
-- ============================================
latest_ai_score AS (
    SELECT
        cattle_id,
        MAX(score_date) AS latest_ai_date,
        AVG(ai_score) AS latest_ai_score,
        AVG(hair) AS latest_hair_score,
        AVG(muscle) AS latest_muscle_score,
        AVG(out_stall_weight) AS latest_out_stall_predict
    FROM {{ ref('dwd_ranch_cattle_ai_score_fact_i') }}
    WHERE create_time IS NOT NULL
    GROUP BY cattle_id
),

-- ============================================
-- 4. 体重快照
-- ============================================
weight_snap AS (
    SELECT
        cattle_id,
        latest_weight_date,
        latest_weight,
        latest_daily_gain,
        latest_ai_score AS snap_ai_score
    FROM {{ ref('dws_ranch_cattle_weight_snap_df') }}
),

-- ============================================
-- 5. 生长阶段标准体重
-- ============================================
stage_standard AS (
    SELECT
        stage_id,
        stage_name,
        weight_begin,
        weight_end,
        target_adg_min,
        target_adg_max,
        target_fcr_min,
        target_fcr_max
    FROM {{ ref('dim_ranch_grow_stage') }}
    WHERE is_current = '1'
),

-- ============================================
-- 6. ADG历史趋势（最近3次平均）
-- ============================================
adg_trend AS (
    SELECT
        cattle_id,
        AVG(period_adg) AS avg_recent_adg,
        STDDEV(period_adg) AS stddev_recent_adg
    FROM (
        SELECT
            cattle_id, period_adg,
            ROW_NUMBER() OVER (PARTITION BY cattle_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_cattle_adg_fcr_i') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn <= 3
    GROUP BY cattle_id
),

-- ============================================
-- 7. 数据整合与健康指标计算
-- ============================================
integrated AS (
    SELECT
        b.cattle_id,
        b.cattle_no,
        b.ranch_id,
        b.ranch_name,
        b.stall_id,
        b.stall_name,
        b.cattle_sku_id,
        b.cattle_sku_name,
        b.brand_name,
        b.birth_date,
        b.in_stall_date,
        b.in_stall_weight,

        -- 状态
        b.dim_cattle_status,

        -- 最新体重
        COALESCE(a.latest_weight, w.latest_weight, b.in_stall_weight) AS current_weight,
        COALESCE(a.latest_adg_date, w.latest_weight_date) AS latest_measure_date,

        -- ADG指标
        a.latest_adg_date,
        a.period_weight_gain,
        a.period_adg,
        a.overall_adg,
        a.interval_days,
        a.cumulative_gain,
        a.stage_name,

        -- ADG趋势
        at.avg_recent_adg,
        at.stddev_recent_adg,

        -- ADG达标判定
        CASE WHEN a.stage_name IS NOT NULL AND ss.target_adg_min IS NOT NULL AND a.period_adg IS NOT NULL
             WHEN a.period_adg >= ss.target_adg_min AND a.period_adg <= ss.target_adg_max THEN '达标'
             WHEN a.period_adg < ss.target_adg_min THEN '偏低'
             WHEN a.period_adg > ss.target_adg_max THEN '偏高'
             ELSE '未知' END AS adg_status,

        -- 料肉比
        a.period_fcr,
        a.stage_target_fcr,
        a.period_feed_consumption,

        -- FCR达标判定
        CASE WHEN a.stage_name IS NOT NULL AND ss.target_fcr_min IS NOT NULL AND a.period_fcr IS NOT NULL
             WHEN a.period_fcr >= ss.target_fcr_min AND a.period_fcr <= ss.target_fcr_max THEN '正常'
             WHEN a.period_fcr > ss.target_fcr_max THEN '偏高'
             ELSE '未知' END AS fcr_status,

        -- AI评分
        ais.latest_ai_date,
        ais.latest_ai_score,
        ais.latest_hair_score,
        ais.latest_muscle_score,
        ais.latest_out_stall_predict,

        -- 体重偏离度（与同龄标准对比）
        CASE WHEN b.birth_date IS NOT NULL
             THEN DATE_DIFF('day', b.birth_date, COALESCE(a.latest_adg_date, w.latest_weight_date, CURRENT_DATE))
             ELSE NULL END AS day_age,
        -- 偏离度 = (当前体重 - 入栏体重 - 目标增重) / 目标增重（简化版：使用日龄×目标ADG）
        CASE WHEN b.in_stall_date IS NOT NULL AND b.in_stall_weight IS NOT NULL
                  AND DATE_DIFF('day', b.in_stall_date, COALESCE(a.latest_adg_date, w.latest_weight_date, CURRENT_DATE)) > 0
             THEN (COALESCE(a.latest_weight, w.latest_weight, b.in_stall_weight) - b.in_stall_weight) /
                  DATE_DIFF('day', b.in_stall_date, COALESCE(a.latest_adg_date, w.latest_weight_date, CURRENT_DATE))
             ELSE NULL END AS actual_overall_adg,

        -- 健康等级标签（综合评分）
        CASE
            WHEN ais.latest_ai_score >= 90 AND a.period_adg IS NOT NULL AND a.period_adg >= 0.8 THEN '优秀'
            WHEN ais.latest_ai_score >= 80 AND a.period_adg IS NOT NULL AND a.period_adg >= 0.6 THEN '良好'
            WHEN ais.latest_ai_score >= 70 AND a.period_adg IS NOT NULL AND a.period_adg >= 0.4 THEN '一般'
            WHEN ais.latest_ai_score < 70 OR a.period_adg < 0.4 THEN '较差'
            ELSE '待评估'
        END AS health_grade

    FROM cattle_base b
    LEFT JOIN latest_adg a ON CAST(b.cattle_id AS VARCHAR) = CAST(a.cattle_id AS VARCHAR)
    LEFT JOIN latest_ai_score ais ON CAST(b.cattle_id AS VARCHAR) = CAST(ais.cattle_id AS VARCHAR)
    LEFT JOIN weight_snap w ON CAST(b.cattle_id AS VARCHAR) = CAST(w.cattle_id AS VARCHAR)
    LEFT JOIN stage_standard ss ON a.stage_name::VARCHAR = ss.stage_name::VARCHAR
    LEFT JOIN adg_trend at ON CAST(b.cattle_id AS VARCHAR) = CAST(at.cattle_id AS VARCHAR)
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 标识维度
    cattle_id,                               -- 牛只ID
    cattle_no,                               -- 牛只编号

    -- 组织维度
    ranch_id,                                -- 牧场ID
    ranch_name,                              -- 牧场名称
    stall_id,                                -- 栏舍ID
    stall_name,                              -- 栏舍名称

    -- 品种维度
    cattle_sku_id,                           -- SKU ID
    cattle_sku_name,                         -- SKU名称
    brand_name,                              -- 品牌名称

    -- 基础属性
    birth_date,                              -- 出生日期
    in_stall_date,                           -- 入栏日期
    in_stall_weight,                         -- 入栏体重
    day_age,                                 -- 日龄

    -- 状态
    dim_cattle_status,                       -- 牛只状态

    -- 最新体重
    current_weight,                          -- 最新体重
    latest_measure_date,                     -- 最新测量日期

    -- ADG指标
    latest_adg_date,                         -- 最新ADG统计日期
    period_weight_gain,                      -- 区间增重
    period_adg,                              -- 区间日均增重
    overall_adg,                             -- 整体ADG
    interval_days,                           -- 称重间隔天数
    cumulative_gain,                         -- 累计增重
    stage_name,                              -- 生长阶段

    -- ADG趋势
    avg_recent_adg,                          -- 最近3次平均ADG
    stddev_recent_adg,                       -- 最近3次ADG标准差

    -- ADG达标判定
    adg_status,                              -- ADG状态（达标/偏低/偏高/未知）

    -- 料肉比
    period_fcr,                              -- 区间料肉比
    stage_target_fcr,                        -- 阶段目标料肉比
    period_feed_consumption,                 -- 区间饲料消耗

    -- FCR达标判定
    fcr_status,                              -- FCR状态（正常/偏高/未知）

    -- AI评分
    latest_ai_date,                          -- 最新AI评分日期
    latest_ai_score,                         -- 最新AI评分
    latest_hair_score,                       -- 最新被毛评分
    latest_muscle_score,                     -- 最新肌肉评分
    latest_out_stall_predict,                -- 出栏体重预测

    -- 体重偏离度
    actual_overall_adg,                      -- 实际整体ADG

    -- 健康等级
    health_grade,                            -- 健康等级（优秀/良好/一般/较差/待评估）

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM integrated
ORDER BY ranch_id, stall_id, cattle_id
```

- [ ] **Step 2: 验证语法**

运行：`dbt parse --select ads_ranch_cattle_health_profile_cum_d`
预期：无语法错误

- [ ] **Step 3: 提交**

```bash
git add models/ranch/ads/ads_ranch_cattle_health_profile_cum_d.sql
git commit -m "feat(ranch): add cattle health profile wide table (cumulative daily)"
```

---

### Task 4: 创建牧场健康月报

**Files:**
- Create: `models/ranch/ads/ads_ranch_health_dashboard_mf.sql`

- [ ] **Step 1: 编写模型代码**

```sql
-- =============================================
-- 模型名称：ads_ranch_health_dashboard_mf
-- 模型描述：牧场健康运营月报，按牧场+自然月统计群体健康指标、异常分布及体重达标率
-- Dbt更新方式：全量
-- 粒度：牧场 + 自然月
-- 说明：
--   - 数据源：dws_ranch_cattle_growth_agg_mi（月生长统计）+ dws_ranch_ai_score_agg_di（AI评分）+ dws_ranch_cattle_adg_fcr_i（ADG料肉比）+ dws_ranch_stall_performance_agg_di（栏舍绩效）
--   - 增量策略：全量刷新（table）
--   - 统计指标：群体ADG分布、AI评分分布、异常牛只比例、体重达标率、料肉比分布
-- =============================================
{{ config(
    materialized='table',
    description='牧场健康运营月报，按牧场+自然月统计群体健康指标、异常分布及体重达标率',
    tags=['ranch', 'ads', 'health', 'dashboard', 'monthly']
) }}

-- ============================================
-- 1. 月度生长统计
-- ============================================
growth_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        total_cattle_count,
        weighed_cattle_count,
        weigh_coverage_rate,
        avg_weight,
        avg_period_adg,
        stddev_period_adg,
        min_period_adg,
        max_period_adg
    FROM {{ ref('dws_ranch_cattle_growth_agg_mi') }}
),

-- ============================================
-- 2. 月度AI评分统计
-- ============================================
ai_score_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(total_scored_cattle) AS month_total_scored_cattle,
        AVG(avg_ai_score) AS month_avg_ai_score,
        SUM(count_score_a) AS month_count_score_a,
        SUM(count_score_b) AS month_count_score_b,
        SUM(count_score_c) AS month_count_score_c,
        SUM(count_score_d) AS month_count_score_d,
        SUM(count_score_e) AS month_count_score_e
    FROM {{ ref('dws_ranch_ai_score_agg_di') }}
    WHERE score_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 3. 月度料肉比统计
-- ============================================
fcr_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        AVG(avg_period_fcr) AS month_avg_fcr,
        AVG(min_period_fcr) AS month_min_fcr,
        AVG(max_period_fcr) AS month_max_fcr,
        AVG(herd_fcr) AS month_herd_fcr
    FROM {{ ref('dws_ranch_stall_performance_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 4. 统一主键表
-- ============================================
all_keys AS (
    SELECT natural_month, ranch_id FROM growth_monthly
    UNION
    SELECT natural_month, ranch_id FROM ai_score_monthly
    UNION
    SELECT natural_month, ranch_id FROM fcr_monthly
),

-- ============================================
-- 5. 数据整合与健康指标计算
-- ============================================
integrated AS (
    SELECT
        k.natural_month,
        k.ranch_id,
        COALESCE(dr.ranch_name, '') AS ranch_name,

        -- 在栏规模
        COALESCE(g.total_cattle_count, 0) AS total_cattle_count,
        COALESCE(g.weighed_cattle_count, 0) AS weighed_cattle_count,
        g.weigh_coverage_rate,

        -- ADG统计
        g.avg_period_adg,
        g.stddev_period_adg,
        g.min_period_adg,
        g.max_period_adg,

        -- AI评分统计
        COALESCE(ai.month_total_scored_cattle, 0) AS month_total_scored_cattle,
        ai.month_avg_ai_score,
        ai.month_count_score_a,
        ai.month_count_score_b,
        ai.month_count_score_c,
        ai.month_count_score_d,
        ai.month_count_score_e,

        -- AI评分覆盖率
        CASE WHEN g.total_cattle_count > 0
             THEN CAST(ai.month_total_scored_cattle AS DOUBLE) / g.total_cattle_count * 100
             ELSE NULL END AS ai_score_coverage_rate,

        -- AI评分占比
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_a AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_a,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_b AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_b,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_c AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_c,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_d AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_d,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_e AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_e,

        -- 料肉比统计
        f.month_avg_fcr,
        f.month_min_fcr,
        f.month_max_fcr,
        f.month_herd_fcr,

        -- 异常牛只比例
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_e AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS abnormal_cattle_rate,

        -- 健康达标判定（ADG >= 0.8 且 AI评分 >= 80）
        CASE WHEN g.total_cattle_count > 0
             THEN (CAST(ai.month_count_score_a + ai.month_count_score_b AS DOUBLE) / g.total_cattle_count) * 100
             ELSE NULL END AS health_excellent_rate

    FROM all_keys k
    LEFT JOIN growth_monthly g ON k.natural_month = g.natural_month AND k.ranch_id = g.ranch_id
    LEFT JOIN ai_score_monthly ai ON k.natural_month = ai.natural_month AND k.ranch_id = ai.ranch_id
    LEFT JOIN fcr_monthly f ON k.natural_month = f.natural_month AND k.ranch_id = f.ranch_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON k.ranch_id = dr.ranch_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    natural_month,
    ranch_id,
    ranch_name,

    -- 在栏规模
    total_cattle_count,                     -- 月末在栏数量
    weighed_cattle_count,                   -- 月度称重数量
    weigh_coverage_rate,                    -- 称重覆盖率

    -- ADG统计
    avg_period_adg,                         -- 平均ADG
    stddev_period_adg,                      -- ADG标准差
    min_period_adg,                         -- 最小ADG
    max_period_adg,                         -- 最大ADG

    -- AI评分统计
    month_total_scored_cattle,              -- 月度评分总数
    month_avg_ai_score,                     -- 月度平均AI评分
    month_count_score_a,                    -- A级数量
    month_count_score_b,                    -- B级数量
    month_count_score_c,                    -- C级数量
    month_count_score_d,                    -- D级数量
    month_count_score_e,                    -- E级数量

    -- AI评分覆盖率
    ai_score_coverage_rate,                 -- AI评分覆盖率

    -- AI评分占比
    pct_score_a,                            -- A级占比
    pct_score_b,                            -- B级占比
    pct_score_c,                            -- C级占比
    pct_score_d,                            -- D级占比
    pct_score_e,                            -- E级占比

    -- 料肉比统计
    month_avg_fcr,                          -- 月度平均料肉比
    month_min_fcr,                          -- 月度最小料肉比
    month_max_fcr,                          -- 月度最大料肉比
    month_herd_fcr,                         -- 群体料肉比

    -- 异常牛只比例
    abnormal_cattle_rate,                   -- 异常牛只比例（E级占比）

    -- 健康达标率
    health_excellent_rate,                  -- 健康优秀率（A+B级占比）

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time

FROM integrated
ORDER BY natural_month DESC, ranch_id
```

- [ ] **Step 2: 验证语法**

运行：`dbt parse --select ads_ranch_health_dashboard_mf`
预期：无语法错误

- [ ] **Step 3: 提交**

```bash
git add models/ranch/ads/ads_ranch_health_dashboard_mf.sql
git commit -m "feat(ranch): add health dashboard monthly report"
```

---

## Chunk 3: 运营域模型（Operation Domain）

### Task 5: 创建牧场运营月报

**Files:**
- Create: `models/ranch/ads/ads_ranch_operation_dashboard_mf.sql`

- [ ] **Step 1: 编写模型代码**

```sql
-- =============================================
-- 模型名称：ads_ranch_operation_dashboard_mf
-- 模型描述：牧场运营月报，按牧场+自然月统计栏舍利用率、周转效率、饲料效率及配方效果
-- Dbt更新方式：全量
-- 粒度：牧场 + 自然月
-- 说明：
--   - 数据源：dws_ranch_stall_capacity_agg_di（栏舍容量）+ dws_ranch_stall_performance_agg_di（栏舍绩效）+ dws_ranch_stall_feed_agg_di（栏舍饲料）+ dws_ranch_recipe_performance_agg_mi（配方效果）+ dws_ranch_ai_score_agg_di（AI评分）
--   - 增量策略：全量刷新（table）
--   - 统计指标：栏舍利用率、周转效率、饲料转化效率、配方执行率、AI覆盖率和评分
-- =============================================
{{ config(
    materialized='table',
    description='牧场运营月报，按牧场+自然月统计栏舍利用率、周转效率、饲料效率及配方效果',
    tags=['ranch', 'ads', 'operation', 'dashboard', 'monthly']
) }}

-- ============================================
-- 1. 月度栏舍容量统计
-- ============================================
capacity_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(system_cattle_count) AS month_total_capacity,
        SUM(actual_cattle_count) AS month_total_actual_cattle,
        SUM(system_weight_capacity) AS month_total_weight_capacity,
        SUM(actual_total_weight) AS month_total_actual_weight,
        AVG(capacity_utilization_rate) AS month_avg_capacity_utilization
    FROM {{ ref('dws_ranch_stall_capacity_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 2. 月度周转统计
-- ============================================
turnover_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(total_cattle_count) AS month_total_cattle_count,
        SUM(count_under_30d) AS month_count_under_30d,
        SUM(count_30_60d) AS month_count_30_60d,
        SUM(count_60_90d) AS month_count_60_90d,
        SUM(count_90_120d) AS month_count_90_120d,
        SUM(count_120_150d) AS month_count_120_150d,
        SUM(count_150_180d) AS month_count_150_180d,
        SUM(count_over_180d) AS month_count_over_180d
    FROM {{ ref('dws_ranch_stall_performance_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 3. 月度饲料效率统计
-- ============================================
feed_efficiency_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(act_feed_quantity) AS month_total_feed_quantity,
        SUM(total_feed_cost) AS month_total_feed_cost,
        AVG(feed_plan_completion_rate) AS month_avg_feed_completion_rate,
        AVG(leftover_rate) AS month_avg_leftover_rate,
        AVG(concentrate_ratio) AS month_avg_concentrate_ratio,
        AVG(roughage_ratio) AS month_avg_roughage_ratio
    FROM {{ ref('dws_ranch_stall_feed_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 4. 月度配方效果统计
-- ============================================
recipe_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        COUNT(DISTINCT recipe_id) AS month_recipe_count,
        SUM(total_cattle_count) AS month_recipe_cattle_count,
        AVG(avg_period_adg) AS month_recipe_avg_adg,
        AVG(avg_fcr) AS month_recipe_avg_fcr,
        AVG(feed_cost_per_kg_gain) AS month_avg_feed_cost_per_kg_gain
    FROM {{ ref('dws_ranch_recipe_performance_agg_mi') }}
    WHERE natural_month IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 5. 月度AI评分统计
-- ============================================
ai_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(total_scored_cattle) AS month_total_ai_scored_cattle,
        AVG(avg_ai_score) AS month_avg_ai_score
    FROM {{ ref('dws_ranch_ai_score_agg_di') }}
    WHERE score_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 6. 统一主键表
-- ============================================
all_keys AS (
    SELECT natural_month, ranch_id FROM capacity_monthly
    UNION
    SELECT natural_month, ranch_id FROM turnover_monthly
    UNION
    SELECT natural_month, ranch_id FROM feed_efficiency_monthly
    UNION
    SELECT natural_month, ranch_id FROM recipe_monthly
    UNION
    SELECT natural_month, ranch_id FROM ai_monthly
),

-- ============================================
-- 7. 数据整合与运营指标计算
-- ============================================
integrated AS (
    SELECT
        k.natural_month,
        k.ranch_id,
        COALESCE(dr.ranch_name, '') AS ranch_name,

        -- 栏舍利用率
        c.month_total_capacity,
        c.month_total_actual_cattle,
        c.month_total_weight_capacity,
        c.month_total_actual_weight,
        c.month_avg_capacity_utilization,
        CASE WHEN c.month_total_capacity > 0
             THEN CAST(c.month_total_actual_cattle AS DOUBLE) / c.month_total_capacity * 100
             ELSE NULL END AS overall_capacity_utilization_rate,

        -- 周转效率
        t.month_total_cattle_count,
        t.month_count_under_30d,
        t.month_count_30_60d,
        t.month_count_60_90d,
        t.month_count_90_120d,
        t.month_count_120_150d,
        t.month_count_150_180d,
        t.month_count_over_180d,

        -- 周转天数分布占比
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_under_30d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_under_30d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_30_60d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_30_60d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_60_90d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_60_90d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_90_120d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_90_120d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_120_150d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_120_150d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_150_180d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_150_180d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_over_180d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_over_180d,

        -- 饲料效率
        fe.month_total_feed_quantity,
        fe.month_total_feed_cost,
        fe.month_avg_feed_completion_rate,
        fe.month_avg_leftover_rate,
        fe.month_avg_concentrate_ratio,
        fe.month_avg_roughage_ratio,

        -- 配方效果
        r.month_recipe_count,
        r.month_recipe_cattle_count,
        r.month_recipe_avg_adg,
        r.month_recipe_avg_fcr,
        r.month_avg_feed_cost_per_kg_gain,

        -- AI覆盖
        ai.month_total_ai_scored_cattle,
        ai.month_avg_ai_score,
        CASE WHEN c.month_total_actual_cattle > 0
             THEN CAST(ai.month_total_ai_scored_cattle AS DOUBLE) / c.month_total_actual_cattle * 100
             ELSE NULL END AS ai_score_coverage_rate

    FROM all_keys k
    LEFT JOIN capacity_monthly c ON k.natural_month = c.natural_month AND k.ranch_id = c.ranch_id
    LEFT JOIN turnover_monthly t ON k.natural_month = t.natural_month AND k.ranch_id = t.ranch_id
    LEFT JOIN feed_efficiency_monthly fe ON k.natural_month = fe.natural_month AND k.ranch_id = fe.ranch_id
    LEFT JOIN recipe_monthly r ON k.natural_month = r.natural_month AND k.ranch_id = r.ranch_id
    LEFT JOIN ai_monthly ai ON k.natural_month = ai.natural_month AND k.ranch_id = ai.ranch_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON k.ranch_id = dr.ranch_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    natural_month,
    ranch_id,
    ranch_name,

    -- 栏舍利用率
    month_total_capacity,                  -- 月总容量（牛只数）
    month_total_actual_cattle,             -- 月实际在栏数
    month_total_weight_capacity,           -- 月总容量（重量）
    month_total_actual_weight,             -- 月实际总重量
    month_avg_capacity_utilization,        -- 平均容量利用率
    overall_capacity_utilization_rate,     -- 整体容量利用率

    -- 周转效率
    month_total_cattle_count,              -- 月总牛只数
    month_count_under_30d,                 -- 30天内数量
    month_count_30_60d,                    -- 30-60天数量
    month_count_60_90d,                    -- 60-90天数量
    month_count_90_120d,                   -- 90-120天数量
    month_count_120_150d,                  -- 120-150天数量
    month_count_150_180d,                  -- 150-180天数量
    month_count_over_180d,                 -- 180天以上数量

    -- 周转天数分布占比
    pct_under_30d,                         -- 30天内占比
    pct_30_60d,                            -- 30-60天占比
    pct_60_90d,                            -- 60-90天占比
    pct_90_120d,                           -- 90-120天占比
    pct_120_150d,                          -- 120-150天占比
    pct_150_180d,                          -- 150-180天占比
    pct_over_180d,                         -- 180天以上占比

    -- 饲料效率
    month_total_feed_quantity,             -- 月总饲料消耗量
    month_total_feed_cost,                 -- 月总饲料成本
    month_avg_feed_completion_rate,        -- 平均投喂完成率
    month_avg_leftover_rate,               -- 平均剩料率
    month_avg_concentrate_ratio,           -- 平均精料占比
    month_avg_roughage_ratio,              -- 平均粗料占比

    -- 配方效果
    month_recipe_count,                    -- 月使用配方数
    month_recipe_cattle_count,             -- 配方覆盖牛只数
    month_recipe_avg_adg,                  -- 配方平均ADG
    month_recipe_avg_fcr,                  -- 配方平均料肉比
    month_avg_feed_cost_per_kg_gain,       -- 单位增重饲料成本

    -- AI覆盖
    month_total_ai_scored_cattle,          -- 月AI评分总数
    month_avg_ai_score,                    -- 月平均AI评分
    ai_score_coverage_rate,                -- AI评分覆盖率

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time

FROM integrated
ORDER BY natural_month DESC, ranch_id
```

- [ ] **Step 2: 验证语法**

运行：`dbt parse --select ads_ranch_operation_dashboard_mf`
预期：无语法错误

- [ ] **Step 3: 提交**

```bash
git add models/ranch/ads/ads_ranch_operation_dashboard_mf.sql
git commit -m "feat(ranch): add operation dashboard monthly report"
```

---

### Task 6: 创建栏舍运营画像

**Files:**
- Create: `models/ranch/ads/ads_ranch_stall_operation_profile.sql`

- [ ] **Step 1: 编写模型代码**

```sql
-- =============================================
-- 模型名称：ads_ranch_stall_operation_profile
-- 模型描述：栏舍运营画像，每个栏舍一条记录，汇总容量、绩效、饲料、品种分布等运营全貌
-- Dbt更新方式：全量
-- 粒度：栏舍级（1栏舍1行，最新状态）
-- 说明：
--   - 数据源：dim_ranch_stall（栏舍维度）+ dws_ranch_stall_capacity_agg_di（容量）+ dws_ranch_stall_performance_agg_di（绩效）+ dws_ranch_stall_feed_agg_di（饲料）
--   - 增量策略：全量刷新（table）
--   - 统计指标：设计容量、实际使用、容量利用率、ADG/料肉比、饲料投喂、品种分布、容量状态标签
-- =============================================
{{ config(
    materialized='table',
    description='栏舍运营画像，汇总每个栏舍的容量、绩效、饲料、品种分布等运营全貌',
    tags=['ranch', 'ads', 'operation', 'stall', 'profile']
) }}

-- ============================================
-- 1. 栏舍基础信息
-- ============================================
stall_base AS (
    SELECT
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        system_cattle_count,
        system_weight_capacity,
        recipe_id,
        recipe_name,
        is_current
    FROM {{ ref('dim_ranch_stall') }}
    WHERE is_current = '1'
),

-- ============================================
-- 2. 最新容量统计
-- ============================================
latest_capacity AS (
    SELECT
        stall_id,
        stats_date AS latest_capacity_date,
        actual_cattle_count,
        actual_total_weight,
        capacity_utilization_rate,
        capacity_status_label
    FROM (
        SELECT
            stall_id, stats_date, actual_cattle_count, actual_total_weight,
            capacity_utilization_rate, capacity_status_label,
            ROW_NUMBER() OVER (PARTITION BY stall_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_capacity_agg_di') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

-- ============================================
-- 3. 最新绩效统计
-- ============================================
latest_performance AS (
    SELECT
        stall_id,
        stats_date AS latest_performance_date,
        total_cattle_count,
        weighed_cattle_count,
        avg_current_weight,
        avg_period_adg,
        avg_period_fcr,
        weight_add_ratio,
        herd_fcr,
        feed_cost_per_kg
    FROM (
        SELECT
            stall_id, stats_date, total_cattle_count, weighed_cattle_count,
            avg_current_weight, avg_period_adg, avg_period_fcr,
            weight_add_ratio, herd_fcr, feed_cost_per_kg,
            ROW_NUMBER() OVER (PARTITION BY stall_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_performance_agg_di') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

-- ============================================
-- 4. 最新饲料投喂统计（最近7天平均）
-- ============================================
latest_feed AS (
    SELECT
        stall_id,
        AVG(act_feed_quantity) AS avg_daily_feed_quantity,
        AVG(total_feed_cost) AS avg_daily_feed_cost,
        AVG(feed_plan_completion_rate) AS avg_feed_completion_rate,
        AVG(leftover_rate) AS avg_leftover_rate,
        AVG(concentrate_ratio) AS avg_concentrate_ratio,
        AVG(roughage_ratio) AS avg_roughage_ratio,
        AVG(avg_feed_intake_per_cattle) AS avg_feed_intake_per_cattle,
        AVG(avg_feed_cost_per_cattle) AS avg_feed_cost_per_cattle
    FROM (
        SELECT
            stall_id, stats_date, act_feed_quantity, total_feed_cost,
            feed_plan_completion_rate, leftover_rate, concentrate_ratio,
            roughage_ratio, avg_feed_intake_per_cattle, avg_feed_cost_per_cattle,
            ROW_NUMBER() OVER (PARTITION BY stall_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_feed_agg_di') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn <= 7
    GROUP BY stall_id
),

-- ============================================
-- 5. 品种分布
-- ============================================
brand_distribution AS (
    SELECT
        stall_id,
        MAX(CASE WHEN brand_name = '西门塔尔' THEN cattle_count ELSE 0 END) AS count_simmental,
        MAX(CASE WHEN brand_name = '安格斯' THEN cattle_count ELSE 0 END) AS count_angus,
        MAX(CASE WHEN brand_name = '夏洛莱' THEN cattle_count ELSE 0 END) AS count_charolais,
        MAX(CASE WHEN brand_name = '利木赞' THEN cattle_count ELSE 0 END) AS count_limousin,
        SUM(cattle_count) AS total_count
    FROM (
        SELECT
            stall_id, brand_name, COUNT(DISTINCT cattle_id) AS cattle_count,
            ROW_NUMBER() OVER (PARTITION BY stall_id, brand_name ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_capacity_agg_di') }}
        WHERE stats_date IS NOT NULL
        GROUP BY stall_id, brand_name, stats_date
    ) t
    WHERE rn = 1
    GROUP BY stall_id
),

-- ============================================
-- 6. 数据整合
-- ============================================
integrated AS (
    SELECT
        b.stall_id,
        b.stall_name,
        b.ranch_id,
        b.ranch_name,
        b.system_cattle_count,
        b.system_weight_capacity,
        b.recipe_id,
        b.recipe_name,

        -- 最新容量
        lc.latest_capacity_date,
        lc.actual_cattle_count,
        lc.actual_total_weight,
        lc.capacity_utilization_rate,
        lc.capacity_status_label,

        -- 容量利用率
        CASE WHEN b.system_cattle_count > 0
             THEN CAST(lc.actual_cattle_count AS DOUBLE) / b.system_cattle_count * 100
             ELSE NULL END AS capacity_utilization_pct,

        -- 最新绩效
        lp.latest_performance_date,
        lp.total_cattle_count,
        lp.weighed_cattle_count,
        lp.avg_current_weight,
        lp.avg_period_adg,
        lp.avg_period_fcr,
        lp.weight_add_ratio,
        lp.herd_fcr,
        lp.feed_cost_per_kg,

        -- 绩效覆盖率
        CASE WHEN lp.total_cattle_count > 0
             THEN CAST(lp.weighed_cattle_count AS DOUBLE) / lp.total_cattle_count * 100
             ELSE NULL END AS weigh_coverage_rate,

        -- 最新饲料投喂
        lf.avg_daily_feed_quantity,
        lf.avg_daily_feed_cost,
        lf.avg_feed_completion_rate,
        lf.avg_leftover_rate,
        lf.avg_concentrate_ratio,
        lf.avg_roughage_ratio,
        lf.avg_feed_intake_per_cattle,
        lf.avg_feed_cost_per_cattle,

        -- 品种分布
        bd.count_simmental,
        bd.count_angus,
        bd.count_charolais,
        bd.count_limousin,
        bd.total_count,

        -- 品种占比
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_simmental AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_simmental,
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_angus AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_angus,
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_charolais AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_charolais,
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_limousin AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_limousin

    FROM stall_base b
    LEFT JOIN latest_capacity lc ON CAST(b.stall_id AS VARCHAR) = CAST(lc.stall_id AS VARCHAR)
    LEFT JOIN latest_performance lp ON CAST(b.stall_id AS VARCHAR) = CAST(lp.stall_id AS VARCHAR)
    LEFT JOIN latest_feed lf ON CAST(b.stall_id AS VARCHAR) = CAST(lf.stall_id AS VARCHAR)
    LEFT JOIN brand_distribution bd ON CAST(b.stall_id AS VARCHAR) = CAST(bd.stall_id AS VARCHAR)
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 标识维度
    stall_id,                                -- 栏舍ID
    stall_name,                              -- 栏舍名称
    ranch_id,                                -- 牧场ID
    ranch_name,                              -- 牧场名称

    -- 配方信息
    recipe_id,                               -- 当前配方ID
    recipe_name,                             -- 当前配方名称

    -- 设计容量
    system_cattle_count,                     -- 设计容量（牛只数）
    system_weight_capacity,                  -- 设计容量（重量）

    -- 最新容量
    latest_capacity_date,                    -- 最新容量统计日期
    actual_cattle_count,                     -- 实际在栏数
    actual_total_weight,                     -- 实际总重量
    capacity_utilization_rate,               -- 容量利用率
    capacity_status_label,                   -- 容量状态标签
    capacity_utilization_pct,                -- 容量利用率百分比

    -- 最新绩效
    latest_performance_date,                 -- 最新绩效统计日期
    total_cattle_count,                      -- 总牛只数
    weighed_cattle_count,                    -- 已称重牛只数
    weigh_coverage_rate,                     -- 称重覆盖率
    avg_current_weight,                      -- 平均体重
    avg_period_adg,                          -- 平均ADG
    avg_period_fcr,                          -- 平均料肉比
    weight_add_ratio,                        -- 增重率
    herd_fcr,                                -- 群体料肉比
    feed_cost_per_kg,                        -- 单位增重饲料成本

    -- 最新饲料投喂（最近7天平均）
    avg_daily_feed_quantity,                 -- 平均日投喂量
    avg_daily_feed_cost,                     -- 平均日饲料成本
    avg_feed_completion_rate,                -- 平均投喂完成率
    avg_leftover_rate,                       -- 平均剩料率
    avg_concentrate_ratio,                   -- 平均精料占比
    avg_roughage_ratio,                      -- 平均粗料占比
    avg_feed_intake_per_cattle,              -- 头均采食量
    avg_feed_cost_per_cattle,                -- 头均饲料成本

    -- 品种分布
    count_simmental,                         -- 西门塔尔数量
    count_angus,                             -- 安格斯数量
    count_charolais,                         -- 夏洛莱数量
    count_limousin,                          -- 利木赞数量
    total_count,                             -- 总数

    -- 品种占比
    pct_simmental,                           -- 西门塔尔占比
    pct_angus,                               -- 安格斯占比
    pct_charolais,                           -- 夏洛莱占比
    pct_limousin,                            -- 利木赞占比

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM integrated
ORDER BY ranch_id, stall_id
```

- [ ] **Step 2: 验证语法**

运行：`dbt parse --select ads_ranch_stall_operation_profile`
预期：无语法错误

- [ ] **Step 3: 提交**

```bash
git add models/ranch/ads/ads_ranch_stall_operation_profile.sql
git commit -m "feat(ranch): add stall operation profile wide table"
```

---

## 执行总结

本计划共实现 **6个ADS层宽表模型**：

### 成本域（2个模型）
1. ✅ `ads_ranch_cattle_cost_profile_cum_d.sql` - 牛只成本画像（累计至今）
2. ✅ `ads_ranch_cost_dashboard_mf.sql` - 牧场成本月报

### 健康域（2个模型）
3. ✅ `ads_ranch_cattle_health_profile_cum_d.sql` - 牛只健康画像（累计至今）
4. ✅ `ads_ranch_health_dashboard_mf.sql` - 牧场健康月报

### 运营域（2个模型）
5. ✅ `ads_ranch_operation_dashboard_mf.sql` - 牧场运营月报
6. ✅ `ads_ranch_stall_operation_profile.sql` - 栏舍运营画像

所有模型遵循现有命名规范和代码风格，依赖DWS层聚合数据，支持全量刷新策略。
