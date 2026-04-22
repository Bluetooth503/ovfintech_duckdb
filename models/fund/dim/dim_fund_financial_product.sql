-- =============================================
-- 模型名称：dim_fund_financial_product
-- 模型描述：金融产品维度表，维护资金域金融产品的基础信息
-- 粒度：product_id
-- 说明：
--   - 数据源：ods_product_financial（金融产品基础信息表）
--   - 主键：product_id
--   - 统计指标：产品名称、额度范围、期限范围、还款方式、贷款类型等
--   - 业务规则：去重取最新记录（按id去重）
-- =============================================
{{ config(
    materialized='table',
    description='金融产品维度表，维护资金域金融产品的基础信息',
    tags=['fund', 'dim', 'product', 'financial']
) }}

WITH product_financial_latest AS (
    -- 去重逻辑：按id取最新记录（ROW_NUMBER去重）
    SELECT
        id,
        financial_name,
        product_id,
        quota_start,
        quota_end,
        fund_use,
        biz_code,
        min_period,
        max_period,
        min_single_loan,
        max_single_loan,
        to_customer,
        repay_type,
        quota,
        limit_date,
        loan_type,
        grace_period,
        lmt_no,
        bank_product_id,
        ROW_NUMBER() OVER (PARTITION BY id ORDER BY id) as rn
    FROM {{ ref('ods_product_financial') }}
)

SELECT
    id AS financial_product_id,                                                        -- 金融产品ID
    product_id,                                                                        -- 产品ID
    financial_name,                                                                    -- 产品名称
    CAST(quota_start AS DOUBLE) AS quota_start_amt,                                    -- 额度下限（元）
    CAST(quota_end AS DOUBLE) AS quota_end_amt,                                        -- 额度上限（元）
    CAST(quota AS DOUBLE) AS total_quota_amt,                                          -- 总授信额度（元）
    fund_use,                                                                          -- 资金用途
    biz_code,                                                                          -- 业务编码
    CAST(min_period AS INTEGER) AS min_period_days,                                    -- 最短期限（天）
    CAST(max_period AS INTEGER) AS max_period_days,                                    -- 最长期限（天）
    CAST(min_single_loan AS DOUBLE) AS min_single_loan_amt,                            -- 单笔最小金额（元）
    CAST(max_single_loan AS DOUBLE) AS max_single_loan_amt,                            -- 单笔最大金额（元）
    to_customer,                                                                       -- 客户类型（1=对公，2=对私，3=对公对私）
    repay_type,                                                                        -- 还款方式（1=等额本息，2=等额本金，3=先息后本，4=一次性还本付息）
    loan_type,                                                                         -- 贷款类型
    CAST(grace_period AS INTEGER) AS grace_period_days,                                -- 宽限期（天）
    limit_date::DATE AS quota_limit_date,                                              -- 额度到期日
    lmt_no,                                                                            -- 授信编号
    bank_product_id,                                                                   -- 银行产品ID
    '1' AS is_current                                                                  -- 是否当前有效记录（固定为1）
FROM product_financial_latest
WHERE rn = 1                                                                          -- 去重取最新记录

-- 分布式表通常不需要排序，如需排序可取消以下注释
-- ORDER BY
--     product_id
