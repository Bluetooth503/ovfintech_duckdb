-- =============================================
-- 模型名称：dwd_fund_credit_fact_i
-- 模型描述：授信明细事实表，记录每笔授信的详细信息及额度使用情况
-- Dbt更新方式：增量（事件级）
-- 粒度：credit_id
-- 说明：
--   - 数据源：ods_fund_member_credit（授信额度表）+ ods_fund_member_credit_apply（授信申请表）
--   - 增量策略：按 trx_date 分区，append
--   - 关联逻辑：LEFT JOIN 授信申请表获取 member_id 和产品信息
--   - 关键指标：授信额度、剩余额度、已用额度（贷款余额）
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['trx_date'],
    description='授信明细事实表，记录每笔授信的详细信息及额度使用情况',
    tags=['fund', 'dwd', 'fact', 'credit', 'loan']
) }}

WITH credit_with_apply AS (
    -- ============================================
    -- 关联授信表和授信申请表
    -- ============================================
    SELECT
        -- 主键
        c.id AS credit_id,                                                   -- 授信ID（主键）

        -- 时间信息
        c.create_time,                                                       -- 创建时间
        c.update_time,                                                       -- 更新时间
        CAST(c.update_time AS DATE) AS trx_date,                             -- 更新日期（分区字段）

        -- 客户信息
        ca.member_id AS customer_id,                                         -- 客户ID
        ca.member_name AS customer_name,                                     -- 客户名称
        ca.member_type AS customer_type,                                     -- 客户类型（1=个人，2=企业）
        ca.business_no AS credit_apply_sn,                                   -- 业务编号
        c.customer_contract_no,                                              -- 客户合同编号（关联借据表）

        -- 授信额度信息
        c.credit_quota,                                                      -- 授信额度
        c.remain_quota,                                                      -- 剩余额度
        (c.credit_quota - c.remain_quota) AS loan_balance,                   -- 贷款余额

        -- 利率信息
        c.base_rate,                                                         -- 基础利率
        c.rate_float,                                                        -- 浮动利率

        -- 期限信息
        c.credit_begin_day AS credit_start_date,                             -- 授信起期
        c.credit_end_day AS credit_end_date,                                 -- 授信止期

        -- 产品信息
        ca.financial_product_id,                                             -- 金融产品ID
        ca.financial_product_name,                                           -- 金融产品名称

        -- 资金方信息
        ca.fund_org_id,                                                      -- 资金方ID
        ca.fund_org_name,                                                    -- 资金方名称

        -- 授信属性
        c.loop_flag,                                                         -- 循环标志
        c.repay_type,                                                        -- 还款方式
        c.remaining_exposure,                                                -- 剩余敞口
        c.margin_ratio,                                                      -- 保证金比例
        c.reply_no,                                                          -- 批复号

        -- 状态信息
        c.result AS credit_result,                                           -- 授信结果（0=有效，1=无效）
        c.status AS credit_status,                                           -- 授信状态
        c.remark,                                                            -- 备注
        c.push_type,                                                         -- 推送类型

        -- 数据仓库字段
        CURRENT_TIMESTAMP AS dw_insert_time,                                 -- 数据仓库插入时间
        CURRENT_DATE AS dw_insert_date                                       -- 数据仓库插入日期

    FROM {{ ref('ods_fund_member_credit') }} c
    LEFT JOIN {{ ref('ods_fund_member_credit_apply') }} ca
        ON c.credit_apply_id = ca.id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    credit_id,                                                              -- 授信ID

    -- 时间信息
    create_time,                                                            -- 创建时间
    update_time,                                                            -- 更新时间
    trx_date,                                                               -- 更新日期（分区字段）

    -- 客户信息
    customer_id,                                                            -- 客户ID
    customer_name,                                                          -- 客户名称
    customer_type,                                                          -- 客户类型
    credit_apply_sn,                                                        -- 业务编号
    customer_contract_no,                                                   -- 客户合同编号（关联借据表）

    -- 授信额度信息
    credit_quota,                                                           -- 授信额度
    remain_quota,                                                           -- 剩余额度
    loan_balance,                                                           -- 贷款余额

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

    -- 数据仓库字段
    dw_insert_time,                                                         -- 数据仓库插入时间
    dw_insert_date                                                          -- 数据仓库插入日期

FROM credit_with_apply

-- {% if is_incremental() %}
-- AND CAST(update_time AS DATE) >= (SELECT COALESCE(MAX(trx_date), DATE '2020-01-01') - INTERVAL '7 days' FROM {{ this }})
-- {% endif %}

ORDER BY trx_date DESC, update_time DESC
