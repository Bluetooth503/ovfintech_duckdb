-- =============================================
-- 模型名称：dws_ranch_cattle_growth_agg_1m_m
-- 模型描述：牧场牛只生长月统计表，按自然月统计牛只生长指标
-- 作者：dbt
-- 创建时间：2026-04-07
-- 更新方式：增量（按自然月）
-- 粒度：牧场 + 栏舍 + SKU + 自然月
-- 说明：
--   - 数据源：dws_ranch_cattle_snapshot_1d_d（牛只日快照）
--   - 增量策略：按自然月追加
--   - 统计指标：ADG、增重、体重分布等生长指标
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['natural_month'],
    description='牧场牛只生长月统计表，按自然月统计牛只的生长指标（ADG、增重、体重分布等）',
    tags=['ranch', 'dws', 'agg', 'cattle', 'growth', 'monthly']
) }}

WITH cattle_snap AS (
    -- 从牛只日快照表获取数据
    SELECT
        natural_month,
        stats_date,
        cattle_id,
        cattle_code,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        customer_id,

        -- 体重相关
        current_weight,
        in_stall_weight,
        weight_bucket,

        -- 日龄相关
        age_days,
        months_in_stall,
        months_in_stall_bucket,

        -- ADG相关
        period_adg,
        adg_overall_adg,
        interval_days

    FROM {{ ref('dws_ranch_cattle_snapshot_1d_d') }}
    WHERE stats_date IS NOT NULL
),

-- 按自然月 + 牧场 + 栏舍 + SKU 维度聚合
growth_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        customer_id,

        -- ====================
        -- 时间维度
        -- ====================
        MIN(stats_date) AS month_start_date,
        MAX(stats_date) AS month_end_date,
        COUNT(DISTINCT stats_date) AS valid_days,

        -- ====================
        -- 数量统计
        -- ====================
        COUNT(DISTINCT cattle_id) AS total_cattle_count,        -- 本月牛只总数
        COUNT(DISTINCT CASE WHEN current_weight IS NOT NULL THEN cattle_id END) AS weighed_cattle_count,  -- 本月称重牛只数

        -- ====================
        -- 体重统计
        -- ====================
        AVG(current_weight) AS avg_weight,                      -- 平均体重
        MIN(current_weight) AS min_weight,                      -- 最小体重
        MAX(current_weight) AS max_weight,                      -- 最大体重
        STDDEV(current_weight) AS stddev_weight,                -- 体重标准差

        -- 体重区间分布
        COUNT(DISTINCT CASE WHEN weight_bucket = '200Kg以下' THEN cattle_id END) AS count_weight_under_200,
        COUNT(DISTINCT CASE WHEN weight_bucket = '200～249Kg' THEN cattle_id END) AS count_weight_200_249,
        COUNT(DISTINCT CASE WHEN weight_bucket = '250～299Kg' THEN cattle_id END) AS count_weight_250_299,
        COUNT(DISTINCT CASE WHEN weight_bucket = '300～349Kg' THEN cattle_id END) AS count_weight_300_349,
        COUNT(DISTINCT CASE WHEN weight_bucket = '350～399Kg' THEN cattle_id END) AS count_weight_350_399,
        COUNT(DISTINCT CASE WHEN weight_bucket = '400～449Kg' THEN cattle_id END) AS count_weight_400_449,
        COUNT(DISTINCT CASE WHEN weight_bucket = '450～499Kg' THEN cattle_id END) AS count_weight_450_499,
        COUNT(DISTINCT CASE WHEN weight_bucket = '500～549Kg' THEN cattle_id END) AS count_weight_500_549,
        COUNT(DISTINCT CASE WHEN weight_bucket = '550～599Kg' THEN cattle_id END) AS count_weight_550_599,
        COUNT(DISTINCT CASE WHEN weight_bucket = '600～649Kg' THEN cattle_id END) AS count_weight_600_649,
        COUNT(DISTINCT CASE WHEN weight_bucket = '650～699Kg' THEN cattle_id END) AS count_weight_650_699,
        COUNT(DISTINCT CASE WHEN weight_bucket = '700～749Kg' THEN cattle_id END) AS count_weight_700_749,
        COUNT(DISTINCT CASE WHEN weight_bucket = '750～799Kg' THEN cattle_id END) AS count_weight_750_799,
        COUNT(DISTINCT CASE WHEN weight_bucket = '800Kg以上' THEN cattle_id END) AS count_weight_over_800,

        -- ====================
        -- ADG统计（区间ADG）
        -- ====================
        AVG(period_adg) AS avg_period_adg,                      -- 平均区间日增重
        MIN(period_adg) AS min_period_adg,                      -- 最小区间日增重
        MAX(period_adg) AS max_period_adg,                      -- 最大区间日增重
        STDDEV(period_adg) AS stddev_period_adg,                -- 区间日增重标准差

        -- ADG分布（按0.1kg分组）
        COUNT(DISTINCT CASE WHEN period_adg < 0.1 THEN cattle_id END) AS count_adg_under_01,
        COUNT(DISTINCT CASE WHEN period_adg >= 0.1 AND period_adg < 0.3 THEN cattle_id END) AS count_adg_01_03,
        COUNT(DISTINCT CASE WHEN period_adg >= 0.3 AND period_adg < 0.5 THEN cattle_id END) AS count_adg_03_05,
        COUNT(DISTINCT CASE WHEN period_adg >= 0.5 AND period_adg < 0.7 THEN cattle_id END) AS count_adg_05_07,
        COUNT(DISTINCT CASE WHEN period_adg >= 0.7 AND period_adg < 0.9 THEN cattle_id END) AS count_adg_07_09,
        COUNT(DISTINCT CASE WHEN period_adg >= 0.9 AND period_adg < 1.1 THEN cattle_id END) AS count_adg_09_11,
        COUNT(DISTINCT CASE WHEN period_adg >= 1.1 THEN cattle_id END) AS count_adg_over_11,

        -- ====================
        -- 在栏月龄分布
        -- ====================
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '1月' THEN cattle_id END) AS count_month_1,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '2月' THEN cattle_id END) AS count_month_2,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '3月' THEN cattle_id END) AS count_month_3,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '4月' THEN cattle_id END) AS count_month_4,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '5月' THEN cattle_id END) AS count_month_5,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '6月' THEN cattle_id END) AS count_month_6,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '7月' THEN cattle_id END) AS count_month_7,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '8月' THEN cattle_id END) AS count_month_8,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '9月' THEN cattle_id END) AS count_month_9,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '10月' THEN cattle_id END) AS count_month_10,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '11月' THEN cattle_id END) AS count_month_11,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '12月' THEN cattle_id END) AS count_month_12,
        COUNT(DISTINCT CASE WHEN months_in_stall_bucket = '12月以上' THEN cattle_id END) AS count_month_over_12,

        CURRENT_TIMESTAMP AS dw_update_time

    FROM cattle_snap
    GROUP BY
        natural_month,
        ranch_id, ranch_name,
        stall_id, stall_name,
        cattle_sku_id, cattle_sku_name, brand_name,
        customer_id
)

