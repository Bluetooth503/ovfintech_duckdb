-- =============================================
-- 模型名称：dws_fund_customer_loan_balance_agg_df
-- 模型描述：客户贷款余额日聚合表，按客户+统计日期粒度汇总贷款余额核心指标（线上/线下/授信/逾期/到期）
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dwd_fund_promissory_note_fact_i（借据）+ dwd_fund_credit_fact_i（授信）+ dwd_fund_offline_loan_fact_i（线下）
--   - 增量策略：按日期全量刷新，保留历史数据
--   - 核心指标：线上/线下/总贷款余额、授信额度、剩余额度、逾期余额、到期预警余额
--   - 派生指标：昨日余额、当日余额变动、用信率、逾期率、敞口合计
--   - 替代生产环境 dws_fund_member_daily + dws_fund_member_offline_daily 的贷款余额部分
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户贷款余额日聚合表，按客户+统计日期粒度汇总贷款余额核心指标',
    tags=['fund', 'dws', 'agg', 'customer', 'loan_balance', 'daily']
) }}

WITH credit_daily AS (
    SELECT
        customer_id,
        MAX(customer_name) AS customer_name,
        MAX(customer_type) AS customer_type,
        CAST(trx_date AS DATE) AS stats_date,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota
    FROM (
        SELECT
            credit_id,
            customer_id,
            customer_name,
            customer_type,
            credit_quota,
            remain_quota,
            credit_used_quota,
            CAST(trx_date AS DATE) AS trx_date,
            ROW_NUMBER() OVER (PARTITION BY credit_id, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_credit_fact_i') }}
        WHERE credit_result = '1'
    ) ranked
    WHERE rn = 1
    GROUP BY customer_id, CAST(trx_date AS DATE)
),

online_loan_balance_daily AS (
    SELECT
        credit.customer_id,
        MAX(credit.customer_name) AS customer_name,
        MAX(credit.customer_type) AS customer_type,
        pn.stats_date,
        SUM(CASE WHEN pn.loan_balance > 0 THEN pn.loan_balance ELSE 0 END) AS online_loan_balance,
        COUNT(CASE WHEN pn.loan_balance > 0 THEN 1 END) AS online_promissory_note_cnt,
        SUM(CASE WHEN pn.is_overdue = '1' AND pn.loan_balance > 0 THEN pn.loan_balance ELSE 0 END) AS online_overdue_balance,
        COUNT(CASE WHEN pn.is_overdue = '1' AND pn.loan_balance > 0 THEN 1 END) AS online_overdue_cnt,
        SUM(CASE WHEN pn.is_due_within_7d = '1' AND pn.loan_balance > 0 THEN pn.loan_balance ELSE 0 END) AS online_due_7d_balance,
        SUM(CASE WHEN pn.is_due_within_30d = '1' AND pn.loan_balance > 0 THEN pn.loan_balance ELSE 0 END) AS online_due_30d_balance
    FROM (
        SELECT
            contract_code,
            loan_balance,
            CAST(trx_date AS DATE) AS stats_date,
            CASE
                WHEN CAST(promissory_note_end_date AS DATE) < CAST(trx_date AS DATE) THEN '1'
                ELSE '0'
            END AS is_overdue,
            CASE
                WHEN CAST(promissory_note_end_date AS DATE) >= CAST(trx_date AS DATE)
                     AND CAST(promissory_note_end_date AS DATE) <= CAST(trx_date AS DATE) + INTERVAL '7' DAY THEN '1'
                ELSE '0'
            END AS is_due_within_7d,
            CASE
                WHEN CAST(promissory_note_end_date AS DATE) >= CAST(trx_date AS DATE)
                     AND CAST(promissory_note_end_date AS DATE) <= CAST(trx_date AS DATE) + INTERVAL '30' DAY THEN '1'
                ELSE '0'
            END AS is_due_within_30d,
            ROW_NUMBER() OVER (PARTITION BY promissory_note_no, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_promissory_note_fact_i') }}
        WHERE promissory_note_status = '0'
    ) pn
    LEFT JOIN (
        SELECT DISTINCT customer_contract_no, customer_id, customer_name, customer_type
        FROM {{ ref('dwd_fund_credit_fact_i') }}
        WHERE credit_result = '1' AND customer_id IS NOT NULL
    ) credit ON credit.customer_contract_no = pn.contract_code
    WHERE pn.rn = 1 AND credit.customer_id IS NOT NULL
    GROUP BY credit.customer_id, pn.stats_date
),

offline_loan_balance_daily AS (
    SELECT
        customer_id,
        MAX(customer_name) AS customer_name,
        MAX(customer_type) AS customer_type,
        stats_date,
        SUM(CASE WHEN loan_repay_type = '1' THEN loan_amount ELSE 0 END) - SUM(CASE WHEN loan_repay_type = '2' THEN loan_amount ELSE 0 END) AS offline_loan_balance,
        SUM(CASE WHEN loan_repay_type = '1' THEN loan_amount ELSE 0 END) AS offline_cumulative_disbursement,
        SUM(CASE WHEN loan_repay_type = '2' THEN loan_amount ELSE 0 END) AS offline_cumulative_repay
    FROM (
        SELECT
            customer_id,
            customer_name,
            customer_type,
            loan_repay_type,
            loan_amount,
            CAST(statistics_date AS DATE) AS stats_date,
            ROW_NUMBER() OVER (PARTITION BY trx_id) AS rn
        FROM {{ ref('dwd_fund_offline_loan_fact_i') }}
    ) dedup
    WHERE rn = 1
    GROUP BY customer_id, stats_date
),

offline_balance_cumulative AS (
    SELECT
        customer_id,
        stats_date,
        customer_name,
        customer_type,
        offline_loan_balance,
        offline_cumulative_disbursement,
        offline_cumulative_repay,
        SUM(offline_cumulative_disbursement) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_offline_cumulative_disbursement,
        SUM(offline_cumulative_repay) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_offline_cumulative_repay,
        SUM(offline_cumulative_disbursement) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS year_offline_cumulative_disbursement,
        SUM(offline_cumulative_repay) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS year_offline_cumulative_repay
    FROM offline_loan_balance_daily
),

merged AS (
    SELECT
        COALESCE(cr.customer_id, ol.customer_id, obc.customer_id) AS customer_id,
        COALESCE(cr.customer_name, ol.customer_name, obc.customer_name) AS customer_name,
        COALESCE(cr.customer_type, ol.customer_type, obc.customer_type) AS customer_type,
        COALESCE(cr.stats_date, ol.stats_date, obc.stats_date) AS stats_date,
        COALESCE(cr.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cr.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(cr.total_credit_used_quota, 0) AS total_credit_used_quota,
        COALESCE(ol.online_loan_balance, 0) AS online_loan_balance,
        COALESCE(ol.online_promissory_note_cnt, 0) AS online_promissory_note_cnt,
        COALESCE(ol.online_overdue_balance, 0) AS online_overdue_balance,
        COALESCE(ol.online_overdue_cnt, 0) AS online_overdue_cnt,
        COALESCE(ol.online_due_7d_balance, 0) AS online_due_7d_balance,
        COALESCE(ol.online_due_30d_balance, 0) AS online_due_30d_balance,
        CASE WHEN COALESCE(obc.offline_loan_balance, 0) > 0 THEN obc.offline_loan_balance ELSE 0 END AS offline_loan_balance,
        COALESCE(obc.total_offline_cumulative_disbursement, 0) AS total_offline_cumulative_disbursement,
        COALESCE(obc.total_offline_cumulative_repay, 0) AS total_offline_cumulative_repay,
        COALESCE(obc.year_offline_cumulative_disbursement, 0) AS year_offline_cumulative_disbursement,
        COALESCE(obc.year_offline_cumulative_repay, 0) AS year_offline_cumulative_repay
    FROM credit_daily cr
    FULL OUTER JOIN online_loan_balance_daily ol ON cr.customer_id = ol.customer_id AND cr.stats_date = ol.stats_date
    FULL OUTER JOIN offline_balance_cumulative obc ON COALESCE(cr.customer_id, ol.customer_id) = obc.customer_id AND COALESCE(cr.stats_date, ol.stats_date) = obc.stats_date
),

with_prev AS (
    SELECT
        *,
        LAG(online_loan_balance + offline_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date) AS prev_total_loan_balance,
        online_loan_balance + offline_loan_balance AS total_loan_balance
    FROM merged
)

SELECT
    customer_id,                                                           -- 客户ID
    customer_name,                                                         -- 客户名称
    customer_type,                                                         -- 客户类型
    stats_date,                                                            -- 统计日期

    total_credit_quota,                                                    -- 总授信额度
    total_remain_quota,                                                    -- 总剩余额度（客户剩余可用授信）
    total_credit_used_quota,                                               -- 总授信已用额度

    total_loan_balance,                                                    -- 总贷款余额（线上+线下）
    online_loan_balance,                                                   -- 线上贷款余额
    offline_loan_balance,                                                  -- 线下贷款余额

    online_promissory_note_cnt,                                            -- 线上在贷借据笔数
    online_overdue_balance,                                                -- 线上逾期余额
    online_overdue_cnt,                                                    -- 线上逾期借据笔数
    online_due_7d_balance,                                                 -- 7天内到期余额（线上）
    online_due_30d_balance,                                                -- 30天内到期余额（线上）

    prev_total_loan_balance,                                               -- 昨日总贷款余额
    total_loan_balance - COALESCE(prev_total_loan_balance, 0) AS daily_balance_change,  -- 当日余额变动

    total_offline_cumulative_disbursement,                                 -- 线下累计放款金额
    total_offline_cumulative_repay,                                        -- 线下累计还款金额
    year_offline_cumulative_disbursement,                                  -- 线下年累计放款金额
    year_offline_cumulative_repay,                                         -- 线下年累计还款金额

    CASE WHEN total_credit_quota > 0 THEN ROUND((total_credit_used_quota / total_credit_quota) * 100, 2) ELSE 0 END AS utilization_rate,  -- 用信率（%）
    CASE WHEN total_loan_balance > 0 THEN ROUND((online_overdue_balance / total_loan_balance) * 100, 2) ELSE 0 END AS overdue_rate,  -- 逾期率（%）

    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户
    CASE WHEN online_loan_balance > 0 THEN '1' ELSE '0' END AS has_online_loan,  -- 是否有线上贷款
    CASE WHEN offline_loan_balance > 0 THEN '1' ELSE '0' END AS has_offline_loan,  -- 是否有线下贷款

    CURRENT_TIMESTAMP AS dw_update_time                                    -- 数据仓库更新时间

FROM with_prev
WHERE total_credit_quota > 0 OR total_loan_balance > 0 OR online_loan_balance > 0 OR offline_loan_balance > 0
ORDER BY customer_id, stats_date DESC
