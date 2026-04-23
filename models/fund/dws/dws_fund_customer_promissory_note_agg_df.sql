-- =============================================
-- 模型名称：dws_fund_customer_promissory_note_agg_df
-- 模型描述：借据日明细宽表，按借据+日期粒度记录每笔借据的完整状态
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + promissory_note_id + stats_date
-- 说明：
--   - 数据源：dwd_fund_promissory_note_fact_i（借据事实）+ dwd_fund_credit_fact_i（授信事实）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 取值逻辑：按 promissory_note_id + stats_date 取每天最新记录，关联授信获取客户和产品信息
--   - 核心指标：
--     * 授信额度/已用额度/剩余额度（来自授信表）
--     * 借据额度/余额/利率/起止日期（来自借据事实）
--     * 到期天数/逾期标识/到期预警
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='借据日明细宽表，按借据+日期粒度记录每笔借据的完整状态',
    tags=['fund', 'dws', 'agg', 'customer_promissory_note', 'daily']
) }}

WITH daily_promissory_note AS (
    SELECT
        pn.promissory_note_id,
        pn.promissory_note_no,
        pn.credit_quota AS note_credit_quota,
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
        pn.create_time,
        pn.update_time,
        CAST(pn.trx_date AS DATE) AS stats_date,
        ROW_NUMBER() OVER (PARTITION BY pn.promissory_note_id, CAST(pn.trx_date AS DATE) ORDER BY pn.update_time DESC) AS rn
    FROM {{ ref('dwd_fund_promissory_note_fact_i') }} pn
    WHERE pn.promissory_note_status = '1'
),

latest_note AS (
    SELECT * FROM daily_promissory_note WHERE rn = 1
),

credit_info AS (
    SELECT
        customer_id,
        customer_name,
        customer_type,
        customer_contract_no,
        credit_quota,
        remain_quota AS credit_remain_quota,
        (credit_quota - remain_quota) AS credit_used_quota,
        credit_start_date,
        credit_end_date,
        financial_product_id,
        financial_product_name,
        fund_org_id,
        fund_org_name,
        repay_type,
        ROW_NUMBER() OVER (PARTITION BY customer_contract_no ORDER BY update_time DESC) AS rn
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE credit_result = '1'
),

note_with_credit AS (
    SELECT
        ln.promissory_note_id,
        ln.stats_date,
        ln.promissory_note_no,
        ln.note_credit_quota,
        ln.loan_balance,
        ln.remain_quota,
        ln.interest_rate,
        ln.promissory_note_start_date,
        ln.promissory_note_end_date,
        ln.contract_code,
        ln.apply_quota,
        ln.promissory_note_sn,
        ln.entrust_account,
        ln.apply_free_time,
        ln.store_id,
        ln.store_name,
        ln.apply_status,
        ln.connection_type,
        ln.promissory_note_status,
        ln.remark,
        ln.creator,
        ln.create_time,
        ln.update_time,
        ci.customer_id,
        ci.customer_name,
        ci.customer_type,
        ci.credit_quota,
        ci.credit_remain_quota,
        ci.credit_used_quota,
        ci.credit_start_date,
        ci.credit_end_date,
        ci.financial_product_id,
        ci.financial_product_name,
        ci.fund_org_id,
        ci.fund_org_name,
        ci.repay_type
    FROM latest_note ln
    LEFT JOIN credit_info ci
        ON ci.customer_contract_no = ln.contract_code
        AND ci.rn = 1
)

SELECT
    promissory_note_id,                                                      -- 借据ID
    stats_date,                                                              -- 统计日期
    customer_id,                                                             -- 客户ID
    customer_name,                                                           -- 客户名称
    customer_type,                                                           -- 客户类型
    promissory_note_no,                                                      -- 借据编号
    contract_code,                                                           -- 合同编号

    credit_quota,                                                            -- 授信总额度
    credit_remain_quota,                                                     -- 授信剩余额度
    credit_used_quota,                                                       -- 授信已用额度
    credit_start_date,                                                       -- 授信起期
    credit_end_date,                                                         -- 授信止期

    note_credit_quota,                                                       -- 借据额度
    loan_balance,                                                            -- 借据余额
    remain_quota,                                                            -- 借据剩余额度
    apply_quota,                                                             -- 申请额度
    interest_rate,                                                           -- 利率

    promissory_note_start_date,                                              -- 借据起期
    promissory_note_end_date,                                                -- 借据止期

    DATEDIFF('day', stats_date, promissory_note_end_date) AS days_to_maturity,  -- 距到期天数
    CASE WHEN promissory_note_end_date < stats_date THEN '1' ELSE '0' END AS is_overdue,  -- 是否逾期
    CASE WHEN promissory_note_end_date >= stats_date AND promissory_note_end_date <= stats_date + INTERVAL '7 days' THEN '1' ELSE '0' END AS is_due_within_7d,    -- 是否7天内到期
    CASE WHEN promissory_note_end_date >= stats_date AND promissory_note_end_date <= stats_date + INTERVAL '30 days' THEN '1' ELSE '0' END AS is_due_within_30d,  -- 是否30天内到期
    CASE WHEN promissory_note_end_date >= stats_date THEN '1' ELSE '0' END AS is_valid_promissory_note,  -- 是否有效借据
    CASE WHEN loan_balance > 0 THEN '1' ELSE '0' END AS has_balance,        -- 是否有余额
    CASE WHEN loan_balance > 0 THEN '1' ELSE '0' END AS is_on_loan,         -- 是否在贷

    CASE WHEN note_credit_quota > 0 THEN ROUND((loan_balance / note_credit_quota) * 100, 2) ELSE 0 END AS utilization_rate,  -- 用信率（%）
    CASE WHEN promissory_note_end_date >= stats_date AND promissory_note_end_date < stats_date + INTERVAL '30 days' THEN loan_balance ELSE 0 END AS due_30d_balance,  -- 30天内到期余额
    CASE WHEN promissory_note_end_date < stats_date THEN loan_balance ELSE 0 END AS overdue_balance,  -- 逾期余额


    financial_product_id,                                                    -- 金融产品ID
    financial_product_name,                                                  -- 金融产品名称
    fund_org_id,                                                             -- 资金方ID
    fund_org_name,                                                           -- 资金方名称
    repay_type,                                                              -- 还款方式

    promissory_note_sn,                                                      -- 借据流水号
    entrust_account,                                                         -- 委托账户
    apply_free_time,                                                         -- 申请放款时间
    store_id,                                                                -- 门店ID
    store_name,                                                              -- 门店名称
    apply_status,                                                            -- 申请状态
    connection_type,                                                         -- 对接类型
    promissory_note_status,                                                  -- 借据状态

    create_time,                                                             -- 创建时间
    update_time,                                                             -- 更新时间
    CURRENT_TIMESTAMP AS dw_update_time                                      -- 数据仓库更新时间

FROM note_with_credit
WHERE customer_id IS NOT NULL
ORDER BY stats_date DESC, customer_id, loan_balance DESC
