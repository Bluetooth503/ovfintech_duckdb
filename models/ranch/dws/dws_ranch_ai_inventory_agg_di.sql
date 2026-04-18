-- =============================================
-- 模型名称：dws_ranch_ai_inventory_agg_di
-- 模型描述：AI盘点日统计表，按日期统计栏舍AI盘点数据
-- Dbt更新方式：增量（按日期）
-- 粒度：牧场 + 栏舍 + 日期
-- 说明：
--   - 数据源：dwd_ranch_region_ai_inventory_fact_i（DWD层AI盘点明细）+ dim_ranch_stall（栏舍维度表）
--   - 增量策略：按日期追加
--   - 统计指标：盘点数量、盘点率、差异率、预警状态等盘点指标
--   - 聚合逻辑：1天内可能有多次盘点，取盘点数量最多的一次
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_date'],
    description='AI盘点日统计表，按日期统计栏舍的AI盘点数据（盘点数量、盘点率、差异率等）',
    tags=['ranch', 'dws', 'agg', 'ai', 'inventory', 'daily']
) }}

WITH region_inventory AS (
    -- 从DWD层获取AI盘点明细数据
    SELECT
        id,
        region_id,
        region_name,
        inventory_count,                    -- 盘点数量
        system_cattle_count,                -- 系统牛只数量
        inventory_ratio,                    -- 盘点率
        inventory_time,                     -- 盘点时间
        alert_status,                       -- 预警状态
        remark,
        ranch_id,
        stats_date                          -- 统计日期
    FROM {{ ref('dwd_ranch_region_ai_inventory_fact_i') }}
    WHERE inventory_time IS NOT NULL
),

-- 获取栏舍基本信息（包含区域关联）
stall_info AS (
    SELECT
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        region_id,
        system_cattle_count AS expected_cattle_count,           -- 系统牛只数（预期容量）
        real_cattle_count AS recorded_cattle_count,             -- 实际记录数量
        total_cattle_weight AS recorded_total_weight            -- 记录总重量
    FROM {{ ref('dim_ranch_stall') }}
    WHERE is_current = '1'
),

-- 将区域盘点数据关联到栏舍
inventory_by_stall AS (
    SELECT
        ri.stats_date,
        si.stall_id,
        si.stall_name,
        si.ranch_id,
        si.ranch_name,

        -- 区域信息
        ri.region_id,
        ri.region_name,

        -- 盘点原始数据
        ri.inventory_count,
        ri.system_cattle_count,
        ri.inventory_ratio,
        ri.alert_status,
        ri.inventory_time,
        ri.remark,

        -- 预期数据
        si.expected_cattle_count,
        si.recorded_cattle_count,
        si.recorded_total_weight,

        -- 排序，用于取每天盘点数量最多的一次（考虑环境、光线等因素影响）
        ROW_NUMBER() OVER (PARTITION BY ri.region_id, ri.stats_date ORDER BY ri.inventory_count DESC) AS rn

    FROM region_inventory ri
    INNER JOIN stall_info si ON ri.region_id = CAST(si.region_id AS VARCHAR)
),

-- 每天取盘点数量最多的一次（AI摄像头受环境、光线、牛只位置等因素影响，取最大值更准确）
latest_daily_inventory AS (
    SELECT
        stats_date,
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        region_id,
        region_name,
        inventory_count AS actual_inventory_count,       -- AI实际盘点数量
        system_cattle_count,                             -- 系统记录牛只数
        inventory_ratio AS ai_inventory_ratio,           -- AI盘点率
        alert_status,
        inventory_time,
        remark,
        expected_cattle_count,
        recorded_cattle_count,
        recorded_total_weight,

        -- 计算差异
        inventory_count - expected_cattle_count AS count_variance,    -- 数量差异
        inventory_count - recorded_cattle_count AS recorded_variance, -- 与记录数差异

        -- 重新计算盘点率
        CASE WHEN expected_cattle_count > 0 THEN CAST(inventory_count AS DOUBLE) / expected_cattle_count * 100 ELSE NULL END AS calculated_inventory_rate,

        -- 重新计算差异率
        CASE WHEN expected_cattle_count > 0 THEN ABS(CAST(inventory_count AS DOUBLE) - expected_cattle_count) / expected_cattle_count * 100 ELSE NULL END AS variance_rate,

        -- 计算自然周和自然月
        EXTRACT(YEAR FROM stats_date) * 100 + EXTRACT(WEEK FROM stats_date) AS natural_week,
        EXTRACT(YEAR FROM stats_date) * 100 + EXTRACT(MONTH FROM stats_date) AS natural_month

    FROM inventory_by_stall
    WHERE rn = 1  -- 取当天最后一次盘点
),

