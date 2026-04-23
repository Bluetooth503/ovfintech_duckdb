-- =============================================
-- 模型名称：dws_fund_customer_credit_agg_df
-- 模型描述：客户授信明细日统计表，按客户、授信、日期维度统计每笔授信的详细信息
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + credit_id + stats_date
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信事实表）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 统计维度：按客户、授信和统计日期统计授信指标
--   - 核心指标：授信额度、剩余额度、已用额度、到期天数、用信率等
--   - 到期预警：标识7天/30天/90天内到期的授信
--   - 银承标识：标识银承产品（financial_product_id = 73）
--   - 钢贸银承标识：标识钢贸银承产品（financial_product_id = 69）
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户授信明细日统计表，按客户、授信、日期维度统计每笔授信的详细信息',
    tags=['fund', 'dws', 'agg', 'customer_credit', 'daily']
) }}

WITH daily_credit_latest AS (
    -- ============================================
    -- 获取每天每个授信的最新记录
    -- ============================================
    SELECT
        credit_id,
        customer_id,
        customer_name,
        customer_type,
        CAST(trx_date AS DATE) AS stats_date,
        credit_quota,
        remain_quota,
        credit_used_quota,
        credit_result,
        financial_product_id,
        fund_org_id,
        credit_start_date,
        credit_end_date,
        ROW_NUMBER() OVER (PARTITION BY credit_id, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
    FROM {{ ref('dwd_fund_credit_fact_i') }}
)

-- ============================================
-- 最终 SELECT：授信明细日统计（客户ID + 授信ID + 日期粒度）
-- =============================================
SELECT
    -- 维度字段
    stats_date,                                                             -- 统计日期
    customer_id,                                                            -- 客户ID
    customer_name,                                                          -- 客户名称
    customer_type,                                                          -- 客户类型
    credit_id,                                                              -- 授信ID

    -- 授信额度指标
    credit_quota,                                                           -- 授信额度
    remain_quota,                                                           -- 剩余额度
    credit_used_quota,                                                      -- 授信已用额度

    -- 期限信息
    credit_start_date,                                                      -- 授信起期
    credit_end_date,                                                        -- 授信止期

    -- 到期相关指标
    DATEDIFF('day', stats_date, TRY_STRPTIME(credit_end_date, '%Y%m%d')) AS days_to_maturity,  -- 到期剩余天数
    CASE
        WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') < stats_date THEN '1'  -- 已逾期
        WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') <= DATE_ADD(stats_date, INTERVAL 7 DAY) THEN '1'  -- 7天内到期
        ELSE '0'
    END AS is_due_within_7d,                                               -- 7天内到期标识
    CASE
        WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') < stats_date THEN '1'  -- 已逾期
        WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') <= DATE_ADD(stats_date, INTERVAL 30 DAY) THEN '1'  -- 30天内到期
        ELSE '0'
    END AS is_due_within_30d,                                              -- 30天内到期标识
    CASE
        WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') < stats_date THEN '1'  -- 已逾期
        WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') <= DATE_ADD(stats_date, INTERVAL 90 DAY) THEN '1'  -- 90天内到期
        ELSE '0'
    END AS is_due_within_90d,                                              -- 90天内到期标识
    CASE
        WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') < stats_date THEN '1'  -- 已逾期
        ELSE '0'
    END AS is_overdue,                                                      -- 已逾期标识

    -- 用信率指标
    CASE WHEN credit_quota > 0 THEN ROUND((credit_used_quota / credit_quota) * 100, 2) ELSE 0 END AS utilization_rate,  -- 用信率（%）

    -- 授信状态标识
    CASE WHEN credit_result = '1' THEN '1' ELSE '0' END AS is_valid_credit,   -- 有效授信标识
    CASE WHEN credit_used_quota > 0 THEN '1' ELSE '0' END AS has_balance,     -- 有余额标识
    CASE WHEN TRY_STRPTIME(credit_end_date, '%Y%m%d') >= stats_date THEN '1' ELSE '0' END AS is_not_expired,  -- 未过期标识

    -- 银承产品标识
    CASE WHEN financial_product_id = 73 THEN '1' ELSE '0' END AS is_bank_acceptance,         -- 银承产品标识（financial_product_id = 73）
    CASE WHEN financial_product_id = 69 THEN '1' ELSE '0' END AS is_steel_trade_acceptance,  -- 钢贸银承产品标识（financial_product_id = 69）

    -- 授信结果
    credit_result,                                                          -- 授信结果

    -- 产品和资金方信息（保留ID，维度信息在ADS层添加）
    financial_product_id,                                                   -- 金融产品ID
    fund_org_id,                                                            -- 资金方ID

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM daily_credit_latest
WHERE rn = 1
ORDER BY stats_date DESC, customer_id, credit_id
