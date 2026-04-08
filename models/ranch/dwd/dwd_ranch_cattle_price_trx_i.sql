-- =============================================
-- 模型名称：dwd_ranch_cattle_price_trx_i
-- 模型描述：活牛价格事务表（增量）
-- 粒度：每次价格调整记录
-- 更新方式：增量追加
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='活牛价格事务表，记录价格调整历史',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'price']
) }}

-- 源数据 CTE
WITH source_price AS (
    SELECT
        id,
        create_time,
        update_time,
        commodity_id,
        price,
        tenant_id,
        start_weight,
        end_weight,
        sku_id
    FROM {{ ref('ods_psi_cattle_price') }}
),

-- 字段清洗与类型转换
enriched AS (
    SELECT
        id,                                                -- 价格记录ID
        commodity_id AS sku_id,                            -- SKU ID（商品ID/品种）
        sku_id AS collect_price_sku_id,                    -- 采集价格SKU ID
        tenant_id AS ranch_id,                             -- 牧场ID
        CAST(price AS DECIMAL(18,4)) AS unit_price,        -- 单价（元/斤）
        CAST(start_weight AS DECIMAL(10,2)) AS start_weight,             -- 起始体重(Kg)
        CAST(end_weight AS DECIMAL(10,2)) AS end_weight,                 -- 结束体重(Kg)
        update_time AS price_change_date,                  -- 价格变更日期
        create_time,                                       -- 创建时间
        update_time                                        -- 更新时间
    FROM source_price
)

-- 最终输出
SELECT
    id,                                                -- 价格记录ID
    sku_id,                                            -- SKU ID（商品ID/品种）
    collect_price_sku_id,                              -- 采集价格SKU ID
    ranch_id,                                          -- 牧场ID
    unit_price,                                        -- 单价（元/斤）
    start_weight,                                      -- 起始体重(Kg)
    end_weight,                                        -- 结束体重(Kg)
    price_change_date,                                 -- 价格变更日期
    create_time,                                       -- 创建时间
    update_time                                        -- 更新时间
FROM enriched

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