-- 计算盘点状态和分类指标
inventory_calc AS (
    SELECT
        stats_date,
        natural_week,
        natural_month,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        region_id,
        region_name,

        -- 预期数据
        expected_cattle_count,
        recorded_cattle_count,

        -- 实际盘点数据
        actual_inventory_count,
        system_cattle_count,
        ai_inventory_ratio,
        calculated_inventory_rate,
        recorded_total_weight,

        -- 差异统计
        count_variance,
        recorded_variance,
        variance_rate,

        -- 预警状态
        alert_status,

        -- 盘点时间
        inventory_time,
        remark,

        -- 盘点状态分类：根据盘点率划分状态
        CASE WHEN calculated_inventory_rate >= 98 THEN '完整' WHEN calculated_inventory_rate >= 95 THEN '基本完整' WHEN calculated_inventory_rate >= 90 THEN '有缺失' WHEN calculated_inventory_rate > 0 THEN '严重缺失' ELSE '未盘点' END AS inventory_status,

        -- 差异状态分类：根据绝对差异划分状态
        CASE WHEN ABS(count_variance) <= 1 THEN '无差异' WHEN ABS(count_variance) <= 5 THEN '轻微差异' WHEN ABS(count_variance) <= 10 THEN '明显差异' ELSE '严重差异' END AS variance_status,

        -- 预警状态解读
        CASE WHEN alert_status = 1 THEN '预警' ELSE '正常' END AS alert_status_label

    FROM latest_daily_inventory
)

SELECT
    -- ====================
    -- 维度字段
    -- ====================
    stats_date,
    natural_week,
    natural_month,
    ranch_id,
    ranch_name,
    stall_id,
    stall_name,
    region_id,
    region_name,

    -- ====================
    -- 预期数据
    -- ====================
    expected_cattle_count AS expected_cattle_count,
    recorded_cattle_count AS recorded_cattle_count,

    -- ====================
    -- 实际盘点数据
    -- ====================
    actual_inventory_count,
    system_cattle_count,
    ROUND(calculated_inventory_rate, 2) AS inventory_coverage_pct,
    ai_inventory_ratio AS ai_inventory_ratio_pct,

    -- ====================
    -- 差异分析
    -- ====================
    count_variance AS cattle_count_variance,
    recorded_variance AS recorded_count_variance,
    ROUND(variance_rate, 2) AS variance_pct,

    -- ====================
    -- 盘点质量指标
    -- ====================
    inventory_status AS inventory_status_label,
    variance_status AS variance_status_label,
    alert_status,
    alert_status_label,

    -- ====================
    -- 盘点完整性指标
    -- ====================
    -- 是否已盘点
    CASE WHEN actual_inventory_count > 0 THEN '1' ELSE '0' END AS is_inventoried,
    -- 是否完整盘点
    CASE WHEN calculated_inventory_rate >= 95 THEN '1' ELSE '0' END AS is_complete_inventory,

    -- ====================
    -- 预警指标
    -- ====================
    -- 是否预警
    CASE WHEN alert_status = 1 THEN '1' ELSE '0' END AS is_alerted,

    -- ====================
    -- 其他信息
    -- ====================
    inventory_time AS last_inventory_time,                -- 最后盘点时间
    remark,
    CURRENT_TIMESTAMP AS dw_update_time

FROM inventory_calc

-- {% if is_incremental() %}
-- WHERE stats_date > (SELECT COALESCE(MAX(stats_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}

ORDER BY stats_date DESC, ranch_id, stall_id
