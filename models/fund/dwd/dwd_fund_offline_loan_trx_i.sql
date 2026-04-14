-- =============================================
-- 模型名称：dwd_fund_offline_loan_trx_i
-- 模型描述：线下放款还款交易明细表 - 支持RFM分析的放款流水记录
-- 作者：dbt
-- 创建时间：2026-04-13
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='insert_overwrite',
    partition_by=['trx_date'],
    description='线下放款还款交易明细表，记录所有线下放款流水',
    tags=['fund', 'dwd', 'trx', 'offline_loan', 'loan']
) }}

SELECT
    -- 主键
    id AS trx_id,                                                   -- 交易ID（主键）
    CONCAT('LOAN', id) AS trx_sn,                                   -- 交易流水号

    -- 时间信息
    bill_time AS trx_time,                                          -- 交易时间
    CAST(bill_time AS DATE) AS trx_date,                            -- 交易日期
    statistics_date,                                                -- 统计日期

    -- 交易类型
    bill_type AS loan_repay_type,                                   -- 借款还款类型（1-放款, 2-还款）

    -- 客户信息
    member_id AS customer_id,                                       -- 客户ID
    member_name AS customer_name,                                   -- 客户名称
    member_type AS customer_type,                                   -- 客户类型
    counterparty_name,                                              -- 交易对手名称

    -- 订单信息
    order_no,                                                       -- 订单编号
    order_amount,                                                   -- 订单金额
    order_weight_num,                                               -- 订单重量
    order_transit_amount AS transit_amount,                         -- 订单在途金额

    -- 金额信息
    loan_amount,                                                    -- 贷款金额
    loan_balance AS promissory_note_balance,                        -- 借据余额
    loan_quota AS promissory_note_amount,                           -- 借据金额
    difference_value,                                               -- 差异值
    pledge_rate_line,                                               -- 质押率控制线

    -- 日期信息
    debt_start_date AS promissory_note_start_date,                  -- 借据起期
    debt_end_date AS promissory_note_end_date,                      -- 借据止期
    fixed_delivery_date,                                            -- 约定交货日期
    fixed_payment_date,                                             -- 约定回款日期

    -- 单据信息
    bill_no AS promissory_note_no,                                  -- 借据编号
    statistics_no,                                                  -- 统计编号

    -- 产品和类型
    financial_product_name AS product_name,                         -- 产品名称
    loan_type,                                                      -- 融资模式

    -- 状态信息
    is_view,                                                        -- 是否可被查看
    settle_status,                                                  -- 结算状态
    version_no,                                                     -- 版本号

    -- 审计信息
    create_time,                                                    -- 创建时间
    update_time,                                                    -- 更新时间

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_insert_time,                            -- 数据仓库插入时间
    CURRENT_DATE AS dw_insert_date                                  -- 数据仓库插入日期

FROM {{ ref('ods_offline_loan') }}

-- {% if is_incremental() %}
-- AND CAST(bill_time AS DATE) >= (SELECT COALESCE(MAX(trx_date), DATE '2020-01-01') - INTERVAL '7 days' FROM {{ this }})
-- {% endif %}

ORDER BY trx_date, trx_time DESC
