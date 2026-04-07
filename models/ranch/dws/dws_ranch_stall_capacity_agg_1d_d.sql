-- =============================================
-- 模型名称：dws_ranch_stall_capacity_agg_1d_d
-- 模型描述：栏舍容量日统计表，按日期统计栏舍的容量利用率
-- 作者：dbt
-- 创建时间：2026-04-07
-- 更新方式：增量（按日期）
-- 粒度：牧场 + 栏舍 + 日期
-- 说明：
--   - 数据源：dim_ranch_stall（栏舍维度）+ dws_ranch_cattle_snapshot_1d_d
--   - 增量策略：按日期追加
--   - 统计指标：容量利用率、牛只密度、存栏量等容量指标
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_date'],
    description='栏舍容量日统计表，按日期统计栏舍的容量利用率、牛只密度、存栏量等容量指标',
    tags=['ranch', 'dws', 'agg', 'stall', 'capacity', 'daily']
) }}

WITH stall_state AS (
    -- 从栏舍维度表获取容量配置（最新状态）
    SELECT
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        system_cattle_count,
        recipe_total_weight,
        recipe_id,
        recipe_name,
        stall_type,
        region_name,
        customer_id
    FROM {{ ref('dim_ranch_stall') }}
    WHERE is_current = '1'
),

cattle_snap AS (
    -- 从牛只日快照表获取牛只数据
    SELECT
        stats_date,
        natural_week,
        natural_month,
        cattle_id,
        stall_id,
        current_weight,
        cattle_sku_id,
        cattle_sku_name
    FROM {{ ref('dws_ranch_cattle_snapshot_1d_d') }}
    WHERE stats_date IS NOT NULL
),

-- 关联栏舍配置和牛只快照
capacity_data AS (
    SELECT
        c.stats_date,
        c.natural_week,
        c.natural_month,
        s.stall_id,
        s.stall_name,
        s.ranch_id,
        s.ranch_name,
        s.recipe_id,
        s.recipe_name,
        s.stall_type,
        s.region_name,
        s.customer_id,
        s.system_cattle_count AS design_cattle_count,
        s.recipe_total_weight AS design_weight_capacity,

        -- 实际使用情况
        COUNT(DISTINCT c.cattle_id) AS actual_cattle_count,
        SUM(c.current_weight) AS actual_total_weight,

        -- 按品种统计
        COUNT(DISTINCT CASE WHEN c.cattle_sku_name LIKE '%西门塔尔%' THEN c.cattle_id END) AS count_simmental,
        COUNT(DISTINCT CASE WHEN c.cattle_sku_name LIKE '%安格斯%' THEN c.cattle_id END) AS count_angus,
        COUNT(DISTINCT CASE WHEN c.cattle_sku_name LIKE '%夏洛莱%' THEN c.cattle_id END) AS count_charolais,
        COUNT(DISTINCT CASE WHEN c.cattle_sku_name LIKE '%利木赞%' THEN c.cattle_id END) AS count_limousin,

        -- 体重区间统计
        COUNT(DISTINCT CASE WHEN c.current_weight < 300 THEN c.cattle_id END) AS count_under_300kg,
        COUNT(DISTINCT CASE WHEN c.current_weight >= 300 AND c.current_weight < 400 THEN c.cattle_id END) AS count_300_400kg,
        COUNT(DISTINCT CASE WHEN c.current_weight >= 400 AND c.current_weight < 500 THEN c.cattle_id END) AS count_400_500kg,
        COUNT(DISTINCT CASE WHEN c.current_weight >= 500 AND c.current_weight < 600 THEN c.cattle_id END) AS count_500_600kg,
        COUNT(DISTINCT CASE WHEN c.current_weight >= 600 THEN c.cattle_id END) AS count_over_600kg,

        CURRENT_TIMESTAMP AS dw_update_time

    FROM cattle_snap c
    INNER JOIN stall_state s ON c.stall_id = s.stall_id
    GROUP BY
        c.stats_date,
        c.natural_week,
        c.natural_month,
        s.stall_id,
        s.stall_name,
        s.ranch_id,
        s.ranch_name,
        s.recipe_id,
        s.recipe_name,
        s.stall_type,
        s.region_name,
        s.customer_id,
        s.system_cattle_count,
        s.recipe_total_weight
),

