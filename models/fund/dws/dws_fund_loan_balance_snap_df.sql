-- =============================================
-- 模型名称：dws_fund_loan_balance_snap_df
-- 模型描述：借据余额每日快照表，记录每笔借据在每天的历史余额状态
-- Dbt更新方式：全量（保留历史）
-- 粒度：promissory_note_no + stats_date
-- 说明：
--   - 数据源：dwd_fund_promissory_note_fact_i（借据事实表）
--   - 更新策略：按日期追加，保留完整历史数据
--   - 业务时间：取每天截止时刻的借据余额状态
--   - 取值逻辑：按 promissory_note_no + stats_date 分组，取当天最后一条记录
--   - 关联授信表获取客户信息（通过 contract_code）
--   - 用于历史趋势分析、余额变化追踪、到期预警分析
--   - 架构设计：与生产环境保持一致
--   - 命名说明：_snap_df 表示历史快照，保留历史数据
-- =============================================
{{ config(
    materialized='table',
    description='借据余额每日快照表，记录每笔借据在每天的历史余额状态',
    tags=['fund', 'dws', 'snap', 'promissory_note', 'loan_balance']
) }}

WITH latest_promissory_note_daily AS (
    -- ============================================
    -- 按借据号和日期取最新记录
    -- ============================================
    SELECT
        promissory_note_id,
        promissory_note_no,
        credit_quota,
        loan_balance,
        remain_quota,
        interest_rate,
        promissory_note_start_date,
        promissory_note_end_date,
        contract_code,
        apply_quota,
        promissory_note_sn,
        entrust_account,
        apply_free_time,
        store_id,
        store_name,
        apply_status,
        connection_type,
        promissory_note_status,
        remark,
        creator,
        CAST(trx_date AS DATE) AS stats_date,
        trx_date,
        update_time,
        ROW_NUMBER() OVER (PARTITION BY promissory_note_no, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
    FROM {{ ref('dwd_fund_promissory_note_fact_i') }}
    WHERE promissory_note_status = '0'  -- 仅有效借据
),

promissory_note_with_credit AS (
    -- ============================================
    -- 关联授信表获取客户信息
    -- ============================================
    SELECT
        pn.promissory_note_id,
        pn.promissory_note_no,
        pn.credit_quota,
        pn.loan_balance,
        pn.remain_quota,
        pn.interest_rate,
        pn.promissory_note_start_date,
        pn.promissory_note_end_date,
        pn.contract_code,
        pn.apply_quota,
        pn.promissory_note_sn,
        pn.entrust_account,
        pn.apply_free_time,
        pn.store_id,
        pn.store_name,
        pn.apply_status,
        pn.connection_type,
        pn.promissory_note_status,
        pn.remark,
        pn.creator,
        pn.stats_date,
        pn.trx_date,
        pn.update_time,
        -- 从授信表获取客户信息（匹配统计日期）
        c.customer_id,
        c.customer_name,
        c.financial_product_id,
        c.financial_product_name,
        c.fund_org_id,
        c.fund_org_name
    FROM latest_promissory_note_daily pn
    LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
        ON c.customer_contract_no = pn.contract_code
        AND c.credit_result = '1'  -- 有效授信
        AND CAST(c.trx_date AS DATE) <= pn.stats_date  -- 取统计日期前的最新授信信息
    WHERE pn.rn = 1  -- 取每天每笔借据的最新记录
),

-- ============================================
-- 为每笔借据获取对应统计日期的客户信息
-- =============================================
ranked_customer_info AS (
    SELECT
        promissory_note_id,
        promissory_note_no,
        credit_quota,
        loan_balance,
        remain_quota,
        interest_rate,
        promissory_note_start_date,
        promissory_note_end_date,
        contract_code,
        apply_quota,
        promissory_note_sn,
        entrust_account,
        apply_free_time,
        store_id,
        store_name,
        apply_status,
        connection_type,
        promissory_note_status,
        remark,
        creator,
        stats_date,
        trx_date,
        update_time,
        customer_id,
        customer_name,
        financial_product_id,
        financial_product_name,
        fund_org_id,
        fund_org_name,
        ROW_NUMBER() OVER (PARTITION BY promissory_note_no, stats_date ORDER BY update_time DESC) AS customer_rn
    FROM promissory_note_with_credit
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    promissory_note_id,                                                     -- 借据ID
    promissory_note_no,                                                     -- 借据编号
    stats_date,                                                             -- 统计日期

    -- 客户信息（从授信表关联）
    customer_id,                                                            -- 客户ID
    customer_name,                                                          -- 客户名称

    -- 金额信息
    credit_quota,                                                           -- 授信额度
    loan_balance,                                                           -- 贷款余额
    remain_quota,                                                           -- 剩余额度
    apply_quota,                                                            -- 申请额度

    -- 利率信息
    interest_rate,                                                          -- 利率

    -- 日期信息
    promissory_note_start_date,                                            -- 借据起期
    promissory_note_end_date,                                              -- 借据止期
    apply_free_time,                                                        -- 申请放款时间

    -- 产品信息（从授信表关联）
    financial_product_id,                                                   -- 金融产品ID
    financial_product_name,                                                 -- 金融产品名称

    -- 资金方信息（从授信表关联）
    fund_org_id,                                                            -- 资金方ID
    fund_org_name,                                                          -- 资金方名称

    -- 合同信息
    contract_code,                                                          -- 合同编号
    promissory_note_sn,                                                     -- 借据流水号
    entrust_account,                                                        -- 委托账户

    -- 门店信息
    store_id,                                                               -- 门店ID
    store_name,                                                             -- 门店名称

    -- 状态信息
    apply_status,                                                           -- 申请状态
    connection_type,                                                        -- 对接类型
    promissory_note_status,                                                 -- 借据状态
    remark,                                                                 -- 备注
    creator,                                                                -- 创建人

    -- 计算字段
    DATEDIFF('day', stats_date, CAST(promissory_note_end_date AS DATE)) AS days_to_maturity,  -- 距到期天数

    CASE WHEN CAST(promissory_note_end_date AS DATE) < stats_date THEN '1' ELSE '0' END AS is_overdue,  -- 是否逾期

    CASE WHEN CAST(promissory_note_end_date AS DATE) >= stats_date
         AND CAST(promissory_note_end_date AS DATE) <= stats_date + INTERVAL '7 days' THEN '1' ELSE '0' END AS is_due_within_7d,  -- 是否7天内到期

    CASE WHEN CAST(promissory_note_end_date AS DATE) >= stats_date
         AND CAST(promissory_note_end_date AS DATE) <= stats_date + INTERVAL '30 days' THEN '1' ELSE '0' END AS is_due_within_30d,  -- 是否30天内到期

    CASE WHEN loan_balance > 0 THEN '1' ELSE '0' END AS has_balance,        -- 是否有余额

    -- 数据仓库字段
    trx_date,                                                               -- 更新日期
    update_time,                                                            -- 更新时间
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM ranked_customer_info
WHERE customer_rn = 1  -- 取每天每笔借据对应的最新客户信息
  AND customer_id IS NOT NULL  -- 排除无法关联到客户的借据
ORDER BY promissory_note_no, stats_date DESC
