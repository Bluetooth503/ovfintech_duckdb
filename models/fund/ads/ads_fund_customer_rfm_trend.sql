-- =============================================
-- 模型名称：ads_fund_customer_rfm_trend
-- 模型描述：RFM客户价值趋势分析表 - 支持Dashboard趋势分析（按场景分组）
-- 作者：dbt
-- 创建时间：2026-04-13
-- =============================================
{{ config(
    materialized='table',
    description='RFM客户价值趋势分析表，提供时间序列分析和趋势对比数据（支持场景维度）',
    tags=['fund', 'ads', 'rfm', 'trend', 'analysis', 'scene']
) }}

WITH daily_rfm_summary AS (
    -- 按日期+场景汇总RFM指标
    SELECT
        trx_date,
        scene_id,
        scene_name,
        stat_year,
        stat_month,
        stat_quarter,
        stat_week,

        -- 客户数统计
        COUNT(DISTINCT customer_id) AS total_customers,
        COUNT(DISTINCT CASE WHEN rfm_total_score_global >= 13 THEN customer_id END) AS core_customers,
        COUNT(DISTINCT CASE WHEN m_score_global = 5 THEN customer_id END) AS large_amount_customers,

        -- RFM评分分布（全局）
        COUNT(DISTINCT CASE WHEN r_score_global = 5 THEN customer_id END) AS r_score_5_count,
        COUNT(DISTINCT CASE WHEN r_score_global = 4 THEN customer_id END) AS r_score_4_count,
        COUNT(DISTINCT CASE WHEN r_score_global = 3 THEN customer_id END) AS r_score_3_count,
        COUNT(DISTINCT CASE WHEN r_score_global = 2 THEN customer_id END) AS r_score_2_count,
        COUNT(DISTINCT CASE WHEN r_score_global = 1 THEN customer_id END) AS r_score_1_count,

        COUNT(DISTINCT CASE WHEN f_score_global = 5 THEN customer_id END) AS f_score_5_count,
        COUNT(DISTINCT CASE WHEN f_score_global = 4 THEN customer_id END) AS f_score_4_count,
        COUNT(DISTINCT CASE WHEN f_score_global = 3 THEN customer_id END) AS f_score_3_count,
        COUNT(DISTINCT CASE WHEN f_score_global = 2 THEN customer_id END) AS f_score_2_count,
        COUNT(DISTINCT CASE WHEN f_score_global = 1 THEN customer_id END) AS f_score_1_count,

        COUNT(DISTINCT CASE WHEN m_score_global = 5 THEN customer_id END) AS m_score_5_count,
        COUNT(DISTINCT CASE WHEN m_score_global = 4 THEN customer_id END) AS m_score_4_count,
        COUNT(DISTINCT CASE WHEN m_score_global = 3 THEN customer_id END) AS m_score_3_count,
        COUNT(DISTINCT CASE WHEN m_score_global = 2 THEN customer_id END) AS m_score_2_count,
        COUNT(DISTINCT CASE WHEN m_score_global = 1 THEN customer_id END) AS m_score_1_count,

        -- 客户分群分布（全局）
        COUNT(DISTINCT CASE WHEN customer_segment_global = '核心价值客户' THEN customer_id END) AS segment_core_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '高频低贡献客户' THEN customer_id END) AS segment_high_freq_low_contribution_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '大额低频客户' THEN customer_id END) AS segment_large_amount_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '新增客户' THEN customer_id END) AS segment_new_customer_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '流失预警客户' THEN customer_id END) AS segment_churn_warning_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '沉睡大户' THEN customer_id END) AS segment_dormant_large_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '潜力唤回客户' THEN customer_id END) AS segment_potential_recall_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '无价值客户' THEN customer_id END) AS segment_no_value_count,

        -- 价值等级分布（全局）
        COUNT(DISTINCT CASE WHEN customer_value_level_global = 'S级' THEN customer_id END) AS level_s_count,
        COUNT(DISTINCT CASE WHEN customer_value_level_global = 'A级' THEN customer_id END) AS level_a_count,
        COUNT(DISTINCT CASE WHEN customer_value_level_global = 'B级' THEN customer_id END) AS level_b_count,
        COUNT(DISTINCT CASE WHEN customer_value_level_global = 'C级' THEN customer_id END) AS level_c_count,

        -- 金额统计
        SUM(total_trx_amount) AS total_amount,
        SUM(CASE WHEN customer_segment_global = '核心价值客户' THEN total_trx_amount ELSE 0 END) AS core_customer_amount,
        SUM(CASE WHEN m_score_global = 5 THEN total_trx_amount ELSE 0 END) AS large_amount_customer_amount,

        -- 交易频次统计
        SUM(trx_count) AS total_trx_count,
        AVG(trx_count) AS avg_trx_count_per_customer,

        -- RFM指标平均值（全局）
        AVG(recency_days) AS avg_recency_days,
        AVG(frequency_count) AS avg_frequency_count,
        AVG(monetary_amount) AS avg_monetary_amount,
        AVG(rfm_total_score_global) AS avg_rfm_total_score_global,
        AVG(rfm_total_score_scene) AS avg_rfm_total_score_scene,

        -- 活跃度统计
        COUNT(DISTINCT CASE WHEN recency_days <= 7 THEN customer_id END) AS active_7d_customers,
        COUNT(DISTINCT CASE WHEN recency_days <= 30 THEN customer_id END) AS active_30d_customers,
        COUNT(DISTINCT CASE WHEN recency_days <= 90 THEN customer_id END) AS active_90d_customers,
        COUNT(DISTINCT CASE WHEN recency_days > 90 THEN customer_id END) AS inactive_customers

    FROM {{ ref('dws_fund_customer_rfm_1d_d') }}
    GROUP BY trx_date, scene_id, scene_name, stat_year, stat_month, stat_quarter, stat_week
),

