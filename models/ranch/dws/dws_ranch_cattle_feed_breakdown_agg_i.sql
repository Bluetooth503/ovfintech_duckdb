-- =============================================
-- 模型名称：dws_ranch_cattle_feed_breakdown_agg_i
-- 模型描述：牛只饲料结构区间汇总表（增量），按称重区间聚合饲料组成、配方关联信息
-- Dbt更新方式：增量（事件级）
-- 粒度：每头牛每个称重区间一条记录
-- 说明：
--   - 数据源：dws_ranch_cattle_adg_fcr_i（ADG区间汇总）+ dwd_ranch_cattle_feed_fact_i（DWD层饲料明细）+ ods_psi_commodity（商品维度表）+ dim_ranch_stall（栏舍维度表）+ dim_ranch_recipe（配方维度表）
--   - 增量策略：事件级追加
--   - 统计指标：饲料消耗量、饲料成本、精料/粗料/添加剂/药品消耗及占比、配方匹配、料肉比等指标
--   - 聚合逻辑：与dws_ranch_cattle_adg_fcr_i对齐，按称重区间汇总饲料结构分层，关联栏舍配方和理论配方
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_date'],
    description='牛只饲料结构区间汇总表，按称重区间聚合饲料组成和配方关联信息（增量更新）',
    tags=['ranch', 'dws', 'feed', 'breakdown', 'agg', 'incremental']
) }}

-- ============================================
-- 基础数据：称重区间和牛只信息（复用 adg 表）
-- ============================================
WITH base_interval AS (
    SELECT
        stats_date,
        cattle_id,
        stall_id,
        ranch_id,
        ranch_name,
        customer_id,
        sku_id,
        sku_name,
        current_weight,
        prev_weight_date,
        interval_days,
        period_weight_gain
    FROM {{ ref('dws_ranch_cattle_adg_fcr_i') }}
    WHERE stats_date IS NOT NULL
),

-- ============================================
-- 饲料分类维度
-- ============================================
feed_category AS (
    SELECT
        id AS feed_sku_id,
        name AS feed_sku_name,
        type AS commodity_type,
        -- 饲料类型分类
        CASE WHEN type = '2' AND (name LIKE '%浓缩料%' OR name LIKE '%精料%' OR name LIKE '%玉米%' OR name LIKE '%豆粕%') THEN 'concentrate' 
             WHEN type = '2' AND (name LIKE '%稻草%' OR name LIKE '%青贮%' OR name LIKE '%秸秆%' OR name LIKE '%干草%' OR name LIKE '%苜蓿%' OR name LIKE '%啤酒糟%') THEN 'roughage' 
             WHEN type = '2' AND (name LIKE '%小苏打%' OR name LIKE '%益生菌%' OR name LIKE '%舔砖%' OR name LIKE '%预混料%') THEN 'additive' 
             WHEN type = '3' THEN 'medicine' ELSE 'other' END AS feed_type
    FROM {{ ref('ods_psi_commodity') }}
),

-- ============================================
-- 饲料明细关联分类
-- ============================================
classified_feed AS (
    SELECT
        f.cattle_id,
        f.feed_date,
        f.act_feed_quantity,
        f.act_feed_cost,
        c.feed_type
    FROM {{ ref('dwd_ranch_cattle_feed_fact_i') }} f
    LEFT JOIN feed_category c ON f.feed_sku_id::VARCHAR = c.feed_sku_id::VARCHAR
    WHERE f.feed_date IS NOT NULL
),

