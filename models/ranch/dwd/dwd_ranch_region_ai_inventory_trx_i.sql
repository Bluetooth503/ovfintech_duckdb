-- =============================================
-- 模型名称：dwd_ranch_region_ai_inventory_trx_i
-- 模型描述：牧场域区域AI盘点事务明细表，记录区域AI盘点的增量数据
-- 作者：dbt
-- 创建时间：2026-04-07
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域区域AI盘点事务明细表，记录区域AI盘点数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'region', 'ai', 'inventory']
) }}

WITH src_ai_inventory AS (
    SELECT
        id,                                                  -- 事务ID
        region_id,                                           -- 区域ID
        region_name,                                         -- 区域名称
        CAST(value AS BIGINT) AS inventory_count,            -- 盘点数量
        CAST(cattle_count AS BIGINT) AS system_cattle_count, -- 系统牛只数量
        CAST(ratio AS DOUBLE) AS inventory_ratio,            -- 盘点率
        CAST(date AS TIMESTAMP) AS inventory_time,           -- 盘点时间
        CAST(alert_status AS BIGINT) AS alert_status,        -- 预警状态
        remark,                                              -- 备注
        CAST(tenant_id AS BIGINT) AS ranch_id,               -- 牧场ID
        DATE_TRUNC('day', CAST(date AS TIMESTAMP)) AS stats_date,  -- 统计日期
        CAST(date AS TIMESTAMP) AS create_time,              -- 创建时间
        CAST(date AS TIMESTAMP) AS update_time               -- 更新时间
    FROM {{ ref('ods_psi_region_ai_data') }}
    WHERE date IS NOT NULL
)

SELECT
    id,                                                  -- 事务ID
    region_id,                                           -- 区域ID
    region_name,                                         -- 区域名称
    inventory_count,                                     -- 盘点数量
    system_cattle_count,                                 -- 系统牛只数量
    inventory_ratio,                                     -- 盘点率
    inventory_time,                                      -- 盘点时间
    alert_status,                                        -- 预警状态
    remark,                                              -- 备注
    ranch_id,                                            -- 牧场ID
    stats_date,                                          -- 统计日期
    create_time,                                         -- 创建时间
    update_time,                                         -- 更新时间
    CURRENT_TIMESTAMP AS dw_load_time,                   -- 数据加载时间
    CURRENT_TIMESTAMP AS dw_update_time                  -- 数据更新时间

FROM src_ai_inventory

-- {% if is_incremental() %}
-- WHERE stats_date > (SELECT COALESCE(MAX(stats_date), TIMESTAMP '1900-01-01') FROM {{ this }})
-- {% endif %}

ORDER BY inventory_time DESC
