-- =============================================
-- 模型名称：ads_rpt_cattle_age_dist_1w_w
-- 模型描述：牛只在栏月龄分布报表（自然周）
-- 作者：dbt
-- 创建时间：2026-04-07
-- 说明：
--   - 粒度：客户 + 牧场 + 月龄区间 + 自然周
--   - 指标：在栏牛只数量
--   - 月龄区间：1月、2月、...、12月、12月以上
--   - 数据来源：dws_ranch_cattle_rpt_snapshot_1d_d
--   - 聚合逻辑：每周取最后一天的数据，按月龄区间分组统计
-- =============================================
{{ config(
    materialized='table',
    description='牛只在栏月龄分布报表（自然周），展示不同在栏月龄区间的牛只数量分布',
    tags=['ranch', 'ads', 'report', 'age', 'weekly']
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
        months_in_stall_bucket,
        months_in_stall_bucket_sort,
        cattle_id,
        -- 行号：按周内日期排序，取最后一天
        ROW_NUMBER() OVER ( PARTITION BY natural_week, customer_id, ranch_id, cattle_id ORDER BY stats_date DESC) AS rn
    FROM {{ ref('dws_ranch_cattle_snapshot_1d_d') }}
    WHERE natural_week IS NOT NULL AND months_in_stall_bucket IS NOT NULL
),

-- ============================================
-- 按月龄区间聚合统计
-- ============================================
age_distribution AS (
    SELECT
        natural_week,
        customer_id,
        ranch_id,
        ranch_name,
        months_in_stall_bucket,
        months_in_stall_bucket_sort,
        COUNT(DISTINCT cattle_id) AS cattle_count
    FROM weekly_snapshot
    WHERE rn = 1  -- 只取每周最后一天的数据
    GROUP BY
        natural_week,
        customer_id,
        ranch_id,
        ranch_name,
        months_in_stall_bucket,
        months_in_stall_bucket_sort
),

-- ============================================
-- 计算月龄区间占比
-- ============================================
with_percentage AS (
    SELECT
        natural_week,
        customer_id,
        ranch_id,
        ranch_name,
        months_in_stall_bucket,
        months_in_stall_bucket_sort,
        cattle_count,
        -- 计算占牧场的比例
        cattle_count * 100.0 / SUM(cattle_count) OVER (PARTITION BY natural_week, customer_id, ranch_id) AS cattle_percentage
    FROM age_distribution
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

    -- 月龄区间维度
    months_in_stall_bucket,
    months_in_stall_bucket_sort,

    -- 指标
    cattle_count,
    ROUND(cattle_percentage, 2) AS cattle_percentage,

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time
FROM with_percentage
WHERE cattle_count > 0
ORDER BY natural_week, customer_id, ranch_id, months_in_stall_bucket_sort
