-- =============================================
-- 模型名称：dws_fund_billing_customer_monthly_agg_mi
-- 模型描述：企业账单月度聚合表，按借款企业+金融产品+账单类型+自然月统计账单金额与利息
-- Dbt更新方式：增量（按月）
-- 粒度：customer_id + financial_product_id + bill_type + natural_month
-- 说明：
--   - 数据源：dwd_fund_online_loan_fact_i（在线贷款明细）
--   - 统计指标：账单金额合计、利息合计、平均贷款余额、账单笔数
--   - 聚合逻辑：按自然月+客户+产品+账单类型 GROUP BY 汇总
-- =============================================
{{ config(
    materialized='table',
    description='企业账单月度聚合表，按借款企业+金融产品+账单类型+自然月统计账单金额、利息与贷款余额',
    tags=['fund', 'dws', 'agg', 'billing', 'monthly']
) }}

WITH billing_detail AS (
    SELECT
        customer_id,
        customer_type,
        customer_name,
        financial_product_id,
        financial_product_name,
        loan_repay_type,
        bill_amount,
        repay_interest_amount,
        promissory_note_balance,
        promissory_note_no,
        trx_sn,
        EXTRACT(YEAR FROM trx_time::timestamp) * 100 + EXTRACT(MONTH FROM trx_time::timestamp) AS natural_month,
        DATE_TRUNC('month', trx_time::timestamp)::DATE AS month_start_date,
        (DATE_TRUNC('month', trx_time::timestamp) + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS month_end_date
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE trx_time IS NOT NULL
)

SELECT
    natural_month,                                            -- 自然月
    month_start_date,                                         -- 月起始日期
    month_end_date,                                           -- 月结束日期
    customer_id,                                              -- 借款企业ID
    MAX(customer_name) AS customer_name,                      -- 借款企业名称
    MAX(customer_type) AS customer_type,                      -- 企业类型
    financial_product_id,                                     -- 金融产品ID
    MAX(financial_product_name) AS financial_product_name,    -- 金融产品名称
    loan_repay_type,                                                -- 账单类型
    SUM(COALESCE(bill_amount, 0)) AS total_bill_quota,         -- 账单金额合计
    SUM(COALESCE(repay_interest_amount, 0)) AS total_bill_interest,   -- 账单利息合计
    AVG(promissory_note_balance) AS avg_loan_balance,                    -- 平均贷款余额
    COUNT(*) AS bill_count,                                   -- 账单笔数
    COUNT(DISTINCT promissory_note_no) AS loan_no_count,                 -- 贷款编号数
    COUNT(DISTINCT trx_sn) AS serial_no_count,             -- 业务流水号数
    CURRENT_TIMESTAMP AS dw_update_time                       -- 数据仓库更新时间
FROM billing_detail
GROUP BY natural_month, month_start_date, month_end_date, customer_id, financial_product_id, loan_repay_type
ORDER BY natural_month DESC, customer_id, financial_product_id, loan_repay_type
