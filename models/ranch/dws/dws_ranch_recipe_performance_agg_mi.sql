-- =============================================
-- 模型名称：dws_ranch_recipe_performance_agg_mi
-- 模型描述：配方效果评估月汇总表（增量），按月统计配方生长绩效和饲料效率
-- Dbt更新方式：增量（按月份）
-- 粒度：配方 + SKU + 自然月
-- 说明：
--   - 数据源：dws_ranch_cattle_feed_breakdown_agg_i（饲料结构汇总）+ dws_ranch_cattle_adg_fcr_i（ADG汇总）+ dim_ranch_stall（栏舍维度表）
--   - 增量策略：按月份追加
--   - 统计指标：使用规模、生长绩效（增重、ADG）、饲料消耗、饲料结构、料肉比、成本效率等配方指标
--   - 聚合逻辑：通过栏舍配方归属将牛只数据聚合到配方维度
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_month'],
    description='配方效果评估月汇总表，按月统计配方生长绩效和饲料效率（增量更新）',
    tags=['ranch', 'dws', 'feed', 'recipe', 'monthly', 'agg', 'incremental']
) }}

-- ============================================
-- 牛只级饲料与生长数据（通过栏舍配方归属）
-- ============================================
WITH base_cattle AS (
    SELECT
        fb.cattle_id,
        fb.stats_date,
        DATE_TRUNC('month', fb.stats_date)::DATE AS stats_month,
        s.recipe_id,
        s.recipe_name,
        fb.sku_id,
        fb.sku_name,
        fb.period_weight_gain,
        fb.period_feed_consumption,
        fb.period_feed_cost,
        fb.period_concentrate_qty,
        fb.period_roughage_qty,
        fb.period_additive_qty,
        fb.period_medicine_qty,
        fb.period_other_qty,
        fb.recipe_target_fcr
    FROM {{ ref('dws_ranch_cattle_feed_breakdown_agg_i') }} fb
    LEFT JOIN {{ ref('dim_ranch_stall') }} s ON fb.stall_id::VARCHAR = s.stall_id::VARCHAR
    WHERE s.is_current = '1'
),

-- ============================================
-- ADG 数据补充
-- ============================================
adg_data AS (
    SELECT
        cattle_id,
        stats_date,
        period_adg,
        overall_adg
    FROM {{ ref('dws_ranch_cattle_adg_fcr_i') }}
    WHERE stats_date IS NOT NULL
),

-- ============================================
-- 配方月度聚合
-- ============================================
recipe_monthly_agg AS (
    SELECT
        bc.stats_month,
        bc.recipe_id,
        bc.recipe_name,
        bc.sku_id,
        bc.sku_name,
        COUNT(DISTINCT bc.cattle_id) AS cattle_count,
        SUM(bc.period_weight_gain) AS total_weight_gain,
        AVG(ad.period_adg) AS avg_period_adg,
        AVG(ad.overall_adg) AS avg_overall_adg,
        SUM(bc.period_feed_consumption) AS total_feed_consumption,
        SUM(bc.period_feed_cost) AS total_feed_cost,
        SUM(bc.period_concentrate_qty) AS total_concentrate_qty,
        SUM(bc.period_roughage_qty) AS total_roughage_qty,
        SUM(bc.period_additive_qty) AS total_additive_qty,
        SUM(bc.period_medicine_qty) AS total_medicine_qty,
        SUM(bc.period_other_qty) AS total_other_qty,
        AVG(bc.recipe_target_fcr) AS target_fcr
    FROM base_cattle bc
    LEFT JOIN adg_data ad ON bc.cattle_id = ad.cattle_id AND bc.stats_date = ad.stats_date
    GROUP BY bc.stats_month, bc.recipe_id, bc.recipe_name, bc.sku_id, bc.sku_name
),

