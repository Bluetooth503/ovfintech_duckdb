-- =============================================
-- 模型名称：ads_ranch_fund_dashboard_mf
-- 模型描述：牧场资金运营月报，按牧场+自然月统计贷款流动、余额、周转与风险指标
-- Dbt更新方式：全量
-- 粒度：牧场 + 自然月
-- 说明：
--   - 数据源：DWS聚合表、dim_customer_ranch_rel
--   - 增量策略：全量刷新（table）
--   - 统计指标：贷款流动、余额、周转与风险指标
--   - 聚合逻辑：通过 dim_customer_ranch_rel 精确关联，严禁使用 LIKE 模糊匹配
-- =============================================
{{ config(
    materialized='table',
    description='牧场资金运营月报，按牧场+自然月统计贷款规模、流动、周转及风险指标',
    tags=['ranch', 'ads', 'fund', 'dashboard', 'monthly']
) }}

-- ============================================
-- 1. 企业月度贷款聚合（来自DWS聚合表）
-- ============================================
WITH loan_monthly AS (
    SELECT
        natural_month,
        month_start_date,
        month_end_date,
        customer_id,
        customer_name,
        begin_balance,
        end_balance,
        monthly_disbursement,
        monthly_repayment,
        monthly_loan_count,
        outstanding_count,
        loan_quota,
        utilization_rate,
        avg_tenor_days,
        overdue_amount,
        due_7d_amount,
        due_30d_amount,
        overdue_rate
    FROM {{ ref('dws_fund_loan_customer_monthly_agg_mi') }}
),

-- ============================================
-- 2. 牧场映射（通过客户-牧场映射关系表关联）
-- ============================================
ranch_mapping AS (
    SELECT
        customer_id,
        ranch_id
    FROM {{ ref('dim_customer_ranch_rel') }}
),

-- ============================================
-- 3. 牧场级质押率（按月最后一天）
-- ============================================
monthly_pledge AS (
    SELECT
        EXTRACT(YEAR FROM stat_date) * 100 + EXTRACT(MONTH FROM stat_date) AS natural_month,
        ranch_id,
        AVG(pledge_ratio) AS avg_pledge_ratio,
        SUM(total_estimated_value) AS total_estimated_value,
        SUM(total_loan_money) AS total_loan_money
    FROM {{ ref('dws_ranch_cattle_balance_agg_di') }}
    WHERE stat_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 4. 映射整合到牧场
-- ============================================
mapped AS (
    SELECT
        l.natural_month,
        l.month_start_date,
        l.month_end_date,
        rm.ranch_id,
        dr.ranch_name,
        l.customer_id,
        l.customer_name,
        l.begin_balance,
        l.end_balance,
        l.monthly_disbursement,
        l.monthly_repayment,
        l.monthly_loan_count,
        l.outstanding_count,
        l.loan_quota,
        l.utilization_rate,
        l.avg_tenor_days,
        l.overdue_amount,
        l.due_7d_amount,
        l.due_30d_amount,
        l.overdue_rate,
        mp.avg_pledge_ratio,
        mp.total_estimated_value,
        mp.total_loan_money
    FROM loan_monthly l
    LEFT JOIN ranch_mapping rm ON l.customer_id = rm.customer_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON rm.ranch_id = dr.ranch_id
    LEFT JOIN monthly_pledge mp ON rm.ranch_id = mp.ranch_id AND l.natural_month = mp.natural_month
)

-- ============================================
-- 最终 SELECT（按牧场+月份聚合）
-- ============================================
SELECT
    natural_month,                           -- 自然月
    month_start_date,                        -- 月起始日期
    month_end_date,                          -- 月结束日期
    ranch_id,                                -- 牧场ID
    ranch_name,                              -- 牧场名称

    -- 贷款规模
    ROUND(SUM(begin_balance), 2) AS begin_balance,             -- 期初余额
    ROUND(SUM(end_balance), 2) AS end_balance,                 -- 期末余额
    ROUND(SUM(monthly_disbursement), 2) AS monthly_disbursement, -- 当月放款额
    ROUND(SUM(monthly_repayment), 2) AS monthly_repayment,     -- 当月还款额
    SUM(monthly_loan_count) AS monthly_loan_count,             -- 当月贷款笔数
    SUM(outstanding_count) AS outstanding_count,               -- 在贷笔数
    COUNT(DISTINCT customer_id) AS outstanding_member_count,   -- 在贷户数
    MAX(loan_quota) AS loan_quota,                             -- 授信额度

    -- 用信率（按牧场聚合后的期末余额 / 授信额度）
    CASE WHEN MAX(loan_quota) > 0 THEN ROUND(SUM(end_balance) / MAX(loan_quota) * 100, 2) ELSE NULL END AS utilization_rate,

    -- 周转与风险
    ROUND(AVG(avg_tenor_days), 1) AS avg_tenor_days,         -- 平均周转天数
    ROUND(SUM(overdue_amount), 2) AS overdue_amount,         -- 逾期金额
    ROUND(SUM(due_7d_amount), 2) AS due_7d_amount,           -- 7天到期金额
    ROUND(SUM(due_30d_amount), 2) AS due_30d_amount,         -- 30天到期金额
    CASE WHEN SUM(end_balance) > 0 THEN ROUND(SUM(overdue_amount) / SUM(end_balance) * 100, 2) ELSE NULL END AS overdue_rate,  -- 逾期率(%)

    -- 牧场质押（仅映射成功时有值）
    ROUND(AVG(avg_pledge_ratio), 2) AS avg_pledge_ratio,     -- 平均质押率(%)
    ROUND(SUM(total_estimated_value), 2) AS total_estimated_value, -- 在栏货值
    ROUND(SUM(total_loan_money), 2) AS total_loan_money,     -- 在栏贷款余额

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time                      -- 数据仓库更新时间

FROM mapped
GROUP BY natural_month, month_start_date, month_end_date, ranch_id, ranch_name
ORDER BY natural_month DESC, ranch_id
