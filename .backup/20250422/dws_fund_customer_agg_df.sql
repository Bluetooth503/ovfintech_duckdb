-- =============================================
-- 模型名称：dws_fund_customer_agg_df
-- 模型描述：客户资金日汇总表，按客户和日期维度汇总客户资金指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信）+ dwd_fund_promissory_note_fact_i（借据）+ dwd_fund_online_loan_fact_i（交易）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 整合客户级的授信、放款、还款、余额等全部指标
--   - 核心指标：授信额度、贷款余额、当日放还款、累计值等
--   - 替代生产环境被6个任务重复写入的 dws_fund_member_daily
--   - 消除重复计算，统一指标口径，单一事实来源
--   - 用于客户分析、风险评估、业务报表
--   - 架构设计：核心客户汇总表，下游ADS层基础
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户资金日汇总表，按客户和日期维度汇总客户资金指标',
    tags=['fund', 'dws', 'agg', 'customer', 'daily']
) }}

WITH customer_credit_daily AS (
    -- ============================================
    -- 按客户和日期汇总授信信息
    -- ============================================
    WITH ranked_credits AS (
        SELECT
            customer_id,
            customer_name,
            credit_quota,
            remain_quota,
            credit_used_quota,
            CAST(trx_date AS DATE) AS stats_date,
            ROW_NUMBER() OVER (PARTITION BY customer_id, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_credit_fact_i') }}
        WHERE credit_result = '1'  -- 有效授信
    )
    SELECT
        customer_id,
        customer_name,
        stats_date,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota
    FROM ranked_credits
    WHERE rn = 1
    GROUP BY customer_id, customer_name, stats_date
),

customer_loan_balance_daily AS (
    -- ============================================
    -- 按客户和日期汇总借据余额
    -- ============================================
    WITH ranked_promissory_notes AS (
        SELECT
            contract_code,
            loan_balance,
            CAST(trx_date AS DATE) AS stats_date,
            update_time,
            ROW_NUMBER() OVER (PARTITION BY contract_code, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_promissory_note_fact_i') }}
        WHERE promissory_note_status = '0'  -- 有效借据
    ),
    promissory_note_with_customer AS (
        SELECT
            c.customer_id,
            pn.stats_date,
            pn.loan_balance
        FROM ranked_promissory_notes pn
        LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
            ON c.customer_contract_no = pn.contract_code
            AND c.credit_result = '1'
        WHERE pn.rn = 1
    )
    SELECT
        customer_id,
        stats_date,
        SUM(loan_balance) AS total_loan_balance,
        COUNT(CASE WHEN loan_balance > 0 THEN 1 END) AS outstanding_promissory_note_cnt
    FROM promissory_note_with_customer
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id, stats_date
),

customer_daily_transaction AS (
    -- ============================================
    -- 按客户和日期汇总当日交易（放款+还款）
    -- ============================================
    SELECT
        customer_id,
        CAST(trx_date AS DATE) AS stats_date,
        -- 当日放款
        SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS daily_loan_amt,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS daily_loan_cnt,
        -- 当日还款
        SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS daily_repay_amt,
        SUM(CASE WHEN loan_repay_type = '2' THEN repay_interest_amount ELSE 0 END) AS daily_repay_interest_amt,
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS daily_repay_cnt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type IN ('1', '2')  -- 放款和还款
    GROUP BY customer_id, CAST(trx_date AS DATE)
),

-- ============================================
-- 合并所有客户数据
-- =============================================
all_customer_daily AS (
    SELECT
        COALESCE(cc.customer_id, clb.customer_id, cdt.customer_id) AS customer_id,
        COALESCE(cc.customer_name,
                 (SELECT customer_name FROM customer_credit_daily ccd WHERE ccd.customer_id = COALESCE(clb.customer_id, cdt.customer_id) LIMIT 1)) AS customer_name,
        COALESCE(cc.stats_date, clb.stats_date, cdt.stats_date) AS stats_date,

        -- 授信信息
        COALESCE(cc.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cc.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(cc.total_credit_used_quota, 0) AS total_credit_used_quota,

        -- 贷款余额
        COALESCE(clb.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(clb.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt,

        -- 当日放款
        COALESCE(cdt.daily_loan_amt, 0) AS daily_loan_amt,
        COALESCE(cdt.daily_loan_cnt, 0) AS daily_loan_cnt,

        -- 当日还款
        COALESCE(cdt.daily_repay_amt, 0) AS daily_repay_amt,
        COALESCE(cdt.daily_repay_interest_amt, 0) AS daily_repay_interest_amt,
        COALESCE(cdt.daily_repay_cnt, 0) AS daily_repay_cnt

    FROM customer_credit_daily cc
    FULL OUTER JOIN customer_loan_balance_daily clb
        ON cc.customer_id = clb.customer_id AND cc.stats_date = clb.stats_date
    FULL OUTER JOIN customer_daily_transaction cdt
        ON COALESCE(cc.customer_id, clb.customer_id) = cdt.customer_id
        AND COALESCE(cc.stats_date, clb.stats_date) = cdt.stats_date
),

-- ============================================
-- 计算累计指标
-- =============================================
customer_cumulative AS (
    SELECT
        customer_id,
        stats_date,
        -- 累计放款金额（从第一天开始累计）
        SUM(daily_loan_amt) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_loan_amt,
        -- 累计还款金额（从第一天开始累计）
        SUM(daily_repay_amt) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_repay_amt,
        -- 年累计放款
        SUM(daily_loan_amt) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS year_cumulative_loan_amt,
        -- 年累计还款
        SUM(daily_repay_amt) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS year_cumulative_repay_amt,
        -- 昨日余额（前一行的余额）
        LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date) AS prev_loan_balance,
        -- 当日余额变动
        total_loan_balance - LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date) AS daily_balance_change
    FROM all_customer_daily
)

-- ============================================
-- 最终 SELECT
-- =============================================
SELECT
    -- 主键
    acd.customer_id,                                                       -- 客户ID
    acd.customer_name,                                                     -- 客户名称
    acd.stats_date,                                                        -- 统计日期

    -- 授信额度信息
    acd.total_credit_quota,                                                -- 总授信额度
    acd.total_remain_quota,                                                -- 总剩余额度
    acd.total_credit_used_quota,                                           -- 总授信已用额度

    -- 贷款余额
    acd.total_loan_balance,                                                -- 总贷款余额
    acd.outstanding_promissory_note_cnt,                                   -- 在贷笔数

    -- 当日放款
    acd.daily_loan_amt,                                                    -- 当日放款金额
    acd.daily_loan_cnt,                                                    -- 当日放款笔数

    -- 当日还款
    acd.daily_repay_amt,                                                   -- 当日还款金额
    acd.daily_repay_interest_amt,                                          -- 当日还款利息
    acd.daily_repay_cnt,                                                   -- 当日还款笔数

    -- 比率指标
    CASE
        WHEN acd.total_credit_quota > 0
        THEN ROUND((acd.total_credit_used_quota / acd.total_credit_quota) * 100, 2)
        ELSE 0
    END AS utilization_rate,                                               -- 用信率（%）

    -- 累计指标
    cc.cumulative_loan_amt,                                                -- 累计放款金额
    cc.cumulative_repay_amt,                                               -- 累计还款金额
    cc.year_cumulative_loan_amt,                                           -- 年累计放款金额
    cc.year_cumulative_repay_amt,                                          -- 年累计还款金额

    -- 快照字段
    cc.prev_loan_balance,                                                  -- 昨日贷款余额
    cc.daily_balance_change,                                               -- 当日余额变动

    -- 标识字段
    CASE WHEN acd.total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户
    CASE WHEN acd.daily_loan_amt > 0 OR acd.daily_repay_amt > 0 THEN '1' ELSE '0' END AS has_daily_transaction,  -- 是否有当日交易

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM all_customer_daily acd
LEFT JOIN customer_cumulative cc
    ON acd.customer_id = cc.customer_id AND acd.stats_date = cc.stats_date

WHERE acd.total_credit_quota > 0 OR acd.total_loan_balance > 0 OR acd.daily_loan_amt > 0 OR acd.daily_repay_amt > 0  -- 只保留有活动的客户
ORDER BY acd.customer_id, acd.stats_date DESC