weekly_rfm_summary AS (
    -- 按周+场景汇总RFM指标
    SELECT
        stat_year,
        stat_week,
        scene_id,
        scene_name,
        MIN(trx_date) AS week_start_date,
        MAX(trx_date) AS week_end_date,

        COUNT(DISTINCT customer_id) AS weekly_total_customers,
        COUNT(DISTINCT CASE WHEN rfm_total_score_global >= 13 THEN customer_id END) AS weekly_core_customers,
        COUNT(DISTINCT CASE WHEN m_score_global = 5 THEN customer_id END) AS weekly_large_amount_customers,

        SUM(total_trx_amount) AS weekly_total_amount,
        SUM(CASE WHEN customer_segment_global = '核心价值客户' THEN total_trx_amount ELSE 0 END) AS weekly_core_amount,

        AVG(rfm_total_score_global) AS weekly_avg_rfm_score_global,
        AVG(rfm_total_score_scene) AS weekly_avg_rfm_score_scene,
        AVG(recency_days) AS weekly_avg_recency_days

    FROM {{ ref('dws_fund_customer_rfm_1d_d') }}
    GROUP BY stat_year, stat_week, scene_id, scene_name
),

monthly_rfm_summary AS (
    -- 按月+场景汇总RFM指标
    SELECT
        stat_year,
        stat_month,
        scene_id,
        scene_name,
        MIN(trx_date) AS month_start_date,
        MAX(trx_date) AS month_end_date,

        COUNT(DISTINCT customer_id) AS monthly_total_customers,
        COUNT(DISTINCT CASE WHEN rfm_total_score_global >= 13 THEN customer_id END) AS monthly_core_customers,
        COUNT(DISTINCT CASE WHEN m_score_global = 5 THEN customer_id END) AS monthly_large_amount_customers,

        -- 客户分群分布（全局）
        COUNT(DISTINCT CASE WHEN customer_segment_global = '核心价值客户' THEN customer_id END) AS monthly_segment_core_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '高频低贡献客户' THEN customer_id END) AS monthly_segment_high_freq_low_contribution_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '大额低频客户' THEN customer_id END) AS monthly_segment_large_amount_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '新增客户' THEN customer_id END) AS monthly_segment_new_customer_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '流失预警客户' THEN customer_id END) AS monthly_segment_churn_warning_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '沉睡大户' THEN customer_id END) AS monthly_segment_dormant_large_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '潜力唤回客户' THEN customer_id END) AS monthly_segment_potential_recall_count,
        COUNT(DISTINCT CASE WHEN customer_segment_global = '无价值客户' THEN customer_id END) AS monthly_segment_no_value_count,

        SUM(total_trx_amount) AS monthly_total_amount,
        SUM(CASE WHEN customer_segment_global = '核心价值客户' THEN total_trx_amount ELSE 0 END) AS monthly_core_amount,
        SUM(CASE WHEN m_score_global = 5 THEN total_trx_amount ELSE 0 END) AS monthly_large_amount_amount,

        SUM(trx_count) AS monthly_total_trx_count,
        AVG(trx_count) AS monthly_avg_trx_count_per_customer,

        AVG(rfm_total_score_global) AS monthly_avg_rfm_score_global,
        AVG(rfm_total_score_scene) AS monthly_avg_rfm_score_scene,
        AVG(recency_days) AS monthly_avg_recency_days,
        AVG(frequency_count) AS monthly_avg_frequency_count,
        AVG(monetary_amount) AS monthly_avg_monetary_amount,

        LAG(SUM(total_trx_amount)) OVER (PARTITION BY scene_id ORDER BY stat_year, stat_month) AS prev_month_amount,
        LAG(COUNT(DISTINCT customer_id)) OVER (PARTITION BY scene_id ORDER BY stat_year, stat_month) AS prev_month_customers

    FROM {{ ref('dws_fund_customer_rfm_1d_d') }}
    GROUP BY stat_year, stat_month, scene_id, scene_name
)

