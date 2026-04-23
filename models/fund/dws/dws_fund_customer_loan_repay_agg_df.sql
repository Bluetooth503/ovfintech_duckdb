-- =============================================
-- 模型名称：dws_fund_customer_loan_repay_agg_df
-- 模型描述：客户借据放还款日统计表，按客户+借据+统计日期粒度汇总线上/线下贷款与还款核心指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + promissory_note_no + stats_date
-- 说明：
--   - 数据源：dwd_fund_online_loan_fact_i（线上交易）+ dwd_fund_offline_loan_fact_i（线下交易）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 核心指标：线上/线下贷款金额/笔数、还款金额/笔数/利息、净增额
--   - 从 DWD 直接聚合，单一事实来源
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户借据放还款日统计表，按客户+借据+日期粒度汇总线上/线下贷款与还款指标',
    tags=['fund', 'dws', 'agg', 'loan_repay', 'daily']
) }}

WITH online_agg AS (
    -- ============================================
    -- 线上交易按客户+借据+日期聚合
    -- ============================================
    SELECT
        customer_id,
        MAX(customer_name) AS customer_name,
        MAX(customer_type) AS customer_type,
        promissory_note_no,
        CAST(trx_date AS DATE) AS stats_date,
        -- 线上贷款
        SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS online_loan_amt,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS online_loan_cnt,
        -- 线上还款
        SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS online_repay_amt,
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS online_repay_cnt,
        SUM(CASE WHEN loan_repay_type = '2' THEN repay_interest_amount ELSE 0 END) AS online_repay_interest_amt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type IN ('1', '2')
    GROUP BY customer_id, promissory_note_no, CAST(trx_date AS DATE)
),

offline_agg AS (
    -- ============================================
    -- 线下交易按客户+借据+日期聚合
    -- ============================================
    SELECT
        customer_id,
        MAX(customer_name) AS customer_name,
        MAX(customer_type) AS customer_type,
        promissory_note_no,
        CAST(trx_date AS DATE) AS stats_date,
        -- 线下贷款
        SUM(CASE WHEN loan_repay_type = '1' THEN loan_amount ELSE 0 END) AS offline_loan_amt,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS offline_loan_cnt,
        -- 线下还款
        SUM(CASE WHEN loan_repay_type = '2' THEN difference_value ELSE 0 END) AS offline_repay_amt,
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS offline_repay_cnt
    FROM {{ ref('dwd_fund_offline_loan_fact_i') }}
    WHERE loan_repay_type IN ('1', '2')
    GROUP BY customer_id, promissory_note_no, CAST(trx_date AS DATE)
),

-- ============================================
-- 合并线上与线下数据
-- =============================================
merged AS (
    SELECT
        COALESCE(oa.customer_id, ofa.customer_id) AS customer_id,
        COALESCE(oa.customer_name, ofa.customer_name) AS customer_name,
        COALESCE(oa.customer_type, ofa.customer_type) AS customer_type,
        COALESCE(oa.promissory_note_no, ofa.promissory_note_no) AS promissory_note_no,
        COALESCE(oa.stats_date, ofa.stats_date) AS stats_date,
        -- 线上指标
        COALESCE(oa.online_loan_amt, 0) AS online_loan_amt,
        COALESCE(oa.online_loan_cnt, 0) AS online_loan_cnt,
        COALESCE(oa.online_repay_amt, 0) AS online_repay_amt,
        COALESCE(oa.online_repay_cnt, 0) AS online_repay_cnt,
        COALESCE(oa.online_repay_interest_amt, 0) AS online_repay_interest_amt,
        -- 线下指标
        COALESCE(ofa.offline_loan_amt, 0) AS offline_loan_amt,
        COALESCE(ofa.offline_loan_cnt, 0) AS offline_loan_cnt,
        COALESCE(ofa.offline_repay_amt, 0) AS offline_repay_amt,
        COALESCE(ofa.offline_repay_cnt, 0) AS offline_repay_cnt
    FROM online_agg oa
    FULL OUTER JOIN offline_agg ofa
        ON oa.customer_id = ofa.customer_id
        AND oa.promissory_note_no = ofa.promissory_note_no
        AND oa.stats_date = ofa.stats_date
)

-- ============================================
-- 最终 SELECT
-- =============================================
SELECT
    -- 维度字段
    stats_date,                                                            -- 统计日期
    customer_id,                                                           -- 客户ID
    customer_name,                                                         -- 客户名称
    customer_type,                                                         -- 客户类型
    promissory_note_no,                                                    -- 借据编号

    -- 线上贷款
    online_loan_amt,                                               -- 线上贷款金额
    online_loan_cnt,                                               -- 线上贷款笔数

    -- 线上还款
    online_repay_amt,                                                      -- 线上还款金额
    online_repay_cnt,                                                      -- 线上还款笔数
    online_repay_interest_amt,                                             -- 线上还款利息

    -- 线下贷款
    offline_loan_amt,                                              -- 线下贷款金额
    offline_loan_cnt,                                              -- 线下贷款笔数

    -- 线下还款
    offline_repay_amt,                                                     -- 线下还款金额
    offline_repay_cnt,                                                     -- 线下还款笔数

    -- 合计贷款
    (online_loan_amt + offline_loan_amt) AS total_loan_amt,  -- 总贷款金额
    (online_loan_cnt + offline_loan_cnt) AS total_loan_cnt,  -- 总贷款笔数

    -- 合计还款
    (online_repay_amt + offline_repay_amt) AS total_repay_amt,             -- 总还款金额
    (online_repay_cnt + offline_repay_cnt) AS total_repay_cnt,             -- 总还款笔数
    online_repay_interest_amt AS total_repay_interest_amt,                 -- 总还款利息（仅线上有利息明细）

    -- 净增额
    (online_loan_amt + offline_loan_amt - online_repay_amt - offline_repay_amt) AS net_loan_amt,  -- 净增额

    -- 标识字段
    CASE WHEN (online_loan_amt + offline_loan_amt) > 0 THEN '1' ELSE '0' END AS has_loan,  -- 是否有贷款
    CASE WHEN (online_repay_amt + offline_repay_amt) > 0 THEN '1' ELSE '0' END AS has_repay,                      -- 是否有还款

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                    -- 数据仓库更新时间

FROM merged
WHERE online_loan_amt > 0 OR online_repay_amt > 0 OR offline_loan_amt > 0 OR offline_repay_amt > 0  -- 只保留有交易记录的数据
ORDER BY stats_date DESC, customer_id, promissory_note_no
