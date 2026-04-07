-- =============================================
-- 模型名称：dws_ranch_stall_performance_agg_1d_d
-- 模型描述：栏舍绩效日统计表，按日期统计栏舍的运营绩效指标
-- 作者：dbt
-- 创建时间：2026-04-07
-- 更新方式：增量（按日期）
-- 粒度：牧场 + 栏舍 + 日期
-- 说明：
--   - 数据源：dws_ranch_cattle_snapshot_1d_d + dws_ranch_cattle_adg_agg_i
--   - 增量策略：按日期追加
--   - 统计指标：ADG、料肉比、增重率、周转率等绩效指标
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_date'],
    description='栏舍绩效日统计表，按日期统计栏舍的运营绩效指标（ADG、料肉比、增重率、周转率等）',
    tags=['ranch', 'dws', 'agg', 'stall', 'performance', 'daily']
) }}

WITH cattle_snap AS (
    -- 从牛只日快照表获取数据
    SELECT
        stats_date,
        natural_week,
        natural_month,
        cattle_id,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        customer_id,
        current_weight,
        in_stall_weight,
        in_stall_date,
        weight_bucket,
        period_adg,
        adg_overall_adg
    FROM {{ ref('dws_ranch_cattle_snapshot_1d_d') }}
    WHERE stats_date IS NOT NULL
),

adg_data AS (
    -- 从ADG区间汇总表获取料肉比数据
    SELECT
        stats_date,
        cattle_id,
        period_fcr,
        period_feed_consumption,
        period_feed_cost,
        period_weight_gain
    FROM {{ ref('dws_ranch_cattle_adg_agg_i') }}
    WHERE stats_date IS NOT NULL
),

-- 关联ADG数据
cattle_with_adg AS (
    SELECT
        s.stats_date,
        s.natural_week,
        s.natural_month,
        s.cattle_id,
        s.ranch_id,
        s.ranch_name,
        s.stall_id,
        s.stall_name,
        s.cattle_sku_id,
        s.cattle_sku_name,
        s.customer_id,
        s.current_weight,
        s.in_stall_weight,
        s.in_stall_date,
        s.period_adg,
        s.adg_overall_adg,
        a.period_fcr,
        a.period_feed_consumption,
        a.period_feed_cost,
        a.period_weight_gain
    FROM cattle_snap s
    LEFT JOIN adg_data a ON s.stats_date = a.stats_date AND s.cattle_id = a.cattle_id
),

-- 按牧场 + 栏舍 + 日期维度聚合
performance_daily AS (
    SELECT
        stats_date,
        natural_week,
        natural_month,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,

        -- 数量统计
        COUNT(DISTINCT cattle_id) AS total_cattle_count,
        COUNT(DISTINCT CASE WHEN current_weight IS NOT NULL THEN cattle_id END) AS weighed_cattle_count,
        COUNT(DISTINCT CASE WHEN period_adg IS NOT NULL THEN cattle_id END) AS adg_valid_count,
        COUNT(DISTINCT CASE WHEN period_fcr IS NOT NULL THEN cattle_id END) AS fcr_valid_count,

        -- 体重统计
        SUM(current_weight) AS total_current_weight,
        AVG(current_weight) AS avg_current_weight,
        SUM(in_stall_weight) AS total_install_weight,
        SUM(current_weight - in_stall_weight) AS total_weight_add,
        AVG(current_weight - in_stall_weight) AS avg_weight_add,

        -- ADG统计（区间ADG）
        AVG(period_adg) AS avg_period_adg,
        MIN(period_adg) AS min_period_adg,
        MAX(period_adg) AS max_period_adg,
        STDDEV(period_adg) AS stddev_period_adg,
        AVG(adg_overall_adg) AS avg_overall_adg,

        -- 料肉比统计
        AVG(period_fcr) AS avg_period_fcr,
        MIN(period_fcr) AS min_period_fcr,
        MAX(period_fcr) AS max_period_fcr,
        SUM(period_feed_consumption) AS total_feed_consumption,
        SUM(period_feed_cost) AS total_feed_cost,
        AVG(period_feed_consumption) AS avg_feed_consumption,

        -- 增重率(%)
        CASE WHEN SUM(in_stall_weight) > 0 THEN SUM(current_weight - in_stall_weight) / SUM(in_stall_weight) * 100 ELSE NULL END AS weight_add_ratio,

        -- 周转率（入栏天数分布）
        COUNT(DISTINCT CASE WHEN in_stall_date IS NOT NULL AND DATEDIFF('day', in_stall_date, stats_date) < 30 THEN cattle_id END) AS count_under_30d,
        COUNT(DISTINCT CASE WHEN in_stall_date IS NOT NULL AND DATEDIFF('day', in_stall_date, stats_date) >= 30 AND DATEDIFF('day', in_stall_date, stats_date) < 60 THEN cattle_id END) AS count_30_60d,
        COUNT(DISTINCT CASE WHEN in_stall_date IS NOT NULL AND DATEDIFF('day', in_stall_date, stats_date) >= 60 AND DATEDIFF('day', in_stall_date, stats_date) < 90 THEN cattle_id END) AS count_60_90d,
        COUNT(DISTINCT CASE WHEN in_stall_date IS NOT NULL AND DATEDIFF('day', in_stall_date, stats_date) >= 90 AND DATEDIFF('day', in_stall_date, stats_date) < 120 THEN cattle_id END) AS count_90_120d,
        COUNT(DISTINCT CASE WHEN in_stall_date IS NOT NULL AND DATEDIFF('day', in_stall_date, stats_date) >= 120 AND DATEDIFF('day', in_stall_date, stats_date) < 150 THEN cattle_id END) AS count_120_150d,
        COUNT(DISTINCT CASE WHEN in_stall_date IS NOT NULL AND DATEDIFF('day', in_stall_date, stats_date) >= 150 AND DATEDIFF('day', in_stall_date, stats_date) < 180 THEN cattle_id END) AS count_150_180d,
        COUNT(DISTINCT CASE WHEN in_stall_date IS NOT NULL AND DATEDIFF('day', in_stall_date, stats_date) >= 180 THEN cattle_id END) AS count_over_180d,

        -- 饲料效率指标
        CASE WHEN SUM(period_weight_gain) > 0 AND SUM(period_feed_consumption) IS NOT NULL THEN SUM(period_feed_consumption) / SUM(period_weight_gain) ELSE NULL END AS herd_fcr,
        CASE WHEN SUM(period_weight_gain) > 0 AND SUM(period_feed_cost) IS NOT NULL THEN SUM(period_feed_cost) / SUM(period_weight_gain) ELSE NULL END AS feed_cost_per_kg,

        CURRENT_TIMESTAMP AS dw_update_time

    FROM cattle_with_adg
    GROUP BY
        stats_date,
        natural_week,
        natural_month,
        ranch_id, ranch_name,
        stall_id, stall_name
)

