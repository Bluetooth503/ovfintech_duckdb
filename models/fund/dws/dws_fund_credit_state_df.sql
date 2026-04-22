-- =============================================
-- 模型名称：dws_fund_credit_state_df
-- 模型描述：授信额度当前状态表，记录每个授信的最新状态（T-1日）
-- Dbt更新方式：全量
-- 粒度：credit_id
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信事实表）
--   - 更新策略：每日全量覆盖，取每个授信的最新记录，不保留历史数据
--   - 业务时间过滤：只统计 trx_date <= T-1 的数据
--   - 取最新状态：按 credit_id 分组，取 update_time 最大的记录
--   - 用于下游分析授信额度使用情况
--   - 架构设计：与生产环境保持一致
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
),

latest_credit AS (
    -- ============================================
    -- 按授信ID取最新状态（T-1日截止）
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
        credit_used_quota,                                                      -- 授信已用额度（来自源表）
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
        ROW_NUMBER() OVER (PARTITION BY credit_id ORDER BY update_time DESC) AS rn
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
)

-- ============================================
-- 最终 SELECT
-- =============================================
SELECT
    -- 主键
    credit_id,                                                              -- 授信ID

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
    CASE WHEN credit_result = '1' AND TRY_STRPTIME(credit_end_date, '%Y%m%d') >= (SELECT stats_date FROM target_date) THEN '1' ELSE '0' END AS is_valid_credit,  -- 是否有效授信

    -- 是否有余额
    CASE WHEN credit_used_quota > 0 THEN '1' ELSE '0' END AS has_balance,   -- 是否有余额

    -- 数据仓库字段
    (SELECT stats_date FROM target_date) AS stats_date,                     -- 统计日期（T-1）
    trx_date,                                                               -- 最新更新日期
    update_time,                                                            -- 最新更新时间
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM latest_credit
WHERE rn = 1  -- 取每个授信的最新记录
  AND credit_result = '1'  -- 仅保留有效授信
ORDER BY credit_used_quota DESC
