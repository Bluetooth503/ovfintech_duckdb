-- =============================================
-- 模型名称：dim_wms_sku
-- 模型描述：商品SKU维度表 - SCD Type 2
-- 作者：dbt
-- 创建时间：2026-04-08
-- =============================================
{{ config(
    materialized='table',
    description='商品SKU维度表，记录仓库商品信息及历史变更（SCD Type 2）',
    tags=['wms', 'dim', 'sku']
) }}

WITH sku_base AS (
    SELECT
        id,
        member_id,
        org_id,
        sku_id,
        sku_name,
        attr_values AS sku_specification,
        batch_no,
        weight_num,
        charge_num,
        unit_translation,
        CAST(create_time AS TIMESTAMP) AS create_time,
        CAST(update_time AS TIMESTAMP) AS update_time,
        is_deleted
    FROM {{ ref('ods_sku') }}
),

category_base AS (
    SELECT
        id AS category_id,
        warehouse_id,
        category_id AS category_code,
        business_id,
        business_name
    FROM {{ ref('ods_category') }}
)

SELECT
    -- 主键
    sb.id AS sku_record_id,          -- SKU记录ID
    sb.sku_id,                       -- SKU编号
    sb.sku_name,                     -- SKU名称
    sb.member_id,                    -- 会员ID
    sb.org_id,                       -- 组织ID
    sb.sku_specification,            -- SKU规格
    sb.batch_no,                     -- 批次号
    sb.weight_num,                   -- 重量
    sb.charge_num,                   -- 计费数量
    sb.unit_translation,             -- 单位换算
    cb.category_id,                  -- 品类ID
    cb.category_code,                -- 品类编码
    cb.business_id,                  -- 业务ID
    cb.business_name,                -- 业务名称
    cb.warehouse_id,                 -- 仓库ID
    sb.create_time,                  -- 创建时间
    sb.update_time,                  -- 更新时间
    sb.create_time AS dw_effective_date,                                          -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,                   -- 失效日期
    TRUE AS is_current               -- 是否当前记录

FROM sku_base AS sb
LEFT JOIN category_base AS cb ON sb.org_id = cb.warehouse_id
WHERE sb.is_deleted = '0' OR sb.is_deleted = 'false'
