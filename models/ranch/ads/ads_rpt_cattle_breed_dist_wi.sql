-- =============================================
-- 模型名称：ads_rpt_cattle_breed_dist_wi
-- 模型描述：牛只品种分布报表（自然周）
-- Dbt更新方式：增量（按周）
-- 粒度：客户 + 牧场 + 品种 + 自然周
-- 说明：
--   - 数据源：dws_ranch_cattle_weigh_agg_i
--   - 增量策略：每周取最后一天的数据，按品种分组统计
--   - 统计指标：在栏牛只数量
--   - 聚合逻辑：按品种分组统计在栏数量
-- =============================================
{{ config(
    materialized='table',
    description='牛只品种分布报表（自然周），展示各品种牛只在栏数量分布',
    tags=['ranch', 'ads', 'report', 'breed', 'weekly']
) }}

-- ============================================
-- 获取每周最后一天的快照数据
-- ============================================
WITH weekly_snapshot AS (
    SELECT
        natural_week,
        customer_id,
        ranch_id,
        ranch_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        cattle_id,
        -- 行号：按周内日期排序，取最后一天
        ROW_NUMBER() OVER (PARTITION BY natural_week, customer_id, ranch_id, cattle_sku_id, cattle_id ORDER BY stats_date DESC) AS rn
    FROM {{ ref('dws_ranch_cattle_weigh_agg_i') }}
    WHERE natural_week IS NOT NULL
),

-- ============================================
-- 按品种聚合统计
-- ============================================
breed_distribution AS (
    SELECT
        natural_week,
        customer_id,
        ranch_id,
        ranch_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        COUNT(DISTINCT cattle_id) AS cattle_count
    FROM weekly_snapshot
    WHERE rn = 1  -- 只取每周最后一天的数据
    GROUP BY
        natural_week,
        customer_id,
        ranch_id,
        ranch_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name
),

-- ============================================
-- 计算品种占比
-- ============================================
with_percentage AS (
    SELECT
        natural_week,
        customer_id,
        ranch_id,
        ranch_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        cattle_count,
        -- 计算占牧场的比例
        cattle_count * 100.0 / SUM(cattle_count) OVER (PARTITION BY natural_week, customer_id, ranch_id) AS cattle_percentage
    FROM breed_distribution
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    natural_week,
    -- 将自然周转换为周开始日期（可选）
    DATE_TRUNC('week', DATE(CAST(natural_week / 100 AS INTEGER) || '-01-01') + (natural_week % 100 - 1) * INTERVAL '7 days') AS week_start_date,

    -- 组织维度
    customer_id,
    ranch_id,
    ranch_name,

    -- 品种维度
    cattle_sku_id,
    cattle_sku_name,
    brand_name,

    -- 指标
    cattle_count,
    ROUND(cattle_percentage, 2) AS cattle_percentage,

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time
FROM with_percentage
WHERE cattle_count > 0
ORDER BY natural_week, customer_id, ranch_id, cattle_count DESC
