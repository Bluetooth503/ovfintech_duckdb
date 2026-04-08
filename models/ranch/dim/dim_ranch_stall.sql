-- =============================================
-- 模型名称：dim_ranch_stall
-- 模型描述：栏舍维度表 - SCD Type 2（含配方历史）
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='table',
    description='栏舍维度表，记录牛舍栏位的基本信息和配方变更历史（SCD Type 2）',
    tags=['ranch', 'dim']
) }}

WITH source_stall AS (
    SELECT
        id AS stall_id,
        name AS stall_name,
        stock_man AS feeder_name,
        recipe_id,
        recipe_name,
        tenant_id AS ranch_id,
        area_name,
        area_id,
        real_count AS real_cattle_count,
        total_weight AS total_cattle_weight,
        weight AS unit_weight,
        type AS stall_type,
        investor_id AS customer_id,
        name_sort AS sort_order,
        morning_one_weight AS morning_feed_weight,
        noon_one_weight AS noon_feed_weight,
        night_one_weight AS night_feed_weight,
        recipe_total_weight,
        CAST(system_cattle_num AS BIGINT) AS system_cattle_count,
        deleted,
        create_time,
        update_time,
        -- SCD Type 2 字段
        update_time AS dw_effective_date,
        CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,
        '1' AS is_current
    FROM {{ ref('ods_ranch_stall') }}
    WHERE deleted = 0
),

-- 牧场维度关联
lkp_ranch AS (
    SELECT
        ranch_id,
        ranch_name
    FROM {{ ref('dim_ranch') }}
    WHERE is_current = '1'
),

lkp_recipe AS (
    SELECT
        recipe_id,
        recipe_name,
        recipe_sku_id,
        recipe_sku_name,
        weight_begin,
        weight_end,
        feed_meat_ratio,
        plan_days
    FROM {{ ref('dim_ranch_recipe') }}
    WHERE is_current = '1'
),

stall_with_recipe AS (
    SELECT
        s.stall_id,
        s.stall_name,
        s.feeder_name,
        s.recipe_id,
        s.recipe_name,
        s.ranch_id,
        s.area_name AS region_name,
        s.area_id AS region_id,
        s.real_cattle_count,
        s.total_cattle_weight,
        s.unit_weight,
        s.stall_type,
        s.customer_id,
        s.sort_order,
        s.morning_feed_weight,
        s.noon_feed_weight,
        s.night_feed_weight,
        s.recipe_total_weight,
        s.system_cattle_count,
        s.deleted,
        s.create_time,
        s.update_time,
        -- 关联牧场维度信息
        r.ranch_name,
        -- 关联配方维度信息
        rec.recipe_sku_id,
        rec.recipe_sku_name,
        rec.weight_begin AS recipe_weight_begin,
        rec.weight_end AS recipe_weight_end,
        rec.feed_meat_ratio AS recipe_feed_meat_ratio,
        rec.plan_days AS recipe_plan_days,
        -- SCD Type 2 字段
        s.dw_effective_date,
        s.dw_expiry_date,
        s.is_current
    FROM source_stall s
    LEFT JOIN lkp_ranch r ON s.ranch_id = CAST(r.ranch_id AS VARCHAR)
    LEFT JOIN lkp_recipe rec ON s.recipe_id = rec.recipe_id
)

SELECT
    stall_id,                           -- 栏舍ID
    stall_name,                         -- 栏舍名称
    feeder_name,                        -- 饲养员
    recipe_id,                          -- 当前配方ID
    recipe_name,                        -- 当前配方名称
    ranch_id,                           -- 牧场ID
    ranch_name,                         -- 牧场名称
    region_name,                        -- 区域名称
    region_id,                          -- 区域ID
    real_cattle_count,                  -- 实际存栏数
    total_cattle_weight,                -- 总重量
    unit_weight,                        -- 单位重量
    stall_type,                         -- 栏舍类型
    customer_id,                        -- 客户ID
    sort_order,                         -- 排序名称
    morning_feed_weight,                -- 早饲喂量
    noon_feed_weight,                   -- 午饲喂量
    night_feed_weight,                  -- 晚饲喂量
    recipe_total_weight,                -- 配方总重量
    system_cattle_count,                -- 系统牛只数（预期容量）
    -- 配方维度信息
    recipe_sku_id,                      -- 配方SKU ID（配方对应的饲料类型）
    recipe_sku_name,                    -- 配方SKU名称
    recipe_weight_begin,                -- 配方适用体重起始
    recipe_weight_end,                  -- 配方适用体重结束
    recipe_feed_meat_ratio,             -- 配方目标料肉比
    recipe_plan_days,                   -- 配方计划天数
    -- SCD Type 2 字段
    dw_effective_date,                  -- 生效日期
    dw_expiry_date,                     -- 失效日期
    is_current                          -- 是否当前记录
FROM stall_with_recipe
