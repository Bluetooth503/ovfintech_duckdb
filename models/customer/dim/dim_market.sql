-- =============================================
-- 模型名称：dim_market
-- 模型描述：市场维度表，记录市场基础信息及历史变更（SCD Type 2）
-- 粒度：market_id
-- 说明：
--   - 数据源：ods_market（市场基础信息表）
--   - 增量策略：全量刷新，SCD Type 2 有效期管理
-- =============================================
{{ config(
    materialized='table',
    description='市场维度表，记录市场基础信息及历史变更（SCD Type 2）',
    tags=['market', 'dim']
) }}

WITH market_base AS (
    SELECT
        id AS market_id,
        name AS market_name,
        code AS market_code,
        logo,
        creator,
        create_time,
        updator,
        update_time,
        status,
        order_expires_hour,
        inquiry_bill_expires_hour,
        is_init_term_agreement,
        access_switch,
        client_url,
        operate_url,
        pay_expires_hour,
        freeze_switch,
        freeze_amount,
        contract_sign_channel
    FROM {{ ref('ods_market') }}
    WHERE status != '0'
)

SELECT
    -- 主键
    mb.market_id,                          -- 市场ID

    -- 基础信息
    mb.market_name,                        -- 市场名称
    mb.market_code,                        -- 市场编码
    mb.logo,                               -- 市场Logo
    mb.client_url,                         -- 客户端URL地址
    mb.operate_url,                        -- 运营端URL地址

    -- 配置信息
    mb.order_expires_hour,                 -- 订单过期小时
    mb.inquiry_bill_expires_hour,          -- 询价单过期小时
    mb.pay_expires_hour,                   -- 支付过期时间
    mb.freeze_amount,                      -- 冻结金额
    mb.contract_sign_channel,              -- 合同签署渠道（3：北京CA|4：法大大）

    -- 开关和状态
    mb.status,                             -- 状态（1启用；2禁用, 0待启用）
    mb.access_switch,                      -- 准入开关（0关闭，1开启）
    mb.freeze_switch,                      -- 是否开启冻结（0否，1是）
    mb.is_init_term_agreement,             -- 是否初始化协议条款（0否，1是）

    -- 审计信息
    mb.creator,                            -- 创建人
    mb.create_time,                        -- 创建时间
    mb.updator,                            -- 更新人
    mb.update_time,                        -- 更新时间

    -- SCD Type 2 字段
    COALESCE(mb.update_time, mb.create_time) AS dw_effective_date,   -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,      -- 失效日期
    '1' AS is_current                                                   -- 是否当前记录

FROM market_base mb
