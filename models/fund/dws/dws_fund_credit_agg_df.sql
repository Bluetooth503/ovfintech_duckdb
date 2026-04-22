-- =============================================
-- 模型名称：dws_fund_credit_agg_df
-- 模型描述：授信日统计表，按日期维度统计授信相关指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信事实表）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 统计维度：按统计日期汇总授信指标
--   - 核心指标：授信笔数、授信总额度、授信总余额、有效授信等
--   - 用于授信趋势分析、监控报表
--   - 架构设计：替代生产环境多个授信统计任务
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='授信日统计表，按日期维度统计授信相关指标',
    tags=['fund', 'dws', 'agg', 'credit', 'daily']
) }}

WITH daily_credit_records AS (
    -- ============================================
    -- 按日期获取授信记录（取每天最新状态）
    -- ============================================
    WITH ranked_credits AS (
        SELECT
            customer_id,
            credit_quota,
            remain_quota,
            credit_used_quota,
            credit_result,
            CAST(trx_date AS DATE) AS stats_date,
            update_time,
            ROW_NUMBER() OVER (PARTITION BY customer_id, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_credit_fact_i') }}
    )
    SELECT
        customer_id,
        stats_date,
        credit_quota,
        remain_quota,
        credit_used_quota,
        credit_result
    FROM ranked_credits
    WHERE rn = 1  -- 取每天每个客户的最新授信记录
),

credit_stats AS (
    -- ============================================
    -- 按日期统计授信指标
    -- ============================================
    SELECT
        stats_date,
        -- 授信笔数
        COUNT(*) AS credit_cnt,
        COUNT(CASE WHEN credit_result = '1' THEN 1 END) AS valid_credit_cnt,
        COUNT(CASE WHEN credit_used_quota > 0 THEN 1 END) AS credit_with_balance_cnt,
        COUNT(DISTINCT customer_id) AS credit_customer_cnt,

        -- 授信额度
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota,

        -- 平均额度
        AVG(credit_quota) AS avg_credit_quota,
        AVG(remain_quota) AS avg_remain_quota,
        AVG(credit_used_quota) AS avg_credit_used_quota,

        -- 用信率
        CASE
            WHEN SUM(credit_quota) > 0
            THEN ROUND((SUM(credit_used_quota) / SUM(credit_quota)) * 100, 2)
            ELSE 0
        END AS utilization_rate

    FROM daily_credit_records
    WHERE credit_result = '1'  -- 仅统计有效授信
    GROUP BY stats_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 统计维度
    stats_date,                                                             -- 统计日期

    -- 授信笔数
    credit_cnt,                                                             -- 授信总笔数
    valid_credit_cnt,                                                       -- 有效授信笔数
    credit_with_balance_cnt,                                                -- 有余额授信笔数
    credit_customer_cnt,                                                    -- 授信客户数

    -- 授信额度
    total_credit_quota,                                                     -- 总授信额度
    total_remain_quota,                                                     -- 总剩余额度
    total_credit_used_quota,                                                -- 总授信已用额度

    -- 平均额度
    ROUND(avg_credit_quota, 2) AS avg_credit_quota,                         -- 平均授信额度
    ROUND(avg_remain_quota, 2) AS avg_remain_quota,                         -- 平均剩余额度
    ROUND(avg_credit_used_quota, 2) AS avg_credit_used_quota,               -- 平均已用额度

    -- 比率
    utilization_rate,                                                       -- 用信率（%）

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM credit_stats
ORDER BY stats_date DESC
