-- =============================================
-- 模型名称：dim_wms_position
-- 模型描述：库位维度表 - SCD Type 2
-- 作者：dbt
-- 创建时间：2026-04-08
-- =============================================
{{ config(
    materialized='table',
    description='库位维度表，记录仓库精确货位信息及历史变更（SCD Type 2）',
    tags=['wms', 'dim', 'position']
) }}

WITH position_base AS (
    SELECT
        id AS position_id,
        warehouse_area_id AS area_id,
        code AS position_no,
        name AS position_name,
        position_type,
        status AS position_status,
        x_sort AS coord_x,
        y_sort AS coord_y,
        remarks AS position_remark,
        creator,
        CAST(create_time AS TIMESTAMP) AS create_time,
        updator AS update_by,
        CAST(update_time AS TIMESTAMP) AS update_time,
        is_deleted
    FROM {{ ref('ods_warehouse_position') }}
),

area_info AS (
    SELECT
        id AS area_id,
        warehouse_id,
        code AS area_no,
        name AS area_name
    FROM {{ ref('ods_warehouse_area') }}
    WHERE is_deleted = '0' OR is_deleted = 'false'
),

warehouse_info AS (
    SELECT
        id AS warehouse_id,
        code AS warehouse_no,
        name AS warehouse_name
    FROM {{ ref('ods_warehouse') }}
    WHERE is_deleted = '0' OR is_deleted = 'false'
)

SELECT
    -- 主键
    pb.position_id,                  -- 库位ID
    pb.position_no,                  -- 库位编号
    pb.area_id,                      -- 库区ID
    ai.warehouse_id,                 -- 仓库ID
    pb.position_name,                -- 库位名称
    pb.position_type,                -- 库位类型
    pb.position_status,              -- 库位状态
    pb.coord_x,                      -- X坐标
    pb.coord_y,                      -- Y坐标
    ai.area_no,                      -- 库区编号
    ai.area_name,                    -- 库区名称
    wi.warehouse_no,                 -- 仓库编号
    wi.warehouse_name,               -- 仓库名称
    pb.position_remark,              -- 库位备注
    pb.create_time,                  -- 创建时间
    pb.creator,                      -- 创建人
    pb.update_time,                  -- 更新时间
    pb.update_by,                    -- 更新人
    pb.create_time AS dw_effective_date,                                          -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,                   -- 失效日期
    TRUE AS is_current               -- 是否当前记录

FROM position_base AS pb
LEFT JOIN area_info AS ai ON pb.area_id = ai.area_id
LEFT JOIN warehouse_info AS wi ON ai.warehouse_id = wi.warehouse_id
WHERE pb.is_deleted = '0' OR pb.is_deleted = 'false'
