-- =============================================
-- 模型名称：dim_ranch_grow_stage
-- 模型描述：生长阶段维度表，记录不同体重阶段的生长目标和料肉比目标（SCD Type 2）
-- 粒度：stage_id
-- 说明：
--   - 数据源：ods_psi_cattle_grow_config（生长阶段配置表）、dim_ranch_sku
--   - 关联逻辑：LEFT JOIN SKU维度获取品种名称
-- =============================================
{{ config(
    materialized='table',
    description='生长阶段维度表，记录不同体重阶段的生长目标和料肉比目标（SCD Type 2）',
    tags=['ranch', 'dim']
) }}

WITH source_grow_config AS (
    SELECT
        g.id AS stage_id,
        g.name AS stage_name,
        g.commodity_id AS sku_id,
        s.sku_name,
        s.brand_name,
        g.start_weight,
        g.end_weight,
        g.plan_weight_add,
        g.feed_meat_ratio,
        g.days,
        g.measure_max_weight,
        g.measure_min_weight,
        g.measure_normal_weight,
        g.tenant_id AS customer_id,
        g.create_time,
        g.update_time,
        -- SCD Type 2 字段
        g.update_time AS dw_effective_date,
        CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,
        '1' AS is_current
    FROM {{ ref('ods_psi_cattle_grow_config') }} AS g
    LEFT JOIN {{ ref('dim_ranch_sku') }} AS s ON g.commodity_id::VARCHAR = s.sku_id::VARCHAR AND s.is_current = '1'
)

SELECT
    stage_id,                           -- 阶段ID
    stage_name,                         -- 阶段名称
    sku_id,                             -- SKU ID（牛只品种）
    sku_name,                           -- SKU名称
    brand_name,                         -- 品牌名称
    start_weight,                       -- 阶段起始体重
    end_weight,                         -- 阶段结束体重
    plan_weight_add,                    -- 计划增重
    feed_meat_ratio,                    -- 目标料肉比
    days,                               -- 阶段天数
    measure_max_weight,                 -- 测量最大体重
    measure_min_weight,                 -- 测量最小体重
    measure_normal_weight,              -- 测量正常体重
    customer_id,                        -- 客户ID
    dw_effective_date,                  -- 生效日期
    dw_expiry_date,                     -- 失效日期
    is_current                          -- 是否当前记录
FROM source_grow_config
