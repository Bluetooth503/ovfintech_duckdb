-- =============================================
-- 模型名称：ads_ranch_cattle_asset_dashboard_mf
-- 模型描述：牧场资产运营月报，按牧场+栏舍+品种+自然月统计资产流动与生长绩效
-- Dbt更新方式：全量
-- 粒度：牧场 + 栏舍 + 品种 + 自然月
-- 说明：
--   - 数据源：DWS月统计表
--   - 增量策略：全量刷新（table）
--   - 统计指标：期初期末、资产流动、生长绩效、体重/月龄分布
--   - 聚合逻辑：资产域运营监控，按牧场+栏舍+品种+自然月聚合
-- =============================================
{{ config(
    materialized='table',
    description='牧场资产运营月报，按牧场+栏舍+品种+自然月统计期初期末、资产流动、生长绩效及分布指标',
    tags=['ranch', 'ads', 'asset', 'dashboard', 'monthly']
) }}

-- ============================================
-- 1. 生长指标基础（来自DWS月统计）
-- ============================================
WITH growth_base AS (
    SELECT
        natural_month, ranch_id, ranch_name, stall_id, stall_name, cattle_sku_id, cattle_sku_name, brand_name, customer_id,
        month_start_date, month_end_date, valid_days, total_cattle_count, weighed_cattle_count, weigh_coverage_rate,
        avg_weight, min_weight, max_weight, stddev_weight, avg_period_adg, min_period_adg, max_period_adg, stddev_period_adg,
        count_weight_under_200, count_weight_200_249, count_weight_250_299, count_weight_300_349, count_weight_350_399,
        count_weight_400_449, count_weight_450_499, count_weight_500_549, count_weight_550_599, count_weight_600_649,
        count_weight_650_699, count_weight_700_749, count_weight_750_799, count_weight_over_800,
        count_adg_under_01, count_adg_01_03, count_adg_03_05, count_adg_05_07, count_adg_07_09, count_adg_09_11, count_adg_over_11,
        count_month_1, count_month_2, count_month_3, count_month_4, count_month_5, count_month_6,
        count_month_7, count_month_8, count_month_9, count_month_10, count_month_11, count_month_12, count_month_over_12
    FROM {{ ref('dws_ranch_cattle_growth_agg_mi') }}
),

-- ============================================
-- 2. 期初期末在栏数（来自DWS月度快照聚合表）
-- ============================================
inventory_monthly AS (
    SELECT
        natural_month, ranch_id, stall_id, cattle_sku_id,
        begin_cattle_count, begin_avg_weight, begin_total_loan,
        end_cattle_count, end_avg_weight, end_total_loan, end_avg_weight_add, end_total_feed_cost
    FROM {{ ref('dws_ranch_cattle_inventory_snap_mf') }}
),

-- ============================================
-- 3. 月度入栏数（来自DWS月度聚合表）
-- ============================================
install_month AS (
    SELECT
        natural_month, ranch_id, stall_id, cattle_sku_id,
        install_count, install_total_weight, install_avg_weight
    FROM {{ ref('dws_ranch_cattle_install_agg_mf') }}
),

-- ============================================
-- 4. 月度出栏数（来自DWS月度聚合表）
-- ============================================
sell_month AS (
    SELECT
        natural_month, ranch_id, stall_id, cattle_sku_id,
        sell_count, sell_total_weight, sell_avg_weight, sell_total_amount
    FROM {{ ref('dws_ranch_cattle_sell_agg_mf') }}
),

-- ============================================
-- 5. 月度退回数（来自DWS月度聚合表）
-- ============================================
return_month AS (
    SELECT
        natural_month, ranch_id, stall_id, cattle_sku_id,
        return_count, return_total_weight
    FROM {{ ref('dws_ranch_cattle_return_agg_mf') }}
),

