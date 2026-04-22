-- =============================================
-- 模型名称：dws_fund_credit_agg_df
-- 模型描述：授信日统计表，按日期维度统计授信相关指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date
-- 说明：
--   - 数据源：dws_fund_credit_snap_df（授信快照表）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 统计维度：按统计日期汇总授信指标
--   - 核心指标：授信笔数、授信总额度、授信总余额、有效授信等
--   - 用于授信趋势分析、监控报表
--   - 架构设计：复用 snap 表，避免重复计算
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='授信日统计表，按日期维度统计授信相关指标',
    tags=['fund', 'dws', 'agg', 'credit', 'daily']
) }}

WITH credit_stats AS (
    -- ============================================
    -- 按日期统计授信指标
    -- ============================================
    SELECT
        stats_date,
        COUNT(*) AS credit_cnt,
        COUNT(CASE WHEN credit_result = '1' THEN 1 END) AS valid_credit_cnt,
        COUNT(CASE WHEN credit_used_quota > 0 THEN 1 END) AS credit_with_balance_cnt,
        COUNT(DISTINCT customer_id) AS credit_customer_cnt,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota,
        AVG(credit_quota) AS avg_credit_quota,
        AVG(remain_quota) AS avg_remain_quota,
        AVG(credit_used_quota) AS avg_credit_used_quota,
        CASE WHEN SUM(credit_quota) > 0 THEN ROUND((SUM(credit_used_quota) / SUM(credit_quota)) * 100, 2) ELSE 0 END AS utilization_rate
    FROM {{ ref('dws_fund_credit_snap_df') }}
    GROUP BY stats_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    stats_date,
    credit_cnt,
    valid_credit_cnt,
    credit_with_balance_cnt,
    credit_customer_cnt,
    total_credit_quota,
    total_remain_quota,
    total_credit_used_quota,
    ROUND(avg_credit_quota, 2) AS avg_credit_quota,
    ROUND(avg_remain_quota, 2) AS avg_remain_quota,
    ROUND(avg_credit_used_quota, 2) AS avg_credit_used_quota,
    utilization_rate,
    CURRENT_TIMESTAMP AS dw_update_time
FROM credit_stats
ORDER BY stats_date DESC