SELECT
    -- 时间维度
    drs.trx_date AS stat_date,                                         -- 统计日期
    drs.scene_id,                                                     -- 场景ID
    drs.scene_name,                                                   -- 场景名称
    drs.stat_year,                                                   -- 统计年份
    drs.stat_month,                                                  -- 统计月份
    drs.stat_quarter,                                                -- 统计季度
    drs.stat_week,                                                   -- 统计周

    -- 日度指标
    drs.total_customers,                                             -- 当日总客户数
    drs.core_customers,                                              -- 当日核心客户数
    drs.large_amount_customers,                                      -- 当日大额客户数
    drs.total_amount,                                                -- 当日总金额
    drs.core_customer_amount,                                        -- 当日核心客户金额
    drs.large_amount_customer_amount,                                -- 当日大额客户金额
    drs.total_trx_count,                                             -- 当日总交易次数
    drs.avg_trx_count_per_customer,                                  -- 当日户均交易次数

    -- RFM评分分布（日度）
    drs.r_score_5_count, drs.r_score_4_count, drs.r_score_3_count, drs.r_score_2_count, drs.r_score_1_count,
    drs.f_score_5_count, drs.f_score_4_count, drs.f_score_3_count, drs.f_score_2_count, drs.f_score_1_count,
    drs.m_score_5_count, drs.m_score_4_count, drs.m_score_3_count, drs.m_score_2_count, drs.m_score_1_count,

    -- 客户分群分布（日度）
    drs.segment_core_count,                                          -- 核心价值客户数
    drs.segment_high_freq_low_contribution_count,                    -- 高频低贡献客户数
    drs.segment_large_amount_count,                                   -- 大额低频客户数
    drs.segment_new_customer_count,                                   -- 新客户数
    drs.segment_churn_warning_count,                                 -- 流失预警客户数
    drs.segment_dormant_large_count,                                  -- 沉睡大户数
    drs.segment_potential_recall_count,                               -- 潜力唤回客户数
    drs.segment_no_value_count,                                       -- 无价值客户数

    -- 价值等级分布（日度）
    drs.level_s_count, drs.level_a_count, drs.level_b_count, drs.level_c_count,

    -- RFM指标平均值（日度）
    drs.avg_recency_days,                                            -- 平均最近活跃天数
    drs.avg_frequency_count,                                         -- 平均购买频次
    drs.avg_monetary_amount,                                         -- 平均购买金额
    drs.avg_rfm_total_score_global,                                  -- 平均RFM总分（全局）
    drs.avg_rfm_total_score_scene,                                   -- 平均RFM总分（场景内）

    -- 活跃度统计（日度）
    drs.active_7d_customers,                                         -- 7天内活跃客户数
    drs.active_30d_customers,                                        -- 30天内活跃客户数
    drs.active_90d_customers,                                        -- 90天内活跃客户数
    drs.inactive_customers,                                          -- 不活跃客户数

    -- 周度指标
    wrs.weekly_total_customers,                                      -- 周度总客户数
    wrs.weekly_core_customers,                                       -- 周度核心客户数
    wrs.weekly_large_amount_customers,                               -- 周度大额客户数
    wrs.weekly_total_amount,                                         -- 周度总金额
    wrs.weekly_core_amount,                                          -- 周度核心客户金额
    wrs.weekly_avg_rfm_score_global,                                 -- 周度平均RFM分数（全局）
    wrs.weekly_avg_rfm_score_scene,                                  -- 周度平均RFM分数（场景内）
    wrs.weekly_avg_recency_days,                                     -- 周度平均活跃天数

    -- 月度指标
    mrs.monthly_total_customers,                                     -- 月度总客户数
    mrs.monthly_core_customers,                                      -- 月度核心客户数
    mrs.monthly_large_amount_customers,                              -- 月度大额客户数
    mrs.monthly_total_amount,                                        -- 月度总金额
    mrs.monthly_core_amount,                                        -- 月度核心客户金额
    mrs.monthly_large_amount_amount,                                -- 月度大额客户金额
    mrs.monthly_total_trx_count,                                    -- 月度总交易次数
    mrs.monthly_avg_trx_count_per_customer,                         -- 月度户均交易次数
    mrs.monthly_avg_rfm_score_global,                               -- 月度平均RFM分数（全局）
    mrs.monthly_avg_rfm_score_scene,                                -- 月度平均RFM分数（场景内）
    mrs.monthly_avg_recency_days,                                   -- 月度平均活跃天数
    mrs.monthly_avg_frequency_count,                                 -- 月度平均购买频次
    mrs.monthly_avg_monetary_amount,                                -- 月度平均购买金额

    -- 月度客户分群分布
    mrs.monthly_segment_core_count,                                  -- 月度核心价值客户数
    mrs.monthly_segment_high_freq_low_contribution_count,            -- 月度高频低贡献客户数
    mrs.monthly_segment_large_amount_count,                          -- 月度大额低频客户数
    mrs.monthly_segment_new_customer_count,                           -- 月度新客户数
    mrs.monthly_segment_churn_warning_count,                         -- 月度流失预警客户数
    mrs.monthly_segment_dormant_large_count,                         -- 月度沉睡大户数
    mrs.monthly_segment_potential_recall_count,                      -- 月度潜力唤回客户数
    mrs.monthly_segment_no_value_count,                               -- 月度无价值客户数

    -- 环比增长率（月度）
    CASE WHEN mrs.prev_month_amount > 0 THEN ROUND((mrs.monthly_total_amount - mrs.prev_month_amount) / mrs.prev_month_amount * 100, 2) ELSE NULL END AS mom_amount_growth_rate,
    CASE WHEN mrs.prev_month_customers > 0 THEN ROUND((mrs.monthly_total_customers - mrs.prev_month_customers) / mrs.prev_month_customers * 100, 2) ELSE NULL END AS mom_customers_growth_rate,

    -- 时间维度标识
    CASE
        WHEN drs.trx_date = CURRENT_DATE THEN '当日'
        WHEN drs.trx_date >= CURRENT_DATE - INTERVAL '7 days' THEN '最近7天'
        WHEN drs.trx_date >= CURRENT_DATE - INTERVAL '30 days' THEN '最近30天'
        WHEN drs.trx_date >= DATE_TRUNC('month', CURRENT_DATE) THEN '本月'
        WHEN drs.trx_date >= DATE_TRUNC('quarter', CURRENT_DATE) THEN '本季度'
        WHEN drs.trx_date >= DATE_TRUNC('year', CURRENT_DATE) THEN '本年度'
        ELSE '历史'
    END AS time_period,                                                -- 时间周期标识

    -- 数据更新时间
    CURRENT_TIMESTAMP AS data_update_time,                             -- 数据更新时间
    CURRENT_DATE AS data_update_date                                   -- 数据更新日期

FROM daily_rfm_summary drs
LEFT JOIN weekly_rfm_summary wrs
    ON drs.stat_year = wrs.stat_year
    AND drs.stat_week = wrs.stat_week
    AND drs.scene_id = wrs.scene_id
LEFT JOIN monthly_rfm_summary mrs
    ON drs.stat_year = mrs.stat_year
    AND drs.stat_month = mrs.stat_month
    AND drs.scene_id = mrs.scene_id

ORDER BY drs.trx_date DESC, drs.scene_id