SELECT
    -- ====================
    -- 维度字段
    -- ====================
    natural_month,
    month_start_date,
    month_end_date,
    valid_days,
    ranch_id,
    ranch_name,
    stall_id,
    stall_name,
    cattle_sku_id,
    cattle_sku_name,
    brand_name,
    customer_id,

    -- ====================
    -- 数量统计
    -- ====================
    total_cattle_count,
    weighed_cattle_count,
    ROUND(CAST(weighed_cattle_count AS DOUBLE) / NULLIF(total_cattle_count, 0) * 100, 2) AS weigh_coverage_rate,  -- 称重覆盖率

    -- ====================
    -- 体重统计（四舍五入保留2位小数）
    -- ====================
    ROUND(avg_weight, 2) AS avg_weight,
    ROUND(min_weight, 2) AS min_weight,
    ROUND(max_weight, 2) AS max_weight,
    ROUND(stddev_weight, 2) AS stddev_weight,

    -- 体重区间分布
    count_weight_under_200,
    count_weight_200_249,
    count_weight_250_299,
    count_weight_300_349,
    count_weight_350_399,
    count_weight_400_449,
    count_weight_450_499,
    count_weight_500_549,
    count_weight_550_599,
    count_weight_600_649,
    count_weight_650_699,
    count_weight_700_749,
    count_weight_750_799,
    count_weight_over_800,

    -- ====================
    -- ADG统计（四舍五入保留3位小数）
    -- ====================
    ROUND(avg_period_adg, 3) AS avg_period_adg,
    ROUND(min_period_adg, 3) AS min_period_adg,
    ROUND(max_period_adg, 3) AS max_period_adg,
    ROUND(stddev_period_adg, 3) AS stddev_period_adg,

    -- ADG分布
    count_adg_under_01,
    count_adg_01_03,
    count_adg_03_05,
    count_adg_05_07,
    count_adg_07_09,
    count_adg_09_11,
    count_adg_over_11,

    -- ====================
    -- 在栏月龄分布
    -- ====================
    count_month_1,
    count_month_2,
    count_month_3,
    count_month_4,
    count_month_5,
    count_month_6,
    count_month_7,
    count_month_8,
    count_month_9,
    count_month_10,
    count_month_11,
    count_month_12,
    count_month_over_12,

    dw_update_time

FROM growth_monthly

-- {% if is_incremental() %}
-- WHERE natural_month > (SELECT COALESCE(MAX(natural_month), 0) FROM {{ this }})
-- {% endif %}

ORDER BY natural_month DESC, ranch_id, stall_id, cattle_sku_id
