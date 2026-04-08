-- =============================================
-- 模型名称：dim_ranch_sku
-- 模型描述：牧场SKU商品维度表（含饲料、牛只等）- SCD Type 2
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='table',
    description='牧场SKU商品维度表，记录牧场相关商品（饲料、牛只、物资等）的基本信息和属性（SCD Type 2）',
    tags=['ranch', 'dim']
) }}

WITH source_commodity AS (
    SELECT
        id AS sku_id,
        code AS sku_code,
        name AS sku_name,
        type AS sku_type,
        brand AS brand_name,
        spec,
        piece_unit,
        quantity_unit,
        status,
        remark,
        tenant_id AS ranch_id,
        class_id,
        unitweight,
        dry,
        sort,
        uprice AS unit_price,
        if_alert AS is_alert_enabled,
        allow_offset_weight,
        create_time,
        update_time,
        -- SCD Type 2 字段
        update_time AS dw_effective_date,
        CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,
        '1' AS is_current
    FROM {{ ref('ods_psi_commodity') }}
),

-- 牧场维度关联
lkp_ranch AS (
    SELECT
        ranch_id,
        ranch_name
    FROM {{ ref('dim_ranch') }}
    WHERE is_current = '1'
),

final AS (
    SELECT
        s.sku_id,                           -- SKU ID
        s.sku_code,                         -- SKU编码
        s.sku_name,                         -- SKU名称
        s.sku_type,                         -- SKU类型（1-牛只，2-饲料，其他-物资）
        s.brand_name,                       -- 品牌名称
        s.spec,                             -- 规格
        s.piece_unit,                       -- 件单位
        s.quantity_unit,                    -- 数量单位
        s.status,                           -- 状态
        s.remark,                           -- 备注
        s.ranch_id,                         -- 牧场ID
        r.ranch_name,                       -- 牧场名称
        s.class_id,                         -- 分类ID
        s.unitweight,                       -- 单位重量
        s.dry,                              -- 干物质
        s.sort,                             -- 排序
        s.unit_price,                       -- 单价
        s.is_alert_enabled,                 -- 是否预警
        s.allow_offset_weight,              -- 允许误差重量
        s.dw_effective_date,                -- 生效日期
        s.dw_expiry_date,                   -- 失效日期
        s.is_current                        -- 是否当前记录
    FROM source_commodity AS s
    LEFT JOIN lkp_ranch AS r ON s.ranch_id = CAST(r.ranch_id AS VARCHAR)
)

SELECT
    sku_id,                           -- SKU ID
    sku_code,                         -- SKU编码
    sku_name,                         -- SKU名称
    sku_type,                         -- SKU类型（1-牛只，2-饲料，其他-物资）
    brand_name,                       -- 品牌名称
    spec,                             -- 规格
    piece_unit,                       -- 件单位
    quantity_unit,                    -- 数量单位
    status,                           -- 状态
    remark,                           -- 备注
    ranch_id,                         -- 牧场ID
    ranch_name,                       -- 牧场名称
    class_id,                         -- 分类ID
    unitweight,                       -- 单位重量
    dry,                              -- 干物质
    sort,                             -- 排序
    unit_price,                       -- 单价
    is_alert_enabled,                 -- 是否预警
    allow_offset_weight,              -- 允许误差重量
    dw_effective_date,                -- 生效日期
    dw_expiry_date,                   -- 失效日期
    is_current                        -- 是否当前记录
FROM final