-- 计算容量利用率
capacity_calc AS (
    SELECT
        stats_date,
        natural_week,
        natural_month,
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        recipe_id,
        recipe_name,
        stall_type,
        region_name,
        customer_id,

        -- 设计容量
        design_cattle_count,
        design_weight_capacity,

        -- 实际使用
        actual_cattle_count,
        actual_total_weight,

        -- 品种分布
        count_simmental,
        count_angus,
        count_charolais,
        count_limousin,

        -- 体重区间分布
        count_under_300kg,
        count_300_400kg,
        count_400_500kg,
        count_500_600kg,
        count_over_600kg,

        -- 牛只容量利用率(%)
        CASE WHEN design_cattle_count > 0 THEN CAST(actual_cattle_count AS DOUBLE) / design_cattle_count * 100 ELSE NULL END AS cattle_capacity_utilization,

        -- 重量容量利用率(%)
        CASE WHEN design_weight_capacity > 0 AND actual_total_weight IS NOT NULL THEN actual_total_weight / design_weight_capacity * 100 ELSE NULL END AS weight_capacity_utilization,

        -- 剩余容量
        design_cattle_count - actual_cattle_count AS remaining_cattle_capacity,
        design_weight_capacity - actual_total_weight AS remaining_weight_capacity,

        -- 平均每头牛重量
        CASE WHEN actual_cattle_count > 0 THEN actual_total_weight / actual_cattle_count ELSE NULL END AS avg_weight_per_cattle,

        -- 每个设计槽位实际承重
        CASE WHEN design_cattle_count > 0 AND actual_total_weight IS NOT NULL THEN actual_total_weight / design_cattle_count ELSE NULL END AS actual_weight_per_design_slot,

        dw_update_time

    FROM capacity_data
)

SELECT
    -- 时间维度
    stats_date,
    natural_week,
    natural_month,

    -- 组织维度
    ranch_id,
    ranch_name,
    stall_id,
    stall_name,
    recipe_id,
    recipe_name,
    stall_type,
    region_name,
    customer_id,

    -- 设计容量
    design_cattle_count,
    ROUND(design_weight_capacity, 2) AS design_weight_capacity,

    -- 实际使用情况
    actual_cattle_count,
    ROUND(actual_total_weight, 2) AS actual_total_weight,

    -- 容量利用率
    ROUND(cattle_capacity_utilization, 2) AS cattle_capacity_utilization,
    ROUND(weight_capacity_utilization, 2) AS weight_capacity_utilization,

    -- 容量状态标签
    CASE WHEN cattle_capacity_utilization >= 95 THEN '满载' WHEN cattle_capacity_utilization >= 85 THEN '高负载' WHEN cattle_capacity_utilization >= 70 THEN '正常负载' WHEN cattle_capacity_utilization >= 50 THEN '低负载' WHEN cattle_capacity_utilization > 0 THEN '闲置' ELSE '空栏' END AS capacity_status,

    -- 剩余容量
    remaining_cattle_capacity,
    ROUND(remaining_weight_capacity, 2) AS remaining_weight_capacity,

    -- 牛只密度指标
    ROUND(avg_weight_per_cattle, 2) AS avg_weight_per_cattle,
    ROUND(actual_weight_per_design_slot, 2) AS actual_weight_per_design_slot,

    -- 品种分布
    count_simmental,
    count_angus,
    count_charolais,
    count_limousin,

    -- 体重区间分布
    count_under_300kg,
    count_300_400kg,
    count_400_500kg,
    count_500_600kg,
    count_over_600kg,

    -- 元数据
    dw_update_time

FROM capacity_calc

-- {% if is_incremental() %}
-- WHERE stats_date > (SELECT COALESCE(MAX(stats_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}

ORDER BY stats_date DESC, ranch_id, stall_id
