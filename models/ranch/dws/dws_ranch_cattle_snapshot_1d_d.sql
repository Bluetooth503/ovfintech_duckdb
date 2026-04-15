-- =============================================
-- 模型名称：dws_ranch_cattle_snapshot_1d_d
-- 模型描述：牧场牛只每日快照宽表，整合牛只多维度指标
-- 作者：dbt
-- 创建时间：2026-04-07
-- 说明：
--   - 粒度：每头牛每个称重日期一条记录
--   - 用途：作为ADS层报表、分析等应用的统一数据源
--   - 数据整合：
--     * 称重交易数据（dwd_ranch_cattle_weight_trx_i）
--     * ADG区间汇总（dws_ranch_cattle_adg_agg_i）
--     * 活牛价格数据（dwd_ranch_cattle_price_trx_i）
--     * 牛只维度信息（dim_ranch_cattle）
--   - 计算字段：
--     * 在栏月龄区间（months_in_stall_bucket）
--     * 体重区间（weight_bucket）
--     * 自然周、自然月
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_date'],
    description='牧场牛只每日快照宽表，整合牛只的体重、月龄、品种、ADG、价格等多维度指标',
    tags=['ranch', 'dws', 'cattle', 'snapshot', 'daily', 'incremental']
) }}

WITH
-- ============================================
-- 源数据1：称重交易（获取体重、日龄等测量数据）
-- ============================================
weight_trx AS (
    SELECT
        cattle_id,
        weight_date AS stats_date,
        weight AS current_weight,
        stall_id,
        customer_id,
        weight_days
    FROM {{ ref('dwd_ranch_cattle_weight_trx_i') }}
    WHERE weight_date IS NOT NULL
),

