-- =============================================
-- 模型名称：dws_fund_customer_loan_state
-- 模型描述：客户贷款当前状态表，记录每个客户的授信、贷款、交易、累计等完整指标的最新状态（T-1日）
-- Dbt更新方式：全量
-- 粒度：customer_id
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信）+ dwd_fund_promissory_note_fact_i（借据）+ dwd_fund_online_loan_fact_i（交易）
--   - 更新策略：每日全量覆盖，计算 T-1 日截止时刻的完整状态，不保留历史数据
--   - 业务时间过滤：只统计 trx_date <= T-1 的交易数据
--   - 计算逻辑：
--     * 授信额度：从授信事实表获取（credit_quota, remain_quota, credit_used_quota）
--     * 贷款余额：从借据事实表获取（loan_balance），按借据号取最新状态
--     * 当日交易：从交易事实表获取 T-1 日的放款和还款
--     * 累计指标：使用窗口函数计算累计放款、累计还款
--   - 用于客户维度表关联，判断是否贷款客户
--   - 架构设计：三层结构的第一层，为 snap 和 agg 提供基础
--   - 命名说明：_state_df 表示当前状态快照，日全量覆盖，不保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户贷款当前状态表，记录每个客户的授信、贷款、交易、累计等完整指标的最新状态（T-1日）',
    tags=['fund', 'dws', 'state', 'customer', 'loan']
) }}

WITH target_date AS (
    -- ============================================
    -- 定义目标统计日期：T-1
    -- ============================================
    SELECT CURRENT_DATE - INTERVAL '1 day' AS stats_date
),

credit_quota AS (
    -- ============================================
    -- 1. 授信额度信息（从授信事实表获取）
    -- ============================================
    WITH ranked_credits AS (
        SELECT
            customer_id,
            credit_quota,
            remain_quota,
            credit_used_quota,
            update_time,
            ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_credit_fact_i') }}
        WHERE credit_result = '1'  -- 有效授信
          AND trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
    )
    SELECT
        customer_id,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota
    FROM ranked_credits
    WHERE rn = 1  -- 取最新授信记录
    GROUP BY customer_id
),

loan_balance AS (
    -- ============================================
    -- 2. 贷款余额（从借据事实表获取）
    -- ============================================
    WITH latest_promissory_note AS (
        -- 按借据号取最新状态（T-1日）
        SELECT
            pn.promissory_note_no,
            pn.loan_balance,
            pn.contract_code,
            pn.trx_date,
            pn.update_time,
            ROW_NUMBER() OVER (PARTITION BY pn.promissory_note_no ORDER BY pn.update_time DESC) AS rn
        FROM {{ ref('dwd_fund_promissory_note_fact_i') }} pn
        WHERE pn.trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
          AND pn.promissory_note_status = '0'  -- 有效借据
    ),
    promissory_note_with_customer AS (
        -- 通过 contract_code 关联授信表获取 customer_id
        SELECT
            c.customer_id,
            pn.promissory_note_no,
            pn.loan_balance
        FROM latest_promissory_note pn
        LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
            ON c.customer_contract_no = pn.contract_code
            AND c.credit_result = '1'  -- 有效授信
            AND c.trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
        WHERE pn.rn = 1  -- 取每笔借据的最新记录
          AND pn.loan_balance > 0  -- 只保留有余额的借据
    )
    SELECT
        customer_id,
        SUM(loan_balance) AS total_loan_balance,
        COUNT(DISTINCT promissory_note_no) AS outstanding_promissory_note_cnt
    FROM promissory_note_with_customer
    WHERE customer_id IS NOT NULL  -- 排除无法关联到客户的借据
    GROUP BY customer_id
),

daily_transaction AS (
    -- ============================================
    -- 3. T-1日交易汇总
    -- ============================================
    SELECT
        customer_id,
        -- 放款（loan_repay_type = 1）
        SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS daily_loan_amt,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS daily_loan_cnt,
        -- 还款（loan_repay_type = 2）
        SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS daily_repay_amt,
        SUM(CASE WHEN loan_repay_type = '2' THEN repay_interest_amount ELSE 0 END) AS daily_repay_interest_amt,
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS daily_repay_cnt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type IN ('1', '2')  -- 放款和还款
      AND trx_date = (SELECT stats_date FROM target_date)  -- T-1 日
    GROUP BY customer_id
),

