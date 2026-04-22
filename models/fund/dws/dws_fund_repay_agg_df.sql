-- =============================================
-- 模型名称：dws_fund_repay_agg_df
-- 模型描述：还款日统计表，按日期维度统计还款相关指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date
-- 说明：
--   - 数据源：dwd_fund_online_loan_fact_i（线上还款）+ dwd_fund_early_repay_fact_i（提前还款，待实现）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 统计维度：按统计日期汇总还款指标
--   - 核心指标：还款笔数、还款金额、还款本金、还款利息
--   - 用于还款趋势分析、资金回收监控
--   - 架构设计：替代生产环境多个还款统计任务
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
--   - 注意：当前版本仅包含线上还款，提前还款待 DWD 层模型实现后补充
-- =============================================
{{ config(
    materialized='table',
    description='还款日统计表，按日期维度统计还款相关指标',
    tags=['fund', 'dws', 'agg', 'repay', 'daily']
) }}

WITH daily_repayment AS (
    -- ============================================
    -- 线上还款日统计
    -- ============================================
    SELECT
        CAST(trx_date AS DATE) AS stats_date,
        -- 还款笔数
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS repay_cnt,
        -- 还款金额
        SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS repay_amt,
        -- 还款利息
        SUM(CASE WHEN loan_repay_type = '2' THEN repay_interest_amount ELSE 0 END) AS repay_interest_amt,
        -- 还款本金（还款总额 - 利息）
        SUM(CASE WHEN loan_repay_type = '2' THEN (bill_amount - repay_interest_amount) ELSE 0 END) AS repay_principal_amt,
        -- 还款客户数
        COUNT(DISTINCT CASE WHEN loan_repay_type = '2' THEN customer_id END) AS repay_customer_cnt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type = '2'  -- 还款
    GROUP BY CAST(trx_date AS DATE)
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 统计维度
    stats_date,                                                             -- 统计日期

    -- 还款笔数
    repay_cnt,                                                              -- 还款笔数
    repay_customer_cnt,                                                     -- 还款客户数

    -- 还款金额
    repay_amt,                                                              -- 还款总金额
    repay_principal_amt,                                                    -- 还款本金
    repay_interest_amt,                                                     -- 还款利息

    -- 平均还款金额
    CASE
        WHEN repay_cnt > 0
        THEN ROUND(repay_amt / repay_cnt, 2)
        ELSE 0
    END AS avg_repay_amt,                                                   -- 平均还款金额

    -- 平均还款本金
    CASE
        WHEN repay_cnt > 0
        THEN ROUND(repay_principal_amt / repay_cnt, 2)
        ELSE 0
    END AS avg_repay_principal_amt,                                         -- 平均还款本金

    -- 平均还款利息
    CASE
        WHEN repay_cnt > 0
        THEN ROUND(repay_interest_amt / repay_cnt, 2)
        ELSE 0
    END AS avg_repay_interest_amt,                                          -- 平均还款利息

    -- 还款金额占比
    CASE
        WHEN repay_amt > 0
        THEN ROUND((repay_principal_amt / repay_amt) * 100, 2)
        ELSE 0
    END AS principal_ratio_pct,                                             -- 本金占比（%）

    CASE
        WHEN repay_amt > 0
        THEN ROUND((repay_interest_amt / repay_amt) * 100, 2)
        ELSE 0
    END AS interest_ratio_pct,                                              -- 利息占比（%）

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM daily_repayment
ORDER BY stats_date DESC
