-- =============================================
-- 模型名称：dwd_ranch_cattle_outstall_trx_i
-- 模型描述：牧场域牛只出栏事务明细表，记录牛只出栏的增量交易数据
-- 作者：dbt
-- 创建时间：2026-04-03
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只出栏事务明细表，记录牛只出栏数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'outstall']
) }}

WITH src_outstall AS (
    SELECT
        id,                                             -- 事务ID
        sell_id,                                        -- 销售单ID（如有）
        livestock_id AS cattle_id,                      -- 牛只ID
        code AS cattle_code,                            -- 牛只编号
        outstall_date::DATE AS outstall_date,           -- 出栏日期
        CAST(weight AS DOUBLE) AS weight,               -- 出栏重量
        CAST(price AS DOUBLE) AS price,                 -- 出栏单价
        reason,                                         -- 出栏原因
        out_type,                                       -- 出栏类型
        tenant_id,                                      -- 租户ID
        CAST(loan_money AS DOUBLE) AS loan_money,       -- 贷款金额
        investor_id,                                    -- 投资人ID
        investor_name,                                  -- 投资人名称
        commodity_id,                                   -- 商品ID
        commodity_name,                                 -- 商品名称
        status,                                         -- 状态
        id AS create_time,                              -- 使用ID作为时间戳替代
        id AS update_time                               -- 使用ID作为时间戳替代
    FROM {{ ref('ods_ranch_outstall') }}
    WHERE id IS NOT NULL
)

SELECT
    id,                                             -- 事务ID
    sell_id,                                        -- 销售单ID
    cattle_id,                                      -- 牛只ID
    cattle_code,                                    -- 牛只编号
    outstall_date,                                  -- 出栏日期
    weight,                                         -- 出栏重量
    price,                                          -- 出栏单价
    reason,                                         -- 出栏原因
    out_type,                                       -- 出栏类型
    tenant_id,                                      -- 租户ID
    loan_money,                                     -- 贷款金额
    investor_id,                                    -- 投资人ID
    investor_name,                                  -- 投资人名称
    commodity_id,                                   -- 商品ID
    commodity_name,                                 -- 商品名称
    status,                                         -- 状态
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM src_outstall

{% if is_incremental() %}
WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
{% endif %}