-- ============================================
-- 配方使用规模（栏舍数，按当前绑定配方统计）
-- ============================================
recipe_stall_scale AS (
    SELECT
        DATE_TRUNC('month', fb.stats_date)::DATE AS stats_month,
        s.recipe_id,
        COUNT(DISTINCT s.stall_id) AS stall_count
    FROM {{ ref('dws_ranch_cattle_feed_breakdown_agg_i') }} fb
    LEFT JOIN {{ ref('dim_ranch_stall') }} s ON fb.stall_id::VARCHAR = s.stall_id::VARCHAR
    WHERE s.is_current = '1'
    GROUP BY DATE_TRUNC('month', fb.stats_date)::DATE, s.recipe_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- ====================
    -- 标识维度
    -- ====================
    a.stats_month,                            -- 统计月份
    a.recipe_id,                              -- 配方ID
    a.recipe_name,                            -- 配方名称
    a.sku_id,                                 -- 品种ID
    a.sku_name,                               -- 品种名称

    -- ====================
    -- 使用规模
    -- ====================
    COALESCE(s.stall_count, 0) AS stall_count, -- 使用该配方的栏舍数
    a.cattle_count,                           -- 使用该配方的牛只数
    -- 单栏舍平均牛只数
    CASE WHEN s.stall_count > 0 THEN a.cattle_count / s.stall_count ELSE NULL END AS cattle_count_per_stall,

    -- ====================
    -- 生长绩效
    -- ====================
    a.total_weight_gain,                      -- 当月总增重
    a.avg_period_adg,                         -- 平均区间ADG
    a.avg_overall_adg,                        -- 平均整体ADG

    -- ====================
    -- 饲料消耗
    -- ====================
    a.total_feed_consumption,                 -- 当月总饲料消耗量
    a.total_feed_cost,                        -- 当月总饲料成本
    -- 单头牛月均饲料消耗
    CASE WHEN a.cattle_count > 0 THEN a.total_feed_consumption / a.cattle_count ELSE NULL END AS avg_feed_intake_per_cattle,
    -- 单头牛月均饲料成本
    CASE WHEN a.cattle_count > 0 THEN a.total_feed_cost / a.cattle_count ELSE NULL END AS avg_feed_cost_per_cattle,

    -- ====================
    -- 饲料结构
    -- ====================
    -- 平均精料占比
    CASE WHEN a.total_feed_consumption > 0 THEN a.total_concentrate_qty / a.total_feed_consumption ELSE NULL END AS concentrate_ratio_avg,
    -- 平均粗料占比
    CASE WHEN a.total_feed_consumption > 0 THEN a.total_roughage_qty / a.total_feed_consumption ELSE NULL END AS roughage_ratio_avg,
    -- 平均添加剂占比
    CASE WHEN a.total_feed_consumption > 0 THEN a.total_additive_qty / a.total_feed_consumption ELSE NULL END AS additive_ratio_avg,
    -- 平均药品占比
    CASE WHEN a.total_feed_consumption > 0 THEN a.total_medicine_qty / a.total_feed_consumption ELSE NULL END AS medicine_ratio_avg,

    -- ====================
    -- 配方效率指标
    -- ====================
    -- 实际料肉比
    CASE WHEN a.total_weight_gain > 0 AND a.total_feed_consumption IS NOT NULL THEN a.total_feed_consumption / a.total_weight_gain ELSE NULL END AS actual_fcr,
    a.target_fcr,                             -- 配方目标料肉比
    -- 料肉比偏差
    CASE WHEN a.target_fcr IS NOT NULL AND a.total_weight_gain > 0 AND a.total_feed_consumption IS NOT NULL THEN (a.total_feed_consumption / a.total_weight_gain) - a.target_fcr ELSE NULL END AS fcr_deviation,
    -- 单位增重饲料成本
    CASE WHEN a.total_weight_gain > 0 AND a.total_feed_cost IS NOT NULL THEN a.total_feed_cost / a.total_weight_gain ELSE NULL END AS feed_cost_per_kg_gain,
    -- 成本效率指数
    CASE WHEN a.target_fcr > 0 AND a.total_weight_gain > 0 AND a.total_feed_consumption IS NOT NULL THEN a.target_fcr / (a.total_feed_consumption / a.total_weight_gain) ELSE NULL END AS cost_efficiency_index,

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time       -- 数据仓库更新时间
FROM recipe_monthly_agg a
LEFT JOIN recipe_stall_scale s ON a.stats_month = s.stats_month AND a.recipe_id::VARCHAR = s.recipe_id::VARCHAR
WHERE a.stats_month IS NOT NULL AND a.recipe_id IS NOT NULL

-- {% if is_incremental() %}
-- AND a.stats_month > (SELECT COALESCE(MAX(stats_month), 0) FROM {{ this }})
-- {% endif %}

ORDER BY a.stats_month DESC, a.recipe_id
