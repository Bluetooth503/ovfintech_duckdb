-- =============================================
-- 模型名称：ads_rpt_fund_customer_rfm_segment_df
-- 模型描述：RFM客户分群日报表，提供客户价值分析的客户级别视图
-- Dbt更新方式：全量
-- 粒度：customer_id
-- 说明：
--   - 数据源：dws_fund_customer_rfm_df、dim_customer_unify、dim_rfm_segment_metadata
--   - 统计指标：RFM评分、客户分群、全生命周期指标、最近30/90天指标、分群描述与策略
-- =============================================
{{ config(
    materialized='table',
    description='RFM客户分群日报表，提供客户价值分析的客户级别视图，天粒度全量更新',
    tags=['fund', 'ads', 'rpt', 'rfm', 'segment', 'customer', '1d', 'daily']
) }}

WITH customer_latest_rfm AS (
    -- 获取每个客户最新的RFM指标（全局）
    SELECT DISTINCT ON (customer_id)
        customer_id,
        stat_date,
        latest_trx_date,
        scene_id,
        scene_name,
        trx_count,
        total_loan_amount,
        total_interest_amount,
        total_loan_balance,
        recency_days,
        frequency_count,
        monetary_amount,
        r_score_global,
        f_score_global,
        m_score_global,
        rfm_total_score_global,
        r_score_scene,
        f_score_scene,
        m_score_scene,
        rfm_total_score_scene,
        customer_segment_global,
        customer_segment_scene
    FROM {{ ref('dws_fund_customer_rfm_df') }}
    ORDER BY customer_id, latest_trx_date DESC
),

customer_lifetime_stats AS (
    -- 计算客户全生命周期统计（全局）
    SELECT
        customer_id,
        COUNT(latest_trx_date) AS lifetime_trx_days,
        SUM(trx_count) AS lifetime_total_trx_count,
        SUM(total_loan_amount) AS lifetime_total_amount,
        MIN(latest_trx_date) AS first_trx_date,
        MAX(latest_trx_date) AS last_trx_date,
        AVG(trx_count) AS avg_daily_trx_count,
        AVG(total_loan_amount) AS avg_daily_amount,
        SUM(CASE WHEN latest_trx_date >= CURRENT_DATE - INTERVAL '30 days' THEN trx_count ELSE 0 END) AS last_30d_trx_count,
        SUM(CASE WHEN latest_trx_date >= CURRENT_DATE - INTERVAL '30 days' THEN total_loan_amount ELSE 0 END) AS last_30d_amount,
        SUM(CASE WHEN latest_trx_date >= CURRENT_DATE - INTERVAL '90 days' THEN trx_count ELSE 0 END) AS last_90d_trx_count,
        SUM(CASE WHEN latest_trx_date >= CURRENT_DATE - INTERVAL '90 days' THEN total_loan_amount ELSE 0 END) AS last_90d_amount
    FROM {{ ref('dws_fund_customer_rfm_df') }}
    GROUP BY customer_id
)

SELECT
    -- 主键和统计信息
    clr.customer_id,                                                 -- 客户ID
    dc.customer_name,                                                -- 客户名称
    CURRENT_DATE AS stat_date,                                       -- 统计日期（RFM计算执行日期）
    clr.scene_id,                                                    -- 场景ID
    clr.scene_name,                                                  -- 场景名称

    -- RFM原始指标
    clr.recency_days,                                                -- 最近活跃天数
    clr.frequency_count,                                             -- 购买次数
    clr.monetary_amount,                                             -- 购买金额

    -- 全局RFM评分
    clr.r_score_global,                                              -- R评分（全局）
    clr.f_score_global,                                              -- F评分（全局）
    clr.m_score_global,                                              -- M评分（全局）
    clr.rfm_total_score_global,                                      -- RFM总分（全局）

    -- 场景内RFM评分
    clr.r_score_scene,                                               -- R评分（场景内）
    clr.f_score_scene,                                               -- F评分（场景内）
    clr.m_score_scene,                                               -- M评分（场景内）
    clr.rfm_total_score_scene,                                       -- RFM总分（场景内）

    -- 客户分群（全局）
    clr.customer_segment_global,                                     -- 客户分群（全局）

    -- 客户分群（场景内）
    clr.customer_segment_scene,                                      -- 客户分群（场景内）

    -- 客户全生命周期指标
    cls.lifetime_trx_days,                                           -- 交易天数
    cls.lifetime_total_trx_count,                                    -- 总交易次数
    cls.lifetime_total_amount,                                       -- 总交易金额
    cls.first_trx_date,                                              -- 首次交易日期
    cls.last_trx_date,                                               -- 最后交易日期
    cls.avg_daily_trx_count,                                         -- 日均交易次数
    cls.avg_daily_amount,                                            -- 日均交易金额

    -- 最近30天指标
    cls.last_30d_trx_count,                                          -- 最近30天交易次数
    cls.last_30d_amount,                                             -- 最近30天交易金额

    -- 最近90天指标
    cls.last_90d_trx_count,                                          -- 最近90天交易次数
    cls.last_90d_amount,                                             -- 最近90天交易金额

    -- 分群描述和策略（从dim表关联获取）
    dim_global.segment_description AS segment_description_global,    -- 分群描述（全局）
    dim_global.segment_strategy AS segment_strategy_global,          -- 营销策略（全局）
    dim_global.priority_level AS segment_priority_global,            -- 优先级（全局）

    -- 更新时间
    CURRENT_TIMESTAMP AS data_update_time,                           -- 数据更新时间
    CURRENT_DATE AS data_update_date                                 -- 数据更新日期

FROM customer_latest_rfm clr
JOIN customer_lifetime_stats cls ON clr.customer_id = cls.customer_id
LEFT JOIN {{ ref('dim_customer_unify') }} dc ON clr.customer_id = dc.customer_id
LEFT JOIN {{ ref('dim_rfm_segment_metadata') }} dim_global ON clr.customer_segment_global = dim_global.segment_code

ORDER BY
    dim_global.priority_level DESC,
    clr.rfm_total_score_global DESC,
    clr.monetary_amount DESC