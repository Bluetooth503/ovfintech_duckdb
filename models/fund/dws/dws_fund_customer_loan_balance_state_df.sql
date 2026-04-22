-- =============================================
-- @DEPRECATED: 此模型已废弃，请使用以下新模型
--   - dws_fund_customer_loan_state_df.sql（当前状态）
--   - dws_fund_customer_loan_snap_df.sql（历史快照）
--   - dws_fund_customer_loan_agg_df.sql（聚合汇总）
-- 废弃日期: 2025-04-22
-- 计划删除: 2025-05-22（30天后）
-- =============================================
-- =============================================
-- 模型名称：dws_fund_customer_loan_balance_state_df
-- 模型描述：客户贷款余额当前状态表，记录每个客户的授信额度和贷款余额的最新状态（T-1日）
-- Dbt更新方式：全量
-- 粒度：customer_id
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信事实表）+ dwd_fund_promissory_note_fact_i（借据事实表）
--   - 更新策略：每日全量覆盖，计算 T-1 日截止时刻的贷款余额，不保留历史数据
--   - 业务时间过滤：只统计 trx_date <= T-1 的交易数据
--   - 计算逻辑：
--     * 授信额度：从授信事实表获取（credit_quota, remain_quota）
--     * 贷款余额：从借据事实表获取（loan_balance）
--       - 贷款余额 = SUM(借据事实表的 promissory_note_balance)
--       - 按借据号取最新状态（ROW_NUMBER() OVER ... ORDER BY trx_time DESC）
--       - 通过 contract_code 关联授信表获取 customer_id
--       - 不包含授信表的 loan_balance，避免与借据重复
--   - 用于客户维度表关联，判断是否贷款客户
--   - 架构设计：与生产环境保持一致
--   - 命名说明：_state_df 表示当前状态快照，日全量覆盖，不保留历史
-- =============================================
{{
    config(
        materialized='table',
        enabled=False,
        description='@DEPRECATED - 已废弃，请使用 dws_fund_customer_loan_state_df',
        tags=['fund', 'dws', 'state', 'customer', 'loan_balance']
    )
}}

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
    SELECT
        customer_id,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE credit_result = '1'  -- 有效授信
      AND trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
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
        SUM(loan_balance) AS total_loan_balance
    FROM promissory_note_with_customer
    WHERE customer_id IS NOT NULL  -- 排除无法关联到客户的借据
    GROUP BY customer_id
),

-- ============================================
-- 合并授信额度和贷款余额
-- ============================================
all_customer_loan_balance AS (
    SELECT
        COALESCE(cq.customer_id, lb.customer_id) AS customer_id,
        -- 授信额度
        COALESCE(cq.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cq.total_remain_quota, 0) AS total_remain_quota,
        -- 贷款余额（从借据事实表获取）
        COALESCE(lb.total_loan_balance, 0) AS total_loan_balance
    FROM credit_quota cq
    FULL OUTER JOIN loan_balance lb ON cq.customer_id = lb.customer_id
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

    -- 贷款余额（用于判断是否贷款客户）
    total_loan_balance,                                                    -- 总贷款余额

    -- 是否贷款客户标识
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户

    -- 数据仓库字段
    (SELECT stats_date FROM target_date) AS stats_date,                    -- 统计日期（T-1）
    CURRENT_TIMESTAMP AS dw_update_time                                    -- 数据仓库更新时间

FROM all_customer_loan_balance
WHERE total_loan_balance > 0  -- 只保留有贷款余额的客户
ORDER BY total_loan_balance DESC
