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
--   - 架构设计：与生产环境保持一致
--   - 命名说明：_snap_df 表示历史快照，保留历史数据
-- =============================================
{{ config(
    materialized='table',
    description='授信额度每日快照表，记录每个授信在每天的历史状态',
    tags=['fund', 'dws', 'snap', 'credit', 'loan_balance']
) }}

WITH all_dates AS (
    -- ============================================
    -- 生成所有需要统计的日期范围
    -- ============================================
    SELECT
        DISTINCT trx_date AS stats_date
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE trx_date >= '2020-01-01'  -- 可根据实际数据调整起始日期
),

credit_daily_records AS (
    -- ============================================
    -- 获取每天每个授信的最新记录
    -- ============================================
    WITH ranked_credits AS (
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
        update_time
    FROM ranked_credits
    WHERE rn = 1  -- 取每天每个授信的最新记录
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    credit_id,                                                              -- 授信ID
    CAST(trx_date AS DATE) AS stats_date,                                   -- 统计日期

    -- 客户信息
    customer_id,                                                            -- 客户ID
    customer_name,                                                          -- 客户名称
    customer_type,                                                          -- 客户类型
    credit_apply_sn,                                                        -- 业务编号
    customer_contract_no,                                                   -- 客户合同编号

    -- 授信额度信息
    credit_quota,                                                           -- 授信额度
    remain_quota,                                                           -- 剩余额度
    credit_used_quota,                                                      -- 授信已用额度

    -- 利率信息
    base_rate,                                                              -- 基础利率
    rate_float,                                                             -- 浮动利率

    -- 期限信息
    credit_start_date,                                                      -- 授信起期
    credit_end_date,                                                        -- 授信止期

    -- 产品信息
    financial_product_id,                                                   -- 金融产品ID
    financial_product_name,                                                 -- 金融产品名称

    -- 资金方信息
    fund_org_id,                                                            -- 资金方ID
    fund_org_name,                                                          -- 资金方名称

    -- 授信属性
    loop_flag,                                                              -- 循环标志
    repay_type,                                                             -- 还款方式
    remaining_exposure,                                                     -- 剩余敞口
    margin_ratio,                                                           -- 保证金比例
    reply_no,                                                               -- 批复号

    -- 状态信息
    credit_result,                                                          -- 授信结果
    credit_status,                                                          -- 授信状态
    remark,                                                                 -- 备注
    push_type,                                                              -- 推送类型

    -- 计算字段
    CASE WHEN credit_quota > 0 THEN ROUND((credit_used_quota / credit_quota) * 100, 2) ELSE 0 END AS utilization_rate,  -- 用信率（%）

    -- 是否有效授信
    CASE WHEN credit_result = '1' AND TRY_STRPTIME(credit_end_date, '%Y%m%d') >= CAST(trx_date AS DATE) THEN '1' ELSE '0' END AS is_valid_credit,  -- 是否有效授信

    -- 是否有余额
    CASE WHEN credit_used_quota > 0 THEN '1' ELSE '0' END AS has_balance,   -- 是否有余额

    -- 数据仓库字段
    trx_date,                                                               -- 更新日期
    update_time,                                                            -- 更新时间
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM credit_daily_records
ORDER BY credit_id, trx_date DESC
