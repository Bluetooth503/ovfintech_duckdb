-- =============================================
-- @DEPRECATED: 此模型已废弃，请使用以下新模型
--   - dws_fund_customer_loan_state_df.sql（当前状态）
--   - dws_fund_customer_loan_snap_df.sql（历史快照）
--   - dws_fund_customer_loan_agg_df.sql（聚合汇总）
-- 废弃日期: 2025-04-22
-- 计划删除: 2025-05-22（30天后）
-- =============================================
-- =============================================
-- 模型名称：dws_fund_customer_fund_snap_df
-- 模型描述：客户资金每日快照表，记录每个客户在每天的资金状态
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dws_fund_credit_state_df（授信状态）+ dws_fund_loan_balance_snap_df（借据余额快照）+ dwd_fund_online_loan_fact_i（线上交易）
--   - 更新策略：按日期追加，保留完整历史数据
--   - 业务时间：取每天截止时刻的客户资金状态
--   - 整合授信、放款、还款、余额等客户级资金指标
--   - 用于客户资金历史趋势分析、客户价值评估、风险监控
--   - 架构设计：基于现有数据源，待 dws_fund_customer_agg_df 实现后可优化
--   - 命名说明：_snap_df 表示历史快照，保留历史数据
-- =============================================
{{ config(
    materialized='table',
    enabled=False,  -- 禁用此模型
    description='@DEPRECATED - 已废弃，请使用 dws_fund_customer_loan_snap_df',
    tags=['fund', 'dws', 'snap', 'customer', 'fund']
) }}

WITH all_dates AS (
    -- ============================================
    -- 生成所有需要统计的日期范围
    -- ============================================
    SELECT
        DISTINCT CAST(trx_date AS DATE) AS stats_date
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE CAST(trx_date AS DATE) >= '2020-01-01'  -- 可根据实际数据调整起始日期
),

credit_daily AS (
    -- ============================================
    -- 按客户和日期汇总授信信息
    -- ============================================
    WITH ranked_credits AS (
        SELECT
            customer_id,
            CAST(trx_date AS DATE) AS stats_date,
            credit_quota,
            remain_quota,
            credit_used_quota,
            update_time,
            ROW_NUMBER() OVER (PARTITION BY customer_id, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_credit_fact_i') }}
        WHERE credit_result = '1'  -- 有效授信
    )
    SELECT
        customer_id,
        stats_date,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota
    FROM ranked_credits
    WHERE rn = 1  -- 取每天每个客户的最新授信记录
    GROUP BY customer_id, stats_date
),

loan_balance_daily AS (
    -- ============================================
    -- 按客户和日期汇总借据余额
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        SUM(loan_balance) AS total_loan_balance,
        COUNT(DISTINCT promissory_note_no) AS outstanding_promissory_note_cnt
    FROM {{ ref('dws_fund_loan_balance_snap_df') }}
    WHERE loan_balance > 0  -- 只统计有余额的借据
    GROUP BY customer_id, stats_date
),

daily_loan_repay AS (
    -- ============================================
    -- 按客户和日期汇总当日放款和还款
    -- ============================================
    SELECT
        customer_id,
        CAST(trx_date AS DATE) AS stats_date,
        -- 放款（loan_repay_type = 1）
        SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS daily_loan_amt,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS daily_loan_cnt,
        -- 还款（loan_repay_type = 2）
        SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS daily_repay_amt,
        SUM(CASE WHEN loan_repay_type = '2' THEN repay_interest_amount ELSE 0 END) AS daily_repay_interest_amt,
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS daily_repay_cnt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type IN ('1', '2')  -- 放款和还款
    GROUP BY customer_id, CAST(trx_date AS DATE)
),

-- ============================================
-- 合并所有数据
-- =============================================
all_customer_daily AS (
    SELECT
        COALESCE(cd.customer_id, lb.customer_id, lr.customer_id) AS customer_id,
        COALESCE(cd.stats_date, lb.stats_date, lr.stats_date) AS stats_date,
        -- 授信信息
        COALESCE(cd.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cd.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(cd.total_credit_used_quota, 0) AS total_credit_used_quota,
        -- 借据余额
        COALESCE(lb.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(lb.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt,
        -- 当日放款
        COALESCE(lr.daily_loan_amt, 0) AS daily_loan_amt,
        COALESCE(lr.daily_loan_cnt, 0) AS daily_loan_cnt,
        -- 当日还款
        COALESCE(lr.daily_repay_amt, 0) AS daily_repay_amt,
        COALESCE(lr.daily_repay_interest_amt, 0) AS daily_repay_interest_amt,
        COALESCE(lr.daily_repay_cnt, 0) AS daily_repay_cnt
    FROM credit_daily cd
    FULL OUTER JOIN loan_balance_daily lb ON cd.customer_id = lb.customer_id AND cd.stats_date = lb.stats_date
    FULL OUTER JOIN daily_loan_repay lr ON COALESCE(cd.customer_id, lb.customer_id) = lr.customer_id AND COALESCE(cd.stats_date, lb.stats_date) = lr.stats_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    customer_id,                                                            -- 客户ID
    stats_date,                                                             -- 统计日期

    -- 授信额度信息
    total_credit_quota,                                                     -- 总授信额度
    total_remain_quota,                                                     -- 总剩余额度
    total_credit_used_quota,                                                -- 总授信已用额度

    -- 贷款余额
    total_loan_balance,                                                     -- 总贷款余额
    outstanding_promissory_note_cnt,                                        -- 在贷笔数

    -- 当日放款
    daily_loan_amt,                                                         -- 当日放款金额
    daily_loan_cnt,                                                         -- 当日放款笔数

    -- 当日还款
    daily_repay_amt,                                                        -- 当日还款金额
    daily_repay_interest_amt,                                               -- 当日还款利息
    daily_repay_cnt,                                                        -- 当日还款笔数

    -- 计算字段
    CASE WHEN total_credit_quota > 0 THEN ROUND((total_credit_used_quota / total_credit_quota) * 100, 2) ELSE 0 END AS utilization_rate,  -- 用信率（%）

    -- 是否贷款客户
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户

    -- 是否有当日交易
    CASE WHEN daily_loan_amt > 0 OR daily_repay_amt > 0 THEN '1' ELSE '0' END AS has_daily_transaction,  -- 是否有当日交易

    -- 资金方信息（从最新授信记录获取）
    (SELECT c.fund_org_name FROM {{ ref('dwd_fund_credit_fact_i') }} c
     WHERE c.customer_id = all_customer_daily.customer_id
       AND c.credit_result = '1'
       AND CAST(c.trx_date AS DATE) <= all_customer_daily.stats_date
     ORDER BY c.update_time DESC LIMIT 1) AS fund_org_name,  -- 资金方名称

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM all_customer_daily
WHERE total_credit_quota > 0 OR total_loan_balance > 0 OR daily_loan_amt > 0 OR daily_repay_amt > 0  -- 只保留有活动的客户
ORDER BY customer_id, stats_date DESC