SELECT
    -- 时间维度
    stats_date,
    natural_week,
    natural_month,

    -- 组织维度
    ranch_id,
    ranch_name,
    stall_id,
    stall_name,

    -- 数量统计
    total_cattle_count,
    weighed_cattle_count,
    adg_valid_count,
    fcr_valid_count,

    -- 体重统计
    ROUND(total_current_weight, 2) AS total_current_weight,
    ROUND(avg_current_weight, 2) AS avg_current_weight,
    ROUND(total_install_weight, 2) AS total_install_weight,
    ROUND(total_weight_add, 2) AS total_weight_add,
    ROUND(avg_weight_add, 2) AS avg_weight_add,

    -- ADG统计
    ROUND(avg_period_adg, 3) AS avg_period_adg,
    ROUND(min_period_adg, 3) AS min_period_adg,
    ROUND(max_period_adg, 3) AS max_period_adg,
    ROUND(stddev_period_adg, 3) AS stddev_period_adg,
    ROUND(avg_overall_adg, 3) AS avg_overall_adg,

    -- 料肉比统计
    ROUND(avg_period_fcr, 2) AS avg_period_fcr,
    ROUND(min_period_fcr, 2) AS min_period_fcr,
    ROUND(max_period_fcr, 2) AS max_period_fcr,
    ROUND(total_feed_consumption, 2) AS total_feed_consumption,
    ROUND(total_feed_cost, 2) AS total_feed_cost,
    ROUND(avg_feed_consumption, 2) AS avg_feed_consumption,

    -- 增重率
    ROUND(weight_add_ratio, 2) AS weight_add_ratio,

    -- 周转分布
    count_under_30d,
    count_30_60d,
    count_60_90d,
    count_90_120d,
    count_120_150d,
    count_150_180d,
    count_over_180d,

    -- 饲料效率指标
    ROUND(herd_fcr, 2) AS herd_fcr,
    ROUND(feed_cost_per_kg, 2) AS feed_cost_per_kg,

    -- 派生指标
    ROUND(CAST(weighed_cattle_count AS DOUBLE) / NULLIF(total_cattle_count, 0) * 100, 2) AS weigh_coverage_rate,
    ROUND(CAST(adg_valid_count AS DOUBLE) / NULLIF(total_cattle_count, 0) * 100, 2) AS adg_coverage_rate,
    ROUND(CAST(fcr_valid_count AS DOUBLE) / NULLIF(total_cattle_count, 0) * 100, 2) AS fcr_coverage_rate,

    -- 元数据
    dw_update_time

FROM performance_daily

-- {% if is_incremental() %}
-- WHERE stats_date > (SELECT COALESCE(MAX(stats_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}

ORDER BY stats_date DESC, ranch_id, stall_id
