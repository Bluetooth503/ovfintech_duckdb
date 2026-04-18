-- =============================================
-- 模型名称：dim_ranch_region
-- 模型描述：区域维度表，记录牧场区域基本信息和关联栏位统计
-- 粒度：region_id
-- 说明：
--   - 数据源：ods_psi_region（区域表）、ods_psi_stall_region（栏位区域关系表）、dim_ranch
--   - 关联逻辑：LEFT JOIN 牧场维度，LEFT JOIN 栏位区域关系统计栏位数
-- =============================================
{{ config(
    materialized='table',
    description='区域维度表，记录牧场区域的基本信息和关联的栏位信息',
    tags=['ranch', 'dim']
) }}

WITH source_region AS (
    SELECT
        id AS region_id,
        name AS region_name,
        type AS region_type,
        level AS region_level,
        CAST(tenant_id AS BIGINT) AS ranch_id,
        CAST(cattle_check AS BIGINT) AS is_ai_inventory,
        create_time,
        update_time
    FROM {{ ref('ods_psi_region') }}
    WHERE tenant_id IS NOT NULL
),

source_stall_region AS (
    SELECT
        id AS stall_region_id,
        stall_id,
        region_id,
        CAST(tenant_id AS BIGINT) AS ranch_id
    FROM {{ ref('ods_psi_stall_region') }}
    WHERE tenant_id IS NOT NULL
),

-- 统计每个区域关联的栏位数
region_stall_count AS (
    SELECT
        region_id,
        COUNT(DISTINCT stall_id) AS stall_count
    FROM source_stall_region
    GROUP BY region_id
),

-- 牧场维度关联
lkp_ranch AS (
    SELECT
        ranch_id,
        ranch_name
    FROM {{ ref('dim_ranch') }}
    WHERE is_current = '1'
),

region_with_stats AS (
    SELECT
        r.region_id,
        r.region_name,
        r.region_type,
        r.region_level,
        r.ranch_id,
        ranch.ranch_name,
        r.is_ai_inventory,
        COALESCE(rsc.stall_count, 0) AS stall_count,
        r.create_time,
        r.update_time
    FROM source_region r
    LEFT JOIN lkp_ranch ranch ON r.ranch_id = CAST(ranch.ranch_id AS VARCHAR)
    LEFT JOIN region_stall_count rsc ON r.region_id = rsc.region_id
)

SELECT
    region_id,                  -- 区域ID
    region_name,                -- 区域名称
    region_type,                -- 区域类型
    region_level,               -- 区域级别
    ranch_id,                   -- 牧场ID
    ranch_name,                 -- 牧场名称
    is_ai_inventory,            -- AI盘点标志
    stall_count,                -- 关联栏位数
    create_time,                -- 创建时间
    update_time                 -- 更新时间
FROM region_with_stats
ORDER BY ranch_id, region_id
