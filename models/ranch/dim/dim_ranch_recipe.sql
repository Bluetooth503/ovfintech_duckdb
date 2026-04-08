-- =============================================
-- 模型名称：dim_ranch_recipe
-- 模型描述：饲料配方维度表 - SCD Type 2
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='table',
    description='饲料配方维度表，记录饲料配方的基本信息和料肉比目标（SCD Type 2）',
    tags=['ranch', 'dim']
) }}

WITH source_recipe AS (
    SELECT
        id AS recipe_id,
        name AS recipe_name,
        commodity_id AS sku_id,
        weight_begin,
        weight_end,
        plan_days,
        day_age,
        tenant_id AS ranch_id,
        owner AS owner_name,
        color,
        sort,
        enable AS is_enable,
        feed_meat_ratio,
        measure,
        dry_matter_min,
        dry_matter_max,
        total_weight,
        feed_num AS feed_count,
        create_time,
        update_time,
        -- SCD Type 2 字段
        update_time AS dw_effective_date,
        CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,
        '1' AS is_current
    FROM {{ ref('ods_psi_recipe') }}
    WHERE enable = '1'
),

-- 牧场维度关联
lkp_ranch AS (
    SELECT
        ranch_id,
        ranch_name
    FROM {{ ref('dim_ranch') }}
    WHERE is_current = '1'
),

-- SKU维度关联
lkp_sku AS (
    SELECT
        sku_id,
        sku_name
    FROM {{ ref('dim_ranch_sku') }}
    WHERE is_current = '1'
)

SELECT
    s.recipe_id,                         -- 配方ID
    s.recipe_name,                       -- 配方名称
    s.sku_id AS recipe_sku_id,           -- 配方SKU ID（饲料类型）
    k.sku_name AS recipe_sku_name,       -- 配方SKU名称
    s.weight_begin,                      -- 适用体重起始
    s.weight_end,                        -- 适用体重结束
    s.plan_days,                         -- 计划天数
    s.day_age,                           -- 日龄
    s.ranch_id,                          -- 牧场ID
    r.ranch_name,                        -- 牧场名称
    s.owner_name,                        -- 负责人
    s.color,                             -- 颜色标识
    s.sort,                              -- 排序
    s.is_enable,                         -- 是否启用
    s.feed_meat_ratio,                   -- 目标料肉比
    s.measure,                           -- 测量值
    s.dry_matter_min,                    -- 干物质最小值
    s.dry_matter_max,                    -- 干物质最大值
    s.total_weight,                      -- 总重量
    s.feed_count,                        -- 饲喂次数
    s.dw_effective_date,                 -- 生效日期
    s.dw_expiry_date,                    -- 失效日期
    s.is_current                         -- 是否当前记录
FROM source_recipe s
LEFT JOIN lkp_ranch r ON s.ranch_id = CAST(r.ranch_id AS VARCHAR)
LEFT JOIN lkp_sku k ON s.sku_id = k.sku_id