-- ============================================
-- 区间饲料聚合（含结构分层）
-- ============================================
interval_feed_agg AS (
    SELECT
        b.cattle_id,
        b.stats_date,
        SUM(f.act_feed_quantity) AS period_feed_consumption,
        SUM(f.act_feed_cost) AS period_feed_cost,
        SUM(CASE WHEN f.feed_type = 'concentrate' THEN f.act_feed_quantity ELSE 0 END) AS period_concentrate_qty,
        SUM(CASE WHEN f.feed_type = 'roughage' THEN f.act_feed_quantity ELSE 0 END) AS period_roughage_qty,
        SUM(CASE WHEN f.feed_type = 'additive' THEN f.act_feed_quantity ELSE 0 END) AS period_additive_qty,
        SUM(CASE WHEN f.feed_type = 'medicine' THEN f.act_feed_quantity ELSE 0 END) AS period_medicine_qty,
        SUM(CASE WHEN f.feed_type = 'other' THEN f.act_feed_quantity ELSE 0 END) AS period_other_qty,
        SUM(CASE WHEN f.feed_type = 'concentrate' THEN f.act_feed_cost ELSE 0 END) AS period_concentrate_cost,
        SUM(CASE WHEN f.feed_type = 'roughage' THEN f.act_feed_cost ELSE 0 END) AS period_roughage_cost,
        SUM(CASE WHEN f.feed_type = 'additive' THEN f.act_feed_cost ELSE 0 END) AS period_additive_cost,
        SUM(CASE WHEN f.feed_type = 'medicine' THEN f.act_feed_cost ELSE 0 END) AS period_medicine_cost,
        SUM(CASE WHEN f.feed_type = 'other' THEN f.act_feed_cost ELSE 0 END) AS period_other_cost
    FROM base_interval b
    LEFT JOIN classified_feed f ON b.cattle_id::VARCHAR = f.cattle_id::VARCHAR AND f.feed_date > b.prev_weight_date AND f.feed_date <= b.stats_date
    GROUP BY b.cattle_id, b.stats_date
),

-- ============================================
-- 栏舍配方关联（取当前绑定配方）
-- ============================================
stall_recipe AS (
    SELECT
        stall_id,
        recipe_id AS stall_recipe_id,
        recipe_name AS stall_recipe_name
    FROM {{ ref('dim_ranch_stall') }}
    WHERE is_current = '1'
),

-- ============================================
-- 理论配方匹配（按品种 + 体重区间 + 牧场）
-- 注意：dim_ranch_recipe 中同一 sku+ranch 下可能存在体重区间重叠，
--      因此用 ROW_NUMBER 去重，优先保留与栏舍当前配方一致的记录
-- ============================================
matched_recipe_raw AS (
    SELECT
        b.cattle_id,
        b.stats_date,
        r.recipe_id AS matched_recipe_id,
        r.recipe_name AS matched_recipe_name,
        r.feed_meat_ratio AS recipe_target_fcr,
        -- 配方匹配标记
        CASE WHEN s.stall_recipe_id::VARCHAR = r.recipe_id::VARCHAR THEN '1' ELSE '0' END AS recipe_match_flag,
        ROW_NUMBER() OVER (PARTITION BY b.cattle_id, b.stats_date ORDER BY CASE WHEN s.stall_recipe_id::VARCHAR = r.recipe_id::VARCHAR THEN 0 ELSE 1 END, r.weight_end - r.weight_begin, r.recipe_id) AS rn
    FROM base_interval b
    LEFT JOIN stall_recipe s ON b.stall_id::VARCHAR = s.stall_id::VARCHAR
    LEFT JOIN {{ ref('dim_ranch_recipe') }} r ON b.sku_id::VARCHAR = r.recipe_sku_id::VARCHAR AND b.current_weight >= r.weight_begin AND b.current_weight < r.weight_end AND b.ranch_id::VARCHAR = r.ranch_id::VARCHAR AND r.is_current = '1'
),

matched_recipe AS (
    SELECT
        cattle_id,
        stats_date,
        matched_recipe_id,
        matched_recipe_name,
        recipe_target_fcr,
        recipe_match_flag
    FROM matched_recipe_raw
    WHERE rn = 1
),

