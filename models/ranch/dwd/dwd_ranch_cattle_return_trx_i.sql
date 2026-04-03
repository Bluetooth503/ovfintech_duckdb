-- =============================================
-- 模型名称：dwd_ranch_cattle_return_trx_i
-- 模型描述：牧场域牛只退回事务明细表，记录牛只退回的增量交易数据
-- 作者：dbt
-- 创建时间：2026-04-03
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只退回事务明细表，记录牛只退回数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'return']
) }}

WITH src_return AS (
    SELECT
        id,                                             -- 事务ID
        code AS return_code,                            -- 退回单号
        return_date::DATE AS return_date,               -- 退回日期
        livestock_id AS cattle_id,                      -- 牛只ID
        CAST(return_weight AS DOUBLE) AS return_weight, -- 退回重量
        CAST(return_price AS DOUBLE) AS return_price,   -- 退回价格
        reason,                                         -- 退回原因
        tenant_id,                                      -- 租户ID
        create_time::timestamp AS create_time,          -- 创建时间
        COALESCE(update_time::timestamp, create_time::timestamp) AS update_time  -- 更新时间
    FROM {{ ref('ods_psi_cattle_return') }}
    WHERE create_time IS NOT NULL
)

SELECT
    id,                                             -- 事务ID
    return_code,                                    -- 退回单号
    return_date,                                    -- 退回日期
    cattle_id,                                      -- 牛只ID
    return_weight,                                  -- 退回重量
    return_price,                                   -- 退回价格
    reason,                                         -- 退回原因
    tenant_id,                                      -- 租户ID
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM src_return

{% if is_incremental() %}
WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
{% endif %}