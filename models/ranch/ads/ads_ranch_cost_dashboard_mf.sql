-- =============================================
-- 模型名称：ads_ranch_cost_dashboard_mf
-- 模型描述：牧场成本运营月报，按牧场+自然月统计成本构成、效率指标及出栏成本回收
-- Dbt更新方式：全量
-- 粒度：牧场 + 自然月
-- 说明：
--   - 数据源：dws_ranch_stall_feed_agg_di + dws_ranch_cattle_purchase_agg_di + dws_ranch_cattle_sell_agg_mf + dws_ranch_cattle_inventory_snap_mf
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
        EXTRACT(YEAR FROM stat_date) * 100 + EXTRACT(MONTH FROM stat_date) AS natural_month,
        ranch_id,
        SUM(total_amount) AS month_purchase_cost,
        SUM(purchase_count) AS month_purchase_count,
        SUM(total_weight) AS month_purchase_weight,
        AVG(avg_unit_price) AS avg_purchase_unit_price
    FROM {{ ref('dws_ranch_cattle_purchase_agg_di') }}
    WHERE stat_date IS NOT NULL
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
        SUM(roughage_quantity) AS month_roughage_quantity
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
        SUM(sell_total_amount) AS month_sell_revenue,  -- 出栏收入（用于成本回收分析）
        COUNT(DISTINCT cattle_sku_id) AS month_sell_sku_count,
        SUM(sell_count) AS month_sell_count,
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
        SUM(end_cattle_count) AS end_cattle_count,
        SUM(end_total_feed_cost) AS end_total_feed_cost
    FROM {{ ref('dws_ranch_cattle_inventory_snap_mf') }}
    GROUP BY 1, 2
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