cumulative_metrics AS (
    -- ============================================
    -- 4. 累计指标计算
    -- ============================================
    WITH all_daily_transactions AS (
        -- 获取所有历史交易数据
        SELECT
            customer_id,
            CAST(trx_date AS DATE) AS trx_date,
            SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS daily_loan_amt,
            SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS daily_repay_amt
        FROM {{ ref('dwd_fund_online_loan_fact_i') }}
        WHERE loan_repay_type IN ('1', '2')
          AND trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
        GROUP BY customer_id, CAST(trx_date AS DATE)
    ),
    cumulative_calc AS (
        SELECT
            customer_id,
            -- 累计放款金额
            SUM(daily_loan_amt) AS cumulative_loan_amt,
            -- 累计还款金额
            SUM(daily_repay_amt) AS cumulative_repay_amt,
            -- 年累计放款
            SUM(CASE WHEN DATE_TRUNC('year', trx_date) = DATE_TRUNC('year', (SELECT stats_date FROM target_date))
                    THEN daily_loan_amt ELSE 0 END) AS year_cumulative_loan_amt,
            -- 年累计还款
            SUM(CASE WHEN DATE_TRUNC('year', trx_date) = DATE_TRUNC('year', (SELECT stats_date FROM target_date))
                    THEN daily_repay_amt ELSE 0 END) AS year_cumulative_repay_amt
        FROM all_daily_transactions
        GROUP BY customer_id
    )
    SELECT * FROM cumulative_calc
),

-- ============================================
-- 合并所有数据
-- =============================================
all_customer_state AS (
    SELECT
        COALESCE(cq.customer_id, lb.customer_id, dt.customer_id, cm.customer_id) AS customer_id,
        -- 授信额度
        COALESCE(cq.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cq.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(cq.total_credit_used_quota, 0) AS total_credit_used_quota,
        -- 贷款余额
        COALESCE(lb.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(lb.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt,
        -- T-1日交易
        COALESCE(dt.daily_loan_amt, 0) AS daily_loan_amt,
        COALESCE(dt.daily_loan_cnt, 0) AS daily_loan_cnt,
        COALESCE(dt.daily_repay_amt, 0) AS daily_repay_amt,
        COALESCE(dt.daily_repay_interest_amt, 0) AS daily_repay_interest_amt,
        COALESCE(dt.daily_repay_cnt, 0) AS daily_repay_cnt,
        -- 累计指标
        COALESCE(cm.cumulative_loan_amt, 0) AS cumulative_loan_amt,
        COALESCE(cm.cumulative_repay_amt, 0) AS cumulative_repay_amt,
        COALESCE(cm.year_cumulative_loan_amt, 0) AS year_cumulative_loan_amt,
        COALESCE(cm.year_cumulative_repay_amt, 0) AS year_cumulative_repay_amt
    FROM credit_quota cq
    FULL OUTER JOIN loan_balance lb ON cq.customer_id = lb.customer_id
    FULL OUTER JOIN daily_transaction dt ON COALESCE(cq.customer_id, lb.customer_id) = dt.customer_id
    FULL OUTER JOIN cumulative_metrics cm ON COALESCE(cq.customer_id, lb.customer_id, dt.customer_id) = cm.customer_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    customer_id,                                                           -- 客户ID

    -- 授信额度信息
    total_credit_quota,                                                    -- 总授信额度
    total_remain_quota,                                                    -- 总剩余额度
    total_credit_used_quota,                                               -- 总授信已用额度

    -- 用信率
    CASE
        WHEN total_credit_quota > 0
        THEN ROUND((total_credit_used_quota / total_credit_quota) * 100, 2)
        ELSE 0
    END AS credit_utilization_rate,                                        -- 用信率（%）

    -- 贷款余额
    total_loan_balance,                                                    -- 总贷款余额
    outstanding_promissory_note_cnt,                                       -- 在贷笔数

    -- 是否贷款客户
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户

    -- T-1日交易（重命名为 last_* 表示最新）
    daily_loan_amt AS last_daily_loan_amt,                                -- 最新日放款金额
    daily_loan_cnt AS last_daily_loan_cnt,                                -- 最新日放款笔数
    daily_repay_amt AS last_daily_repay_amt,                              -- 最新日还款金额
    daily_repay_interest_amt AS last_daily_repay_interest_amt,            -- 最新日还款利息
    daily_repay_cnt AS last_daily_repay_cnt,                              -- 最新日还款笔数

    -- 累计指标
    cumulative_loan_amt,                                                   -- 累计放款金额
    cumulative_repay_amt,                                                  -- 累计还款金额
    year_cumulative_loan_amt,                                              -- 年累计放款金额
    year_cumulative_repay_amt,                                             -- 年累计还款金额

    -- 状态标识
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS has_active_loan,  -- 是否有效贷款
    (SELECT MAX(trx_date) FROM {{ ref('dwd_fund_online_loan_fact_i') }}
     WHERE customer_id = all_customer_state.customer_id
       AND loan_repay_type IN ('1', '2')
       AND trx_date <= (SELECT stats_date FROM target_date)) AS last_transaction_date,  -- 最后交易日期

    -- 数据仓库字段
    (SELECT stats_date FROM target_date) AS stats_date,                    -- 统计日期（T-1）
    CURRENT_TIMESTAMP AS dw_update_time                                    -- 数据仓库更新时间

FROM all_customer_state
WHERE total_credit_quota > 0 OR total_loan_balance > 0 OR cumulative_loan_amt > 0  -- 只保留有活动的客户
ORDER BY total_loan_balance DESC