-- ============================================
-- 合并所有信息
-- ============================================
final_join AS (
    SELECT
        b.stats_date,
        b.cattle_id,
        b.stall_id,
        b.ranch_id,
        b.ranch_name,
        b.customer_id,
        b.sku_id,
        b.sku_name,
        b.current_weight,
        b.prev_weight_date,
        b.interval_days,
        b.period_weight_gain,
        fa.period_feed_consumption,
        fa.period_feed_cost,
        fa.period_concentrate_qty,
        fa.period_roughage_qty,
        fa.period_additive_qty,
        fa.period_medicine_qty,
        fa.period_other_qty,
        fa.period_concentrate_cost,
        fa.period_roughage_cost,
        fa.period_additive_cost,
        fa.period_medicine_cost,
        fa.period_other_cost,
        sr.stall_recipe_id,
        sr.stall_recipe_name,
        mr.matched_recipe_id,
        mr.matched_recipe_name,
        mr.recipe_target_fcr,
        mr.recipe_match_flag
    FROM base_interval b
    LEFT JOIN interval_feed_agg fa ON b.cattle_id = fa.cattle_id AND b.stats_date = fa.stats_date
    LEFT JOIN stall_recipe sr ON b.stall_id::VARCHAR = sr.stall_id::VARCHAR
    LEFT JOIN matched_recipe mr ON b.cattle_id = mr.cattle_id AND b.stats_date = mr.stats_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- ====================
    -- 标识维度
    -- ====================
    stats_date,                               -- 统计日期（称重日期）
    cattle_id,                                -- 牛只ID
    stall_id,                                 -- 栏舍ID
    ranch_id,                                 -- 牧场ID
    ranch_name,                               -- 牧场名称
    customer_id,                              -- 投资方ID
    sku_id,                                   -- 品种ID
    sku_name,                                 -- 品种名称
    prev_weight_date,                         -- 上次称重日期
    current_weight,                           -- 当前称重体重
    period_weight_gain,                       -- 区间增重

    -- ====================
    -- 饲料消耗总量
    -- ====================
    period_feed_consumption,                  -- 区间饲料总消耗量
    period_feed_cost,                         -- 区间饲料总成本
    -- 日均饲料摄入量
    CASE WHEN interval_days > 0 AND period_feed_consumption IS NOT NULL THEN period_feed_consumption / interval_days ELSE NULL END AS period_avg_feed_intake,
    -- 日均饲料成本
    CASE WHEN interval_days > 0 AND period_feed_cost IS NOT NULL THEN period_feed_cost / interval_days ELSE NULL END AS period_avg_feed_cost_per_day,
    -- 饲料平均单价
    CASE WHEN period_feed_consumption > 0 AND period_feed_cost IS NOT NULL THEN period_feed_cost / period_feed_consumption ELSE NULL END AS period_feed_unit_price,

    -- ====================
    -- 饲料结构分层
    -- ====================
    period_concentrate_qty,                   -- 精料消耗量
    period_roughage_qty,                      -- 粗料消耗量
    period_additive_qty,                      -- 添加剂消耗量
    period_medicine_qty,                      -- 药品消耗量
    period_other_qty,                         -- 其他饲料消耗量
    period_concentrate_cost,                  -- 精料成本
    period_roughage_cost,                     -- 粗料成本
    period_additive_cost,                     -- 添加剂成本
    period_medicine_cost,                     -- 药品成本
    period_other_cost,                        -- 其他饲料成本

    -- ====================
    -- 饲料结构占比
    -- ====================
    -- 精料占比
    CASE WHEN period_feed_consumption > 0 THEN period_concentrate_qty / period_feed_consumption ELSE NULL END AS concentrate_ratio,
    -- 粗料占比
    CASE WHEN period_feed_consumption > 0 THEN period_roughage_qty / period_feed_consumption ELSE NULL END AS roughage_ratio,
    -- 添加剂占比
    CASE WHEN period_feed_consumption > 0 THEN period_additive_qty / period_feed_consumption ELSE NULL END AS additive_ratio,
    -- 药品占比
    CASE WHEN period_feed_consumption > 0 THEN period_medicine_qty / period_feed_consumption ELSE NULL END AS medicine_ratio,
    -- 单位增重饲料成本
    CASE WHEN period_weight_gain > 0 AND period_feed_cost IS NOT NULL THEN period_feed_cost / period_weight_gain ELSE NULL END AS feed_cost_per_kg_gain,

    -- ====================
    -- 配方关联信息
    -- ====================
    stall_recipe_id,                          -- 栏舍绑定配方ID
    stall_recipe_name,                        -- 栏舍绑定配方名称
    matched_recipe_id,                        -- 理论匹配配方ID
    matched_recipe_name,                      -- 理论匹配配方名称
    recipe_target_fcr,                        -- 配方目标料肉比
    recipe_match_flag,                        -- 配方匹配标记

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time       -- 数据仓库更新时间
FROM final_join
WHERE stats_date IS NOT NULL AND cattle_id IS NOT NULL

-- {% if is_incremental() %}
-- AND stats_date > (SELECT COALESCE(MAX(stats_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}

ORDER BY stats_date, cattle_id
