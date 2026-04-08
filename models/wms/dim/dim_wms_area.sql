-- =============================================
-- 模型名称：dim_wms_area
-- 模型描述：库区维度表 - SCD Type 2
-- 作者：dbt
-- 创建时间：2026-04-08
-- =============================================
{{ config(
    materialized='table',
    description='库区维度表，记录仓库库区划分及历史变更（SCD Type 2）',
    tags=['wms', 'dim', 'area']
) }}

WITH area_base AS (
    SELECT
        id AS area_id,
        warehouse_id,
        code AS area_no,
        name AS area_name,
        status AS area_status,
        remarks AS area_remark,
        creator,
        CAST(create_time AS TIMESTAMP) AS create_time,
        updator AS update_by,
        CAST(update_time AS TIMESTAMP) AS update_time,
        is_deleted
    FROM {{ ref('ods_warehouse_area') }}
)

SELECT
    -- 主键
    ab.area_id,                      -- 库区ID
    ab.warehouse_id,                 -- 仓库ID
    ab.area_no,                      -- 库区编号
    ab.area_name,                    -- 库区名称
    ab.area_status,                  -- 库区状态
    ab.area_remark,                  -- 库区备注
    ab.create_time,                  -- 创建时间
    ab.creator,                      -- 创建人
    ab.update_time,                  -- 更新时间
    ab.update_by,                    -- 更新人
    ab.create_time AS dw_effective_date,                                          -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,                   -- 失效日期
    TRUE AS is_current               -- 是否当前记录

FROM area_base AS ab
WHERE ab.is_deleted = '0' OR ab.is_deleted = 'false'
