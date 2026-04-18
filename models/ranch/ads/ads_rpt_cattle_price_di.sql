-- =============================================
-- 模型名称：ads_rpt_cattle_price_di
-- 模型描述：活牛价格走势报表（自然日）
-- Dbt更新方式：增量（按日期）
-- 粒度：客户 + 品种 + 日期
-- 说明：
--   - 数据源：dws_ranch_cattle_weigh_agg_i
--   - 增量策略：按客户+品种+日期聚合价格数据，统计每日价格
--   - 统计指标：活牛单价（平均价、最小价、最大价）、牛只数量
--   - 聚合逻辑：按客户+品种+日期聚合价格数据
-- =============================================
{{ config(
    materialized='table',
    description='活牛价格走势报表（自然日），展示每日活牛单价变化趋势及统计信息',
    tags=['ranch', 'ads', 'report', 'price', 'daily']
) }}

-- ============================================
-- 按客户+品种+日期聚合价格数据
-- ============================================
WITH daily_price AS (
    SELECT
        stats_date,
        natural_week,
        customer_id,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        -- 聚合指标：计算平均价格、最小/最大价格
        AVG(cattle_price) AS avg_purchase_price,
        COUNT(*) AS cattle_count,
        -- 计算价格标准差（可选，用于分析价格波动）
        STDDEV(cattle_price) AS purchase_price_stddev,
        -- 计算最小/最大价格
        MIN(cattle_price) AS min_purchase_price,
        MAX(cattle_price) AS max_purchase_price
    FROM {{ ref('dws_ranch_cattle_weigh_agg_i') }}
    WHERE stats_date IS NOT NULL
      AND cattle_price IS NOT NULL  -- 只统计有价格的记录
    GROUP BY
        stats_date,
        natural_week,
        customer_id,
        cattle_sku_id,
        cattle_sku_name,
        brand_name
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    stats_date,
    natural_week,

    -- 客户维度
    customer_id,

    -- 品种维度
    cattle_sku_id,
    cattle_sku_name,
    brand_name,

    -- 指标
    ROUND(avg_purchase_price, 2) AS avg_purchase_price,
    cattle_count,
    ROUND(purchase_price_stddev, 2) AS purchase_price_stddev,
    ROUND(min_purchase_price, 2) AS min_purchase_price,
    ROUND(max_purchase_price, 2) AS max_purchase_price,

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time
FROM daily_price
WHERE avg_purchase_price > 0
ORDER BY stats_date, customer_id, cattle_sku_id
