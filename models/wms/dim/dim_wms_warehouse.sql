-- =============================================
-- 模型名称：dim_wms_warehouse
-- 模型描述：仓库维度表，记录仓库基础信息及历史变更（SCD Type 2）
-- 粒度：warehouse_id
-- 说明：
--   - 数据源：ods_warehouse（仓库表）、ods_warehouse_ext（仓库扩展表）
--   - 关联逻辑：LEFT JOIN 仓库扩展表
-- =============================================
{{ config(
    materialized='table',
    description='仓库维度表，记录仓库基础信息及历史变更（SCD Type 2）',
    tags=['wms', 'dim', 'warehouse']
) }}

WITH warehouse_base AS (
    SELECT
        id AS warehouse_id,
        code AS warehouse_no,
        name AS warehouse_name,
        type AS warehouse_type,
        attribute AS warehouse_attribute,
        use AS warehouse_use,
        province,
        address AS warehouse_address,
        contact_name,
        contact_phone,
        area AS warehouse_area,
        status AS warehouse_status,
        org_id,
        org_name,
        remarks,
        creator_name AS creator,
        CAST(create_time AS TIMESTAMP) AS create_time,
        is_deleted
    FROM {{ ref('ods_warehouse') }}
),

warehouse_ext AS (
    SELECT
        warehouse_id,
        max_storeage,
        has_insurance,
        finance_type,
        property AS property_type
    FROM {{ ref('ods_warehouse_ext') }}
)

SELECT
    -- 主键
    wb.warehouse_id,                                    -- 仓库ID
    wb.warehouse_no,                                    -- 仓库编号
    wb.warehouse_name,                                  -- 仓库名称
    wb.warehouse_type,                                  -- 仓库类型
    wb.warehouse_attribute,                             -- 仓库属性
    wb.warehouse_use,                                   -- 仓库用途
    wb.warehouse_status,                                -- 仓库状态
    wb.province AS warehouse_province,                  -- 省份
    wb.warehouse_address,                               -- 仓库地址
    wb.contact_name,                                    -- 联系人姓名
    wb.contact_phone,                                   -- 联系人电话
    wb.warehouse_area,                                  -- 仓库面积
    wb.org_id,                                          -- 组织ID
    wb.org_name,                                        -- 组织名称
    COALESCE(we.max_storeage, '') AS max_storeage,      -- 最大存储量
    COALESCE(we.has_insurance, '') AS has_insurance,    -- 是否有保险
    COALESCE(we.finance_type, '') AS finance_type,      -- 金融类型
    COALESCE(we.property_type, '') AS property_type,    -- 产权类型
    wb.remarks AS warehouse_remark,                     -- 仓库备注
    wb.create_time,                                     -- 创建时间
    wb.creator,                                         -- 创建人
    wb.create_time AS dw_effective_date,                                          -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,                   -- 失效日期
    '1' AS is_current                                   -- 是否当前记录

FROM warehouse_base AS wb
LEFT JOIN warehouse_ext AS we ON wb.warehouse_id = we.warehouse_id
WHERE wb.is_deleted = '0' OR wb.is_deleted = 'false'
