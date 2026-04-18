-- =============================================
-- 模型名称：dws_fund_loan_customer_monthly_agg_mi
-- 模型描述：企业贷款月度聚合表，按借款企业+自然月统计贷款流动、余额、周转与风险指标
-- Dbt更新方式：增量（按月）
-- 粒度：customer_id + natural_month
-- 说明：
--   - 数据源：dwd_fund_offline_loan_fact_i（线下贷款明细）
--   - 统计指标：当月放款/还款、期末余额、在贷笔数、授信额度、平均周转天数、逾期金额、到期金额
--   - 聚合逻辑：按自然月+客户 GROUP BY 汇总，关联上月期初余额
-- =============================================
{{ config(
    materialized='table',
    description='企业贷款月度聚合表，按借款企业+自然月统计贷款规模、流动、周转及风险指标',
    tags=['fund', 'dws', 'agg', 'loan', 'monthly']
) }}

-- ============================================
-- 1. 贷款明细（带自然月）
-- ============================================
WITH loan_monthly AS (
    SELECT
        customer_id,
        customer_name,
        loan_amount,
        promissory_note_balance,
        difference_value,
        promissory_note_start_date::DATE AS debt_start_date,
        promissory_note_end_date::DATE AS debt_end_date,
        loan_repay_type AS bill_type,
        settle_status,
        promissory_note_amount AS loan_quota,
        statistics_no,
        update_time::timestamp AS update_time,
        EXTRACT(YEAR FROM statistics_date::DATE) * 100 + EXTRACT(MONTH FROM statistics_date::DATE) AS natural_month,
        DATE_TRUNC('month', statistics_date::DATE)::DATE AS month_start_date,
        (DATE_TRUNC('month', statistics_date::DATE) + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS month_end_date
    FROM {{ ref('dwd_fund_offline_loan_fact_i') }}
    WHERE customer_id IS NOT NULL
      AND statistics_date IS NOT NULL
),

-- ============================================
-- 2. 月未贷款余额（取每笔贷款当月最新记录）
-- ============================================
loan_latest_per_month AS (
    SELECT
        natural_month,
        customer_id,
        statistics_no,
        promissory_note_balance,
        settle_status,
        debt_end_date,
        loan_quota,
        month_end_date
    FROM (
        SELECT
            natural_month, customer_id, statistics_no, promissory_note_balance, settle_status, debt_end_date, loan_quota, month_end_date,
            ROW_NUMBER() OVER (PARTITION BY customer_id, statistics_no, natural_month ORDER BY update_time DESC) AS rn  -- 取每笔贷款当月最新记录
        FROM loan_monthly
    ) t
    WHERE rn = 1
),

-- ============================================
-- 3. 企业级月度聚合
-- ============================================
member_monthly AS (
    SELECT
        l.natural_month,
        l.customer_id,
        MAX(l.customer_name) AS customer_name,
        MAX(l.month_start_date) AS month_start_date,
        MAX(l.month_end_date) AS month_end_date,

        -- 当月放款
        SUM(CASE WHEN l.bill_type = 1 THEN COALESCE(l.loan_amount, 0) ELSE 0 END) AS monthly_disbursement,

        -- 当月还款
        SUM(CASE WHEN l.bill_type = 2 THEN COALESCE(l.difference_value, 0) ELSE 0 END) AS monthly_repayment,

        -- 当月贷款笔数
        COUNT(DISTINCT l.statistics_no) AS monthly_loan_count,

        -- 期末余额
        (SELECT SUM(COALESCE(promissory_note_balance, 0)) FROM loan_latest_per_month lp WHERE lp.natural_month = l.natural_month AND lp.customer_id = l.customer_id AND lp.settle_status = 0) AS end_balance,

        -- 在贷笔数
        (SELECT COUNT(DISTINCT statistics_no) FROM loan_latest_per_month lp WHERE lp.natural_month = l.natural_month AND lp.customer_id = l.customer_id AND lp.settle_status = 0) AS outstanding_count,

        -- 授信额度
        MAX(COALESCE(l.loan_quota, 0)) AS loan_quota,

        -- 平均周转天数
        AVG(CASE WHEN l.debt_start_date IS NOT NULL AND l.debt_end_date IS NOT NULL THEN DATE_DIFF('day', l.debt_start_date, l.debt_end_date) ELSE NULL END) AS avg_tenor_days,

        -- 逾期金额
        (SELECT SUM(COALESCE(promissory_note_balance, 0)) FROM loan_latest_per_month lp WHERE lp.natural_month = l.natural_month AND lp.customer_id = l.customer_id AND lp.settle_status = 0 AND lp.debt_end_date < MAX(l.month_end_date)) AS overdue_amount,

        -- 7天/30天到期金额
        (SELECT SUM(COALESCE(promissory_note_balance, 0)) FROM loan_latest_per_month lp WHERE lp.natural_month = l.natural_month AND lp.customer_id = l.customer_id AND lp.settle_status = 0 AND lp.debt_end_date <= MAX(l.month_end_date) + INTERVAL '7 days') AS due_7d_amount,
        (SELECT SUM(COALESCE(promissory_note_balance, 0)) FROM loan_latest_per_month lp WHERE lp.natural_month = l.natural_month AND lp.customer_id = l.customer_id AND lp.settle_status = 0 AND lp.debt_end_date <= MAX(l.month_end_date) + INTERVAL '30 days') AS due_30d_amount

    FROM loan_monthly l
    GROUP BY l.natural_month, l.customer_id
),

-- ============================================
-- 4. 期初余额（上月期末）
-- ============================================
begin_balance AS (
    SELECT customer_id, natural_month, end_balance
    FROM member_monthly
),

member_with_begin AS (
    SELECT
        m.natural_month,
        m.customer_id,
        m.customer_name,
        m.month_start_date,
        m.month_end_date,
        m.monthly_disbursement,
        m.monthly_repayment,
        m.monthly_loan_count,
        COALESCE(b_prev.end_balance, 0) AS begin_balance,
        m.end_balance,
        m.outstanding_count,
        m.loan_quota,
        m.avg_tenor_days,
        m.overdue_amount,
        m.due_7d_amount,
        m.due_30d_amount
    FROM member_monthly m
    LEFT JOIN begin_balance b_prev ON m.customer_id = b_prev.customer_id AND b_prev.natural_month = CAST(EXTRACT(YEAR FROM (DATE(SUBSTRING(CAST(m.natural_month AS VARCHAR), 1, 4) || '-' || SUBSTRING(CAST(m.natural_month AS VARCHAR), 5, 2) || '-01') - INTERVAL '1 month')) * 100 + EXTRACT(MONTH FROM (DATE(SUBSTRING(CAST(m.natural_month AS VARCHAR), 1, 4) || '-' || SUBSTRING(CAST(m.natural_month AS VARCHAR), 5, 2) || '-01') - INTERVAL '1 month')) AS BIGINT)
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    natural_month,                           -- 自然月
    month_start_date,                        -- 月起始日期
    month_end_date,                          -- 月结束日期
    customer_id,                             -- 借款企业ID
    customer_name,                           -- 借款企业名称
    begin_balance,                           -- 期初余额
    end_balance,                             -- 期末余额
    monthly_disbursement,                    -- 当月放款额
    monthly_repayment,                       -- 当月还款额
    monthly_loan_count,                      -- 当月贷款笔数
    outstanding_count,                       -- 在贷笔数
    loan_quota,                              -- 授信额度
    avg_tenor_days,                          -- 平均周转天数
    overdue_amount,                          -- 逾期金额
    due_7d_amount,                           -- 7天到期金额
    due_30d_amount,                          -- 30天到期金额
    -- 用信率(%)
    CASE WHEN loan_quota > 0 THEN ROUND(end_balance / loan_quota * 100, 2) ELSE NULL END AS utilization_rate,
    -- 逾期率(%)
    CASE WHEN end_balance > 0 THEN ROUND(overdue_amount / end_balance * 100, 2) ELSE NULL END AS overdue_rate,
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM member_with_begin
ORDER BY natural_month DESC, customer_id