-- ============================================
-- 源数据2：牛只维度（获取品种、入栏信息等）
-- ============================================
lkp_cattle AS (
    SELECT
        cattle_id,
        cattle_code,
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        customer_id,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        birth_date,
        in_stall_date,
        in_stall_weight
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- ADG数据：区间ADG（用于报表4的ADG统计）
-- ============================================
adg_data AS (
    SELECT
        stats_date,
        cattle_id,
        period_adg,
        overall_adg,
        prev_weight_date,
        interval_days
    FROM {{ ref('dws_ranch_cattle_adg_agg_i') }}
    WHERE stats_date IS NOT NULL
),

-- ============================================
-- 价格数据：活牛价格（用于报表5的价格走势）
-- 从psi_cattle_price获取按品种+日期的价格数据
-- ============================================
price_data AS (
    SELECT DISTINCT ON (sku_id, price_change_date)
        price_change_date AS stats_date,
        sku_id AS cattle_sku_id,
        ranch_id,
        unit_price AS cattle_price,
        start_weight,
        end_weight
    FROM {{ ref('dwd_ranch_cattle_price_trx_i') }}
    WHERE price_change_date IS NOT NULL
    ORDER BY sku_id, price_change_date, update_time DESC
),

-- ============================================
-- 整合数据：关联所有数据源
-- ============================================
integrated_data AS (
    SELECT
        -- ====================
        -- 时间维度
        -- ====================
        w.stats_date,
        -- 计算自然周（ISO周：YEAR-WEEK格式）
        EXTRACT(YEAR FROM w.stats_date) * 100 + EXTRACT(WEEK FROM w.stats_date) AS natural_week,
        -- 计算自然月（YEAR-MONTH格式）
        EXTRACT(YEAR FROM w.stats_date) * 100 + EXTRACT(MONTH FROM w.stats_date) AS natural_month,

        -- ====================
        -- 组织维度
        -- ====================
        COALESCE(w.customer_id, c.customer_id::VARCHAR) AS customer_id,
        c.ranch_id,
        c.ranch_name,
        COALESCE(w.stall_id, c.stall_id) AS stall_id,
        c.stall_name,

        -- ====================
        -- 品种维度
        -- ====================
        c.cattle_sku_id,
        c.cattle_sku_name,
        c.brand_name,

        -- ====================
        -- 牛只维度
        -- ====================
        w.cattle_id,
        c.cattle_code,

        -- ====================
        -- 牛只属性
        -- ====================
        c.birth_date,
        c.in_stall_date,
        c.in_stall_weight,
        w.current_weight,
        -- 计算日龄
        CASE WHEN c.birth_date IS NOT NULL THEN DATE_DIFF('day', c.birth_date, w.stats_date) ELSE NULL END AS age_days,

        -- 计算在栏月数
        CASE WHEN c.in_stall_date IS NOT NULL THEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) ELSE NULL END AS months_in_stall,

        -- 计算在栏月龄区间（1月、2月、...、12月、12月以上）
        CASE
            WHEN c.in_stall_date IS NULL THEN NULL
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 1 THEN '1月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 2 THEN '2月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 3 THEN '3月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 4 THEN '4月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 5 THEN '5月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 6 THEN '6月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 7 THEN '7月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 8 THEN '8月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 9 THEN '9月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 10 THEN '10月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 11 THEN '11月'
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 12 THEN '12月'
            ELSE '12月以上'
        END AS months_in_stall_bucket,

        -- 计算在栏月龄区间排序（用于图表排序）
        CASE
            WHEN c.in_stall_date IS NULL THEN NULL
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 1 THEN 1
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 2 THEN 2
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 3 THEN 3
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 4 THEN 4
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 5 THEN 5
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 6 THEN 6
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 7 THEN 7
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 8 THEN 8
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 9 THEN 9
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 10 THEN 10
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 11 THEN 11
            WHEN FLOOR(DATE_DIFF('day', c.in_stall_date, w.stats_date) / 30.0) < 12 THEN 12
            ELSE 13
        END AS months_in_stall_bucket_sort,

        -- 计算体重区间（200Kg以下、200～249Kg、...、800Kg以上）
        CASE
            WHEN w.current_weight < 200 THEN '200Kg以下'
            WHEN w.current_weight < 250 THEN '200～249Kg'
            WHEN w.current_weight < 300 THEN '250～299Kg'
            WHEN w.current_weight < 350 THEN '300～349Kg'
            WHEN w.current_weight < 400 THEN '350～399Kg'
            WHEN w.current_weight < 450 THEN '400～449Kg'
            WHEN w.current_weight < 500 THEN '450～499Kg'
            WHEN w.current_weight < 550 THEN '500～549Kg'
            WHEN w.current_weight < 600 THEN '550～599Kg'
            WHEN w.current_weight < 650 THEN '600～649Kg'
            WHEN w.current_weight < 700 THEN '650～699Kg'
            WHEN w.current_weight < 750 THEN '700～749Kg'
            WHEN w.current_weight < 800 THEN '750～799Kg'
            ELSE '800Kg以上'
        END AS weight_bucket,

        -- 计算体重区间排序（用于图表排序）
        CASE
            WHEN w.current_weight < 200 THEN 1
            WHEN w.current_weight < 250 THEN 2
            WHEN w.current_weight < 300 THEN 3
            WHEN w.current_weight < 350 THEN 4
            WHEN w.current_weight < 400 THEN 5
            WHEN w.current_weight < 450 THEN 6
            WHEN w.current_weight < 500 THEN 7
            WHEN w.current_weight < 550 THEN 8
            WHEN w.current_weight < 600 THEN 9
            WHEN w.current_weight < 650 THEN 10
            WHEN w.current_weight < 700 THEN 11
            WHEN w.current_weight < 750 THEN 12
            WHEN w.current_weight < 800 THEN 13
            ELSE 14
        END AS weight_bucket_sort,

        -- ====================
        -- ADG指标（从ADG数据关联）
        -- ====================
        a.period_adg,
        a.overall_adg AS adg_overall_adg,
        a.prev_weight_date,
        a.interval_days,

        -- ====================
        -- 价格指标（从价格数据关联）
        -- 注意：价格数据粒度是 牧场+品种+日期，不是牛只级别
        -- 这里通过牧场+品种+日期关联，会有数据重复，但我们在ADS层聚合
        -- ====================
        p.cattle_price,
        p.start_weight AS price_start_weight,
        p.end_weight AS price_end_weight

    FROM weight_trx w
    LEFT JOIN lkp_cattle c ON w.cattle_id::VARCHAR = c.cattle_id::VARCHAR
    LEFT JOIN adg_data a ON w.stats_date = a.stats_date AND w.cattle_id::VARCHAR = a.cattle_id::VARCHAR
    LEFT JOIN price_data p ON w.stats_date = p.stats_date
        AND c.ranch_id::VARCHAR = p.ranch_id::VARCHAR
        AND c.cattle_sku_id::VARCHAR = p.cattle_sku_id::VARCHAR
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    stats_date,
    natural_week,
    natural_month,

    -- 组织维度
    customer_id,
    ranch_id,
    ranch_name,
    stall_id,
    stall_name,

    -- 品种维度
    cattle_sku_id,
    cattle_sku_name,
    brand_name,

    -- 牛只维度
    cattle_id,
    cattle_code,

    -- 牛只属性
    birth_date,
    in_stall_date,
    in_stall_weight,
    current_weight,
    age_days,
    months_in_stall,
    months_in_stall_bucket,
    months_in_stall_bucket_sort,
    weight_bucket,
    weight_bucket_sort,

    -- ADG指标
    period_adg,
    adg_overall_adg,
    prev_weight_date,
    interval_days,

    -- 价格指标
    cattle_price,
    price_start_weight,
    price_end_weight,

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time
FROM integrated_data
WHERE stats_date IS NOT NULL
ORDER BY stats_date, cattle_id
