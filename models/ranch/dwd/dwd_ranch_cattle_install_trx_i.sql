-- =============================================
-- 模型名称：dwd_ranch_cattle_install_trx_i
-- 模型描述：牧场域牛只入栏事务明细表，记录牛只入栏的增量交易数据
-- 作者：dbt
-- 创建时间：2026-04-03
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只入栏事务明细表，记录牛只入栏数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'install']
) }}

WITH src_install AS (
    SELECT
        id,                                             -- 事务ID
        purchase_id,                                    -- 采购单ID
        code AS cattle_code,                            -- 牛只编号
        vice_code,                                      -- 副编号
        stall_id,                                       -- 栏舍ID
        commodity_id AS sku_id,                         -- 商品ID
        CAST(weight AS DOUBLE) AS weight,               -- 入栏重量
        CAST(price AS DOUBLE) AS price,                 -- 单价
        CAST(total_price AS DOUBLE) AS total_price,     -- 总价
        birth_date::DATE AS birth_date,                 -- 出生日期
        install_date::DATE AS install_date,             -- 入栏日期
        color,                                          -- 毛色
        ai_score,                                       -- AI评分
        tenant_id,                                      -- 租户ID
        create_time::timestamp AS create_time,          -- 创建时间
        COALESCE(update_time::timestamp, create_time::timestamp) AS update_time  -- 更新时间
    FROM {{ ref('ods_ranch_install') }}
    WHERE create_time IS NOT NULL
)

SELECT
    id,                                             -- 事务ID
    purchase_id,                                    -- 采购单ID
    cattle_code,                                    -- 牛只编号
    vice_code,                                      -- 副编号
    stall_id,                                       -- 栏舍ID
    sku_id      ,                                   -- 商品ID
    weight,                                         -- 入栏重量
    price,                                          -- 单价
    total_price,                                    -- 总价
    birth_date,                                     -- 出生日期
    install_date,                                   -- 入栏日期
    color,                                          -- 毛色
    ai_score,                                       -- AI评分
    tenant_id,                                      -- 租户ID
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM src_install

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}