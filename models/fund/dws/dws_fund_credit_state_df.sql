-- =============================================
-- 模型名称：dws_fund_credit_state_df
-- 模型描述：授信额度当前状态表，记录每个授信的最新状态（T-1日）
-- Dbt更新方式：全量
-- 粒度：credit_id
-- 说明：
--   - 数据源：dws_fund_credit_snap_df（授信快照表）
--   - 更新策略：每日全量覆盖，从快照表获取T-1日数据，不保留历史
--   - 业务时间：取 T-1 日的授信快照
--   - 用于下游分析授信额度使用情况
--   - 架构设计：复用 snap 表，避免重复计算
--   - 命名说明：_state_df 表示当前状态快照，日全量覆盖，不保留历史
-- =============================================
{{ config(
    materialized='table',
    description='授信额度当前状态表，记录每个授信的最新状态（T-1日）',
    tags=['fund', 'dws', 'state', 'credit', 'loan_balance']
) }}

WITH target_date AS (
    -- ============================================
    -- 定义目标统计日期：T-1
    -- ============================================
    SELECT CURRENT_DATE - INTERVAL '1 day' AS stats_date
)

-- ============================================
-- 最终 SELECT
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
    utilization_rate,
    is_valid_credit,
    has_balance,
    (SELECT stats_date FROM target_date) AS stats_date,
    trx_date,
    update_time,
    CURRENT_TIMESTAMP AS dw_update_time
FROM {{ ref('dws_fund_credit_snap_df') }}
WHERE stats_date = (SELECT stats_date FROM target_date)
ORDER BY credit_used_quota DESC
