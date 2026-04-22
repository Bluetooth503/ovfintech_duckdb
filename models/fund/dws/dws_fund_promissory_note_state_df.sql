-- =============================================
-- 模型名称：dws_fund_promissory_note_state_df
-- 模型描述：借据当前状态表，记录每笔借据的最新状态（T-1日）
-- Dbt更新方式：全量
-- 粒度：promissory_note_no
-- 说明：
--   - 数据源：dwd_fund_promissory_note_fact_i（借据事实表）
--   - 更新策略：每日全量覆盖，取每笔借据的最新记录，不保留历史数据
--   - 业务时间过滤：只统计 trx_date <= T-1 的数据
--   - 取最新状态：按 promissory_note_no 分组，取 update_time 最大的记录
--   - 关联授信表获取客户信息（通过 contract_code）
--   - 用于下游分析借据余额、到期情况等
--   - 架构设计：与生产环境保持一致
--   - 命名说明：_state_df 表示当前状态快照，日全量覆盖，不保留历史
-- =============================================
{{ config(
    materialized='table',
    description='借据当前状态表，记录每笔借据的最新状态（T-1日）',
    tags=['fund', 'dws', 'state', 'promissory_note', 'loan_balance']
) }}

WITH target_date AS (
    -- ============================================
    -- 定义目标统计日期：T-1
    -- ============================================
    SELECT CURRENT_DATE - INTERVAL '1 day' AS stats_date
),

latest_promissory_note AS (
    -- ============================================
    -- 按借据号取最新状态（T-1日截止）
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
        trx_date,
        update_time,
        ROW_NUMBER() OVER (PARTITION BY promissory_note_no ORDER BY update_time DESC) AS rn
    FROM {{ ref('dwd_fund_promissory_note_fact_i') }}
    WHERE trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
      AND promissory_note_status = '0'  -- 仅有效借据
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
        pn.trx_date,
        pn.update_time,
        -- 从授信表获取客户信息
        c.customer_id,
        c.customer_name,
        c.financial_product_id,
        c.financial_product_name,
        c.fund_org_id,
        c.fund_org_name
    FROM latest_promissory_note pn
    LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
        ON c.customer_contract_no = pn.contract_code
        AND c.credit_result = '1'  -- 有效授信
        AND c.trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
    WHERE pn.rn = 1  -- 取每笔借据的最新记录
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    promissory_note_id,                                                     -- 借据ID
    promissory_note_no,                                                     -- 借据编号

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
    DATEDIFF('day', (SELECT stats_date FROM target_date), promissory_note_end_date) AS days_to_maturity,  -- 距到期天数

    CASE WHEN promissory_note_end_date < (SELECT stats_date FROM target_date) THEN '1' ELSE '0' END AS is_overdue,  -- 是否逾期

    CASE WHEN promissory_note_end_date >= (SELECT stats_date FROM target_date)
         AND promissory_note_end_date <= (SELECT stats_date FROM target_date) + INTERVAL '7 days' THEN '1' ELSE '0' END AS is_due_within_7d,  -- 是否7天内到期

    CASE WHEN promissory_note_end_date >= (SELECT stats_date FROM target_date)
         AND promissory_note_end_date <= (SELECT stats_date FROM target_date) + INTERVAL '30 days' THEN '1' ELSE '0' END AS is_due_within_30d,  -- 是否30天内到期

    CASE WHEN loan_balance > 0 THEN '1' ELSE '0' END AS has_balance,        -- 是否有余额

    -- 数据仓库字段
    (SELECT stats_date FROM target_date) AS stats_date,                     -- 统计日期（T-1）
    trx_date,                                                               -- 最新更新日期
    update_time,                                                            -- 最新更新时间
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM promissory_note_with_credit
WHERE customer_id IS NOT NULL  -- 排除无法关联到客户的借据
ORDER BY loan_balance DESC