-- ============================================
-- 6. 增重率计算（基于月末快照，来自DWS）
-- ============================================
weight_gain_agg AS (
    SELECT
        s.natural_month, s.ranch_id, s.stall_id, s.cattle_sku_id,
        AVG(s.current_weight - s.in_stall_weight) AS avg_weight_gain,
        AVG(s.in_stall_weight) AS avg_in_stall_weight
    FROM {{ ref('dws_ranch_cattle_weigh_agg_i') }} s
    INNER JOIN (SELECT natural_month, MAX(stats_date) AS last_date FROM {{ ref('dws_ranch_cattle_weigh_agg_i') }} GROUP BY natural_month) ml ON s.natural_month = ml.natural_month AND s.stats_date = ml.last_date
    WHERE s.in_stall_weight IS NOT NULL AND s.current_weight IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

-- ============================================
-- 7. 统一主键表（避免多层 FULL OUTER JOIN）
-- ============================================
all_keys AS (
    SELECT natural_month, ranch_id, stall_id, cattle_sku_id FROM growth_base
    UNION
    SELECT natural_month, ranch_id, stall_id, cattle_sku_id FROM inventory_monthly
    UNION
    SELECT natural_month, ranch_id, stall_id, cattle_sku_id FROM install_month
    UNION
    SELECT natural_month, ranch_id, stall_id, cattle_sku_id FROM sell_month
    UNION
    SELECT natural_month, ranch_id, stall_id, cattle_sku_id FROM return_month
),

-- ============================================
-- 8. 数据整合
-- ============================================
integrated AS (
    SELECT
        k.natural_month,
        COALESCE(g.month_start_date, DATE_TRUNC('month', DATE(SUBSTRING(CAST(k.natural_month AS VARCHAR), 1, 4) || '-' || SUBSTRING(CAST(k.natural_month AS VARCHAR), 5, 2) || '-01'))::DATE) AS month_start_date,
        COALESCE(g.month_end_date, (DATE_TRUNC('month', DATE(SUBSTRING(CAST(k.natural_month AS VARCHAR), 1, 4) || '-' || SUBSTRING(CAST(k.natural_month AS VARCHAR), 5, 2) || '-01')) + INTERVAL '1 month' - INTERVAL '1 day')::DATE) AS month_end_date,
        k.ranch_id,
        COALESCE(g.ranch_name, dr.ranch_name) AS ranch_name,
        k.stall_id,
        COALESCE(g.stall_name, ds.stall_name) AS stall_name,
        k.cattle_sku_id,
        COALESCE(g.cattle_sku_name, dk.sku_name) AS cattle_sku_name,
        COALESCE(g.brand_name, dk.brand_name) AS brand_name,
        g.customer_id,

        -- 期初期末（来自DWS月度快照聚合表）
        inv.begin_cattle_count,
        inv.end_cattle_count,

        -- 资产流动（来自DWS月度聚合表）
        i.install_count,
        s.sell_count,
        r.return_count,
        COALESCE(i.install_count, 0) - COALESCE(s.sell_count, 0) - COALESCE(r.return_count, 0) AS net_change_count,

        -- 出栏率
        CASE WHEN inv.begin_cattle_count > 0 THEN ROUND(CAST(s.sell_count AS DOUBLE) / inv.begin_cattle_count * 100, 2) ELSE NULL END AS sell_rate,

        -- 生长指标（来自DWS月统计）
        g.total_cattle_count, g.weighed_cattle_count, g.weigh_coverage_rate,
        g.avg_weight, g.min_weight, g.max_weight, g.stddev_weight,
        g.avg_period_adg, g.min_period_adg, g.max_period_adg, g.stddev_period_adg,

        -- 体重分布
        g.count_weight_under_200, g.count_weight_200_249, g.count_weight_250_299, g.count_weight_300_349, g.count_weight_350_399,
        g.count_weight_400_449, g.count_weight_450_499, g.count_weight_500_549, g.count_weight_550_599, g.count_weight_600_649,
        g.count_weight_650_699, g.count_weight_700_749, g.count_weight_750_799, g.count_weight_over_800,

        -- ADG分布
        g.count_adg_under_01, g.count_adg_01_03, g.count_adg_03_05, g.count_adg_05_07, g.count_adg_07_09, g.count_adg_09_11, g.count_adg_over_11,

        -- 月龄分布
        g.count_month_1, g.count_month_2, g.count_month_3, g.count_month_4, g.count_month_5, g.count_month_6,
        g.count_month_7, g.count_month_8, g.count_month_9, g.count_month_10, g.count_month_11, g.count_month_12, g.count_month_over_12,

        -- 增重率
        wg.avg_weight_gain,
        CASE WHEN wg.avg_in_stall_weight > 0 THEN ROUND(wg.avg_weight_gain / wg.avg_in_stall_weight * 100, 2) ELSE NULL END AS weight_add_ratio,

        -- 期初期末体重（来自DWS月度快照聚合表）
        inv.begin_avg_weight,
        inv.end_avg_weight,

        -- 流动体重（来自DWS月度聚合表）
        i.install_total_weight, i.install_avg_weight,
        s.sell_total_weight, s.sell_avg_weight, s.sell_total_amount,
        r.return_total_weight,

        -- 期末资产价值（来自DWS月度快照聚合表）
        inv.end_total_loan, inv.end_total_feed_cost

    FROM all_keys k
    LEFT JOIN growth_base g ON k.natural_month = g.natural_month AND k.ranch_id = g.ranch_id AND k.stall_id = g.stall_id AND k.cattle_sku_id = g.cattle_sku_id
    LEFT JOIN inventory_monthly inv ON k.natural_month = inv.natural_month AND k.ranch_id = inv.ranch_id AND k.stall_id = inv.stall_id AND k.cattle_sku_id = inv.cattle_sku_id
    LEFT JOIN install_month i ON k.natural_month = i.natural_month AND k.ranch_id = i.ranch_id AND k.stall_id = i.stall_id AND k.cattle_sku_id = i.cattle_sku_id
    LEFT JOIN sell_month s ON k.natural_month = s.natural_month AND k.ranch_id = s.ranch_id AND k.stall_id = s.stall_id AND k.cattle_sku_id = s.cattle_sku_id
    LEFT JOIN return_month r ON k.natural_month = r.natural_month AND k.ranch_id = r.ranch_id AND k.stall_id = r.stall_id AND k.cattle_sku_id = r.cattle_sku_id
    LEFT JOIN weight_gain_agg wg ON k.natural_month = wg.natural_month AND k.ranch_id = wg.ranch_id AND k.stall_id = wg.stall_id AND k.cattle_sku_id = wg.cattle_sku_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON k.ranch_id = dr.ranch_id
    LEFT JOIN {{ ref('dim_ranch_stall') }} ds ON k.stall_id = ds.stall_id AND ds.is_current = '1'
    LEFT JOIN {{ ref('dim_ranch_sku') }} dk ON k.cattle_sku_id = dk.sku_id AND dk.is_current = '1'
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    natural_month, month_start_date, month_end_date, ranch_id, ranch_name, stall_id, stall_name, cattle_sku_id, cattle_sku_name, brand_name, customer_id,

    -- 期初期末
    begin_cattle_count, end_cattle_count,

    -- 资产流动
    install_count, sell_count, return_count, net_change_count, sell_rate,

    -- 数量与称重
    total_cattle_count, weighed_cattle_count, weigh_coverage_rate,

    -- 体重指标
    avg_weight, min_weight, max_weight, stddev_weight,

    -- ADG指标
    avg_period_adg, min_period_adg, max_period_adg, stddev_period_adg,

    -- 增重率
    avg_weight_gain, weight_add_ratio,

    -- 体重分布
    count_weight_under_200, count_weight_200_249, count_weight_250_299, count_weight_300_349, count_weight_350_399,
    count_weight_400_449, count_weight_450_499, count_weight_500_549, count_weight_550_599, count_weight_600_649,
    count_weight_650_699, count_weight_700_749, count_weight_750_799, count_weight_over_800,

    -- ADG分布
    count_adg_under_01, count_adg_01_03, count_adg_03_05, count_adg_05_07, count_adg_07_09, count_adg_09_11, count_adg_over_11,

    -- 月龄分布
    count_month_1, count_month_2, count_month_3, count_month_4, count_month_5, count_month_6,
    count_month_7, count_month_8, count_month_9, count_month_10, count_month_11, count_month_12, count_month_over_12,

    -- 期初期末体重
    begin_avg_weight, end_avg_weight,

    -- 流动体重
    install_total_weight, install_avg_weight, sell_total_weight, sell_avg_weight, sell_total_amount, return_total_weight,

    -- 资金与成本
    end_total_loan, end_total_feed_cost,

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time

FROM integrated
ORDER BY natural_month DESC, ranch_id, stall_id, cattle_sku_id
