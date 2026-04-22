-- =============================================
-- 模型名称：dws_fund_customer_loan_snap_df
-- 模型描述：客户贷款历史快照表，记录每个客户在每日历史时点的授信、贷款余额等核心指标（从2020-01-01起）
-- Dbt更新方式：增量（按日期）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信）+ dwd_fund_promissory_note_fact_i（借据）
--   - 更新策略：按日期追加，保留完整历史数据
--   - 业务时间：取每日截止时刻的客户授信和贷款余额状态
--   - 复用 state 表的聚合逻辑，扩展到完整时间序列
--   - 只包含核心指标（授信、贷款余额），不包含交易明细
--   - 用于客户贷款历史趋势分析、资产变化追踪、风险监控
--   - 架构设计：三层架构的第二层（snap层），复用state计算逻辑
--   - 命名说明：_snap_df 表示历史快照，日全量刷新，保留历史数据
-- =============================================
{{ config(
    materialized='table',
    description='客户贷款历史快照表，记录每个客户在每日历史时点的授信、贷款余额等核心指标',
    tags=['fund', 'dws', 'snap', 'customer', 'loan']
) }}

WITH all_dates AS (
    -- ============================================
    -- 1. 生成所有需要统计的日期范围（从2020-01-01开始）
    -- ============================================
    SELECT
        DISTINCT CAST(trx_date AS DATE) AS stats_date
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE CAST(trx_date AS DATE) >= '2020-01-01'
    UNION
    SELECT DISTINCT CAST(trx_date AS DATE) AS stats_date
    FROM {{ ref('dwd_fund_promissory_note_fact_i') }}
    WHERE CAST(trx_date AS DATE) >= '2020-01-01'
),

credit_daily AS (
    -- ============================================
    -- 2. 按客户和日期汇总授信信息（复用state表逻辑）
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
    -- 3. 按客户和日期汇总借据余额（复用state表逻辑）
    -- ============================================
    WITH daily_promissory_note AS (
        -- 按借据号和日期取最新状态
        SELECT
            pn.promissory_note_no,
            CAST(pn.trx_date AS DATE) AS stats_date,
            pn.loan_balance,
            pn.contract_code,
            pn.update_time,
            ROW_NUMBER() OVER (PARTITION BY pn.promissory_note_no, CAST(pn.trx_date AS DATE) ORDER BY pn.update_time DESC) AS rn
        FROM {{ ref('dwd_fund_promissory_note_fact_i') }} pn
        WHERE pn.promissory_note_status = '0'  -- 有效借据
    ),
    promissory_note_with_customer AS (
        -- 通过 contract_code 关联授信表获取 customer_id
        SELECT
            c.customer_id,
            pn.promissory_note_no,
            pn.stats_date,
            pn.loan_balance
        FROM daily_promissory_note pn
        LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
            ON c.customer_contract_no = pn.contract_code
            AND c.credit_result = '1'  -- 有效授信
            AND CAST(c.trx_date AS DATE) <= pn.stats_date
        WHERE pn.rn = 1  -- 取每笔借据每天的最新记录
          AND pn.loan_balance > 0  -- 只保留有余额的借据
          AND c.customer_id IS NOT NULL  -- 排除无法关联到客户的借据
    )
    SELECT
        customer_id,
        stats_date,
        SUM(loan_balance) AS total_loan_balance,
        COUNT(DISTINCT promissory_note_no) AS outstanding_promissory_note_cnt
    FROM promissory_note_with_customer
    GROUP BY customer_id, stats_date
),

-- ============================================
-- 合并所有数据
-- ============================================
all_customer_daily AS (
    SELECT
        COALESCE(cd.customer_id, lb.customer_id) AS customer_id,
        COALESCE(cd.stats_date, lb.stats_date) AS stats_date,
        -- 授信额度
        COALESCE(cd.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cd.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(cd.total_credit_used_quota, 0) AS total_credit_used_quota,
        -- 贷款余额
        COALESCE(lb.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(lb.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt
    FROM credit_daily cd
    FULL OUTER JOIN loan_balance_daily lb ON cd.customer_id = lb.customer_id AND cd.stats_date = lb.stats_date
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

    -- 用信率
    CASE
        WHEN total_credit_quota > 0
        THEN ROUND((total_credit_used_quota / total_credit_quota) * 100, 2)
        ELSE 0
    END AS credit_utilization_rate,                                         -- 用信率（%）

    -- 贷款余额
    total_loan_balance,                                                     -- 总贷款余额
    outstanding_promissory_note_cnt,                                        -- 在贷笔数

    -- 是否贷款客户
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户

    -- 快照标识
    'auto' AS snapshot_type,                                                -- 快照类型（自动生成）

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM all_customer_daily
WHERE total_credit_quota > 0 OR total_loan_balance > 0  -- 只保留有活动的客户
ORDER BY customer_id, stats_date DESC
-- {% if is_incremental() %}
-- AND stats_date > (SELECT COALESCE(MAX(stats_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}
