-- =============================================
-- 模型名称：dwd_fund_online_loan_fact_i
-- 模型描述：在线放款还款交易明细表，记录所有在线借贷流水
-- Dbt更新方式：增量（事件级）
-- 粒度：trx_id
-- 说明：
--   - 数据源：ods_fund_billing（资金账单表）
--   - 增量策略：按 trx_date 分区，insert_overwrite
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    partition_by=['trx_date'],
    description='在线放款还款交易明细表，记录所有在线借贷流水',
    tags=['fund', 'dwd', 'trx', 'online_loan', 'loan']
) }}

SELECT
    -- 主键
    id AS trx_id,                                                   -- 交易ID（主键）
    serial_no AS trx_sn,                                            -- 交易流水号

    -- 时间信息
    bill_time AS trx_time,                                         -- 交易时间
    CAST(bill_time AS DATE) AS trx_date,                           -- 交易日期

    -- 交易类型
    bill_type AS loan_repay_type,                                  -- 借款还款类型（1-借款, 2-还款）

    -- 客户信息
    member_id AS customer_id,                                       -- 客户ID
    member_name AS customer_name,                                   -- 客户名称
    member_type AS customer_type,                                   -- 客户类型

    -- 金额信息
    bill_quota AS bill_amount,                                      -- 账单金额
    bill_interest AS repay_interest_amount,                         -- 还款利息
    loan_balance AS promissory_note_balance,                        -- 借据余额

    -- 单据信息
    loan_no AS promissory_note_no,                                  -- 借据编号
    financial_product_id,                                           -- 产品ID
    financial_product_name,                                         -- 产品名称

    -- 状态信息
    is_deleted,                                                     -- 是否删除

    -- 审计信息
    creator_id,                                                     -- 创建人ID
    create_time,                                                    -- 创建时间

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_insert_time,                            -- 数据仓库插入时间
    CURRENT_DATE AS dw_insert_date                                  -- 数据仓库插入日期

FROM {{ ref('ods_fund_billing') }}
WHERE is_deleted = '0'

-- {% if is_incremental() %}
-- AND CAST(bill_time AS DATE) >= (SELECT COALESCE(MAX(trx_date), DATE '2020-01-01') - INTERVAL '7 days' FROM {{ this }})
-- {% endif %}

ORDER BY trx_date, trx_time DESC
