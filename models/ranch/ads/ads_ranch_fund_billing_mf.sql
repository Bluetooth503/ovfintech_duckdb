-- =============================================
-- 模型名称：ads_ranch_fund_billing_mf
-- 模型描述：牧场资金账单月报，按客户+金融产品+账单类型+自然月统计账单金额与利息
-- Dbt更新方式：全量
-- 粒度：客户 + 金融产品 + 账单类型 + 自然月
-- 说明：
--   - 数据源：DWS聚合表、dim_customer_ranch_rel
--   - 增量策略：全量刷新（table）
--   - 统计指标：账单金额与利息收入
--   - 聚合逻辑：通过 dim_customer_ranch_rel 精确关联，严禁使用 LIKE 模糊匹配
-- =============================================
{{ config(
    materialized='table',
    description='牧场资金账单月报，按客户+金融产品+账单类型+自然月统计账单金额、利息与贷款余额',
    tags=['ranch', 'ads', 'fund', 'billing', 'monthly']
) }}

-- ============================================
-- 1. 企业月度账单聚合（来自DWS聚合表）
-- ============================================
WITH billing_agg AS (
    SELECT
        natural_month,
        month_start_date,
        month_end_date,
        customer_id,
        customer_name,
        customer_type,
        financial_product_id,
        financial_product_name,
        loan_repay_type,
        total_bill_quota,
        total_bill_interest,
        avg_loan_balance,
        bill_count,
        loan_no_count,
        serial_no_count
    FROM {{ ref('dws_fund_billing_customer_monthly_agg_mi') }}
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
-- 3. 映射整合
-- ============================================
mapped AS (
    SELECT
        a.natural_month,
        a.month_start_date,
        a.month_end_date,
        rm.ranch_id,
        dr.ranch_name,
        a.customer_id,
        a.customer_name,
        a.customer_type,
        a.financial_product_id,
        a.financial_product_name,
        a.loan_repay_type,
        a.total_bill_quota,
        a.total_bill_interest,
        a.avg_loan_balance,
        a.bill_count,
        a.loan_no_count,
        a.serial_no_count
    FROM billing_agg a
    LEFT JOIN ranch_mapping rm ON a.customer_id = rm.customer_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON rm.ranch_id = dr.ranch_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    natural_month,                           -- 自然月
    month_start_date,                        -- 月起始日期
    month_end_date,                          -- 月结束日期
    ranch_id,                                -- 映射牧场ID
    ranch_name,                              -- 映射牧场名称
    customer_id,                                             -- 客户ID
    customer_name,                                           -- 客户名称
    customer_type,                                           -- 企业类型
    financial_product_id,                    -- 金融产品ID
    financial_product_name,                  -- 金融产品名称
    loan_repay_type,                               -- 账单类型

    -- 金额指标
    ROUND(total_bill_quota, 2) AS total_bill_quota,          -- 账单金额合计
    ROUND(total_bill_interest, 2) AS total_bill_interest,    -- 账单利息合计
    ROUND(avg_loan_balance, 2) AS avg_loan_balance,          -- 平均贷款余额

    -- 笔数指标
    bill_count,                              -- 账单笔数
    loan_no_count,                           -- 贷款编号数
    serial_no_count,                         -- 业务流水号数

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM mapped
ORDER BY natural_month DESC, ranch_id, customer_id, financial_product_id, loan_repay_type
