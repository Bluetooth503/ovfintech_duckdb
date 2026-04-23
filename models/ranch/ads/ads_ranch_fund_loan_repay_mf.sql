-- =============================================
-- 模型名称：ads_ranch_fund_loan_repay_mf
-- 模型描述：牧场资金放款还款月报，按客户+放款还款类型+自然月统计放款还款金额与利息
-- Dbt更新方式：全量
-- 粒度：客户 + 放款还款类型 + 自然月
-- 说明：
--   - 数据源：dws_fund_customer_loan_repay_agg_df（日粒度放还款统计）、dim_customer_ranch_rel
--   - 增量策略：全量刷新（table）
--   - 统计指标：放款还款金额、利息、笔数与净增额
--   - 聚合逻辑：通过 dim_customer_ranch_rel 精确关联，严禁使用 LIKE 模糊匹配
-- =============================================
{{ config(
    materialized='table',
    description='牧场资金放款还款月报，按客户+放款还款类型+自然月统计放款还款金额、利息与净增额',
    tags=['ranch', 'ads', 'fund', 'loan_repay', 'monthly']
) }}

-- ============================================
-- 1. 企业月度放款还款聚合（来自日粒度DWS表）
-- ============================================
WITH monthly_agg AS (
    SELECT
        DATE_TRUNC('month', stats_date) AS natural_month,
        MIN(stats_date) AS month_start_date,
        MAX(stats_date) AS month_end_date,
        customer_id,
        MAX(customer_name) AS customer_name,
        MAX(customer_type) AS customer_type,
        SUM(total_loan_amt) AS total_loan_amt,
        SUM(total_loan_cnt) AS total_loan_cnt,
        SUM(total_repay_amt) AS total_repay_amt,
        SUM(total_repay_cnt) AS total_repay_cnt,
        SUM(total_repay_interest_amt) AS total_repay_interest_amt,
        SUM(net_loan_amt) AS net_loan_amt
    FROM {{ ref('dws_fund_customer_loan_repay_agg_df') }}
    GROUP BY DATE_TRUNC('month', stats_date), customer_id
),

-- ============================================
-- 2. 按放款还款类型展开
-- ============================================
monthly_unpivot AS (
    -- 贷款
    SELECT
        natural_month,
        month_start_date,
        month_end_date,
        customer_id,
        customer_name,
        customer_type,
        '1' AS loan_repay_type,
        total_loan_amt AS total_loan_repay_quota,
        0 AS total_loan_repay_interest,
        total_loan_cnt AS loan_repay_count,
        net_loan_amt
    FROM monthly_agg
    UNION ALL
    -- 还款
    SELECT
        natural_month,
        month_start_date,
        month_end_date,
        customer_id,
        customer_name,
        customer_type,
        '2' AS loan_repay_type,
        total_repay_amt AS total_loan_repay_quota,
        total_repay_interest_amt AS total_loan_repay_interest,
        total_repay_cnt AS loan_repay_count,
        net_loan_amt
    FROM monthly_agg
),

-- ============================================
-- 3. 牧场映射
-- ============================================
ranch_mapping AS (
    SELECT
        customer_id,
        ranch_id
    FROM {{ ref('dim_customer_ranch_rel') }}
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    u.natural_month,                           -- 自然月
    u.month_start_date,                        -- 月起始日期
    u.month_end_date,                          -- 月结束日期
    rm.ranch_id,                               -- 映射牧场ID
    dr.ranch_name,                             -- 映射牧场名称
    u.customer_id,                             -- 客户ID
    u.customer_name,                           -- 客户名称
    u.customer_type,                           -- 企业类型
    u.loan_repay_type,                         -- 放款还款类型
    ROUND(u.total_loan_repay_quota, 2) AS total_loan_repay_quota,          -- 放款还款金额合计
    ROUND(u.total_loan_repay_interest, 2) AS total_loan_repay_interest,    -- 放款还款利息合计
    u.loan_repay_count,                        -- 放款还款笔数
    ROUND(u.net_loan_amt, 2) AS net_loan_amt,  -- 净增额
    CURRENT_TIMESTAMP AS dw_update_time        -- 数据仓库更新时间
FROM monthly_unpivot u
LEFT JOIN ranch_mapping rm ON u.customer_id = rm.customer_id
LEFT JOIN {{ ref('dim_ranch') }} dr ON rm.ranch_id = dr.ranch_id
ORDER BY natural_month DESC, ranch_id, customer_id, loan_repay_type
