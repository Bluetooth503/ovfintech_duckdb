-- =============================================
-- 模型名称：ads_rpt_fund_rfm_segment_stats_df
-- 模型描述：RFM分群统计日报表，提供各客户分群的汇总统计信息（全局和场景维度）
-- Dbt更新方式：全量
-- 粒度：stat_scope + scene_id + customer_segment_global
-- 说明：
--   - 数据源：ads_rpt_fund_customer_rfm_segment_df、dim_rfm_segment_metadata
--   - 统计指标：分群客户数、金额、占比、平均RFM评分、平均交易频次
--   - 聚合逻辑：全局+场景两个维度分别统计，UNION ALL 合并
-- =============================================
{{ config(
    materialized='table',
    description='RFM分群统计日报表，提供各客户分群的汇总统计信息（全局和场景维度），天粒度全量更新',
    tags=['fund', 'ads', 'rpt', 'rfm', 'segment', 'stats', 'aggregate', '1d', 'daily']
) }}

WITH customer_segment AS (
    -- 从客户分群报表表获取数据
    SELECT
        customer_id,
        stat_date,
        last_trx_date AS latest_trx_date,
        scene_id,
        scene_name,
        customer_segment_global,
        recency_days,
        frequency_count,
        monetary_amount,
        rfm_total_score_global,
        lifetime_total_amount,
        lifetime_total_trx_count,
        first_trx_date,
        last_trx_date
    FROM {{ ref('ads_rpt_fund_customer_rfm_segment_df') }}
),

-- 全局总体统计
global_total AS (
    SELECT
        COUNT(DISTINCT customer_id) AS total_customers,
        SUM(lifetime_total_amount) AS total_amount
    FROM customer_segment
),

-- 全局分群统计
global_segment_stats AS (
    SELECT
        'global' AS stat_scope,
        0 AS scene_id,
        '全部场景' AS scene_name,
        MAX(cs.stat_date) AS stat_date,
        cs.customer_segment_global,
        COUNT(DISTINCT cs.customer_id) AS segment_customer_count,
        SUM(cs.lifetime_total_amount) AS segment_total_amount,
        AVG(cs.lifetime_total_amount) AS segment_avg_amount,
        AVG(cs.lifetime_total_trx_count) AS segment_avg_trx_count,
        AVG(cs.lifetime_total_amount / NULLIF(cs.lifetime_total_trx_count, 0)) AS segment_avg_per_trx,
        AVG(cs.recency_days) AS segment_avg_recency_days,
        AVG(cs.frequency_count) AS segment_avg_frequency,
        AVG(cs.monetary_amount) AS segment_avg_monetary,
        AVG(cs.rfm_total_score_global) AS segment_avg_rfm_score,
        MIN(cs.first_trx_date) AS segment_first_trx_date,
        MAX(cs.last_trx_date) AS segment_last_trx_date,
        -- 占比计算
        ROUND(COUNT(DISTINCT cs.customer_id)::FLOAT / gt.total_customers * 100, 2) AS segment_customer_ratio,
        ROUND(SUM(cs.lifetime_total_amount)::FLOAT / NULLIF(gt.total_amount, 0) * 100, 2) AS segment_amount_ratio
    FROM customer_segment cs
    CROSS JOIN global_total gt
    GROUP BY cs.customer_segment_global, gt.total_customers, gt.total_amount
),

-- 场景总体统计
scene_total AS (
    SELECT
        scene_id,
        scene_name,
        COUNT(DISTINCT customer_id) AS total_customers,
        SUM(lifetime_total_amount) AS total_amount
    FROM customer_segment
    GROUP BY scene_id, scene_name
),

-- 场景内分群统计
scene_segment_stats AS (
    SELECT
        'scene' AS stat_scope,
        cs.scene_id,
        cs.scene_name,
        MAX(cs.stat_date) AS stat_date,
        cs.customer_segment_global,
        COUNT(DISTINCT cs.customer_id) AS segment_customer_count,
        SUM(cs.lifetime_total_amount) AS segment_total_amount,
        AVG(cs.lifetime_total_amount) AS segment_avg_amount,
        AVG(cs.lifetime_total_trx_count) AS segment_avg_trx_count,
        AVG(cs.lifetime_total_amount / NULLIF(cs.lifetime_total_trx_count, 0)) AS segment_avg_per_trx,
        AVG(cs.recency_days) AS segment_avg_recency_days,
        AVG(cs.frequency_count) AS segment_avg_frequency,
        AVG(cs.monetary_amount) AS segment_avg_monetary,
        AVG(cs.rfm_total_score_global) AS segment_avg_rfm_score,
        MIN(cs.first_trx_date) AS segment_first_trx_date,
        MAX(cs.last_trx_date) AS segment_last_trx_date,
        -- 占比计算
        ROUND(COUNT(DISTINCT cs.customer_id)::FLOAT / st.total_customers * 100, 2) AS segment_customer_ratio,
        ROUND(SUM(cs.lifetime_total_amount)::FLOAT / NULLIF(st.total_amount, 0) * 100, 2) AS segment_amount_ratio
    FROM customer_segment cs
    JOIN scene_total st ON cs.scene_id = st.scene_id AND cs.scene_name = st.scene_name
    GROUP BY cs.scene_id, cs.scene_name, cs.customer_segment_global, st.total_customers, st.total_amount
)

SELECT
    -- 统计范围和日期
    gss.stat_scope,
    gss.stat_date,
    gss.scene_id,
    gss.scene_name,
    gss.customer_segment_global,
    dim.segment_description,
    dim.segment_strategy,
    dim.priority_level,
    gss.segment_customer_count,
    gss.segment_total_amount,
    gss.segment_avg_amount,
    gss.segment_avg_trx_count,
    gss.segment_avg_per_trx,
    gss.segment_avg_recency_days,
    gss.segment_avg_frequency,
    gss.segment_avg_monetary,
    gss.segment_avg_rfm_score,
    gss.segment_first_trx_date,
    gss.segment_last_trx_date,
    gss.segment_customer_ratio,
    gss.segment_amount_ratio,
    CURRENT_TIMESTAMP AS data_update_time,
    CURRENT_DATE AS data_update_date

FROM global_segment_stats gss
LEFT JOIN {{ ref('dim_rfm_segment_metadata') }} dim ON gss.customer_segment_global = dim.segment_code

UNION ALL

SELECT
    sss.stat_scope,
    sss.stat_date,
    sss.scene_id,
    sss.scene_name,
    sss.customer_segment_global,
    dim.segment_description,
    dim.segment_strategy,
    dim.priority_level,
    sss.segment_customer_count,
    sss.segment_total_amount,
    sss.segment_avg_amount,
    sss.segment_avg_trx_count,
    sss.segment_avg_per_trx,
    sss.segment_avg_recency_days,
    sss.segment_avg_frequency,
    sss.segment_avg_monetary,
    sss.segment_avg_rfm_score,
    sss.segment_first_trx_date,
    sss.segment_last_trx_date,
    sss.segment_customer_ratio,
    sss.segment_amount_ratio,
    CURRENT_TIMESTAMP AS data_update_time,
    CURRENT_DATE AS data_update_date

FROM scene_segment_stats sss
LEFT JOIN {{ ref('dim_rfm_segment_metadata') }} dim ON sss.customer_segment_global = dim.segment_code

ORDER BY stat_scope, stat_date DESC, scene_id, segment_customer_count DESC