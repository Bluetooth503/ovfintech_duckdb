-- =============================================
-- 模型名称：dws_fund_credit_snap_df
-- 模型描述：授信额度每日快照表，记录每个授信在每天的历史状态
-- Dbt更新方式：全量（保留历史）
-- 粒度：credit_id + stats_date
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信事实表）
--   - 更新策略：按日期追加，保留完整历史数据
--   - 业务时间：取每天截止时刻的授信状态
--   - 取值逻辑：按 credit_id + stats_date 分组，取当天最后一条记录
--   - 用于历史趋势分析、环比计算、还原任意时点状态
--   - 架构设计：作为基础快照表，被 state 和 agg 表引用
--   - 命名说明：_snap_df 表示历史快照，保留历史数据
-- =============================================
{{ config(
    materialized='table',
    description='授信额度每日快照表，记录每个授信在每天的历史状态',
    tags=['fund', 'dws', 'snap', 'credit', 'loan_balance']
) }}

WITH ranked_credits AS (
    -- ============================================
    -- 获取每天每个授信的最新记录
    -- ============================================
    SELECT
        credit_id,
        customer_id,
        customer_name,
        customer_type,
        credit_apply_sn,
        customer_contract_no,
        credit_quota,
        remain_quota,
        credit_used_quota,
        base_rate,
        rate_float,
        credit_start_date,
        credit_end_date,
        financial_product_id,
        financial_product_name,
        fund_org_id,
        fund_org_name,
        loop_flag,
        repay_type,
        remaining_exposure,
        margin_ratio,
        reply_no,
        credit_result,
        credit_status,
        remark,
        push_type,
        trx_date,
        update_time,
        ROW_NUMBER() OVER (PARTITION BY credit_id, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE credit_result = '1'  -- 仅有效授信
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    credit_id,
    CAST(trx_date AS DATE) AS stats_date,
    customer_id,
    customer_name,
    customer_type,
    credit_apply_sn,
    customer_contract_no,
    credit_quota,
    remain_quota,
    credit_used_quota,
    base_rate,
    rate_float,
    credit_start_date,
    credit_end_date,
    financial_product_id,
    financial_product_name,
    fund_org_id,
    fund_org_name,
    loop_flag,
    repay_type,
    remaining_exposure,
    margin_ratio,
    reply_no,
    credit_result,
    credit_status,
    remark,
    push_type,
    CASE WHEN credit_quota > 0 THEN ROUND((credit_used_quota / credit_quota) * 100, 2) ELSE 0 END AS utilization_rate,
    CASE WHEN credit_result = '1' AND TRY_STRPTIME(credit_end_date, '%Y%m%d') >= CAST(trx_date AS DATE) THEN '1' ELSE '0' END AS is_valid_credit,
    CASE WHEN credit_used_quota > 0 THEN '1' ELSE '0' END AS has_balance,
    trx_date,
    update_time,
    CURRENT_TIMESTAMP AS dw_update_time
FROM ranked_credits
WHERE rn = 1
ORDER BY credit_id, trx_date DESC
