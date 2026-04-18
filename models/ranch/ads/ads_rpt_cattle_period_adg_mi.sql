-- =============================================
-- 模型名称：ads_rpt_cattle_period_adg_mi
-- 模型描述：牛只日均增重统计报表（自然月）
-- Dbt更新方式：增量（按月）
-- 粒度：客户 + 牧场 + 自然月
-- 说明：
--   - 数据源：dws_ranch_cattle_weigh_agg_i
--   - 增量策略：按月聚合，AVG(period_adg)，保留全部历史数据，由前端筛选"过去12个月"
--   - 统计指标：月均日均增重、称重次数、牛只数
--   - 聚合逻辑：区间ADG（period_adg）
-- =============================================
{{ config(
    materialized='table',
    description='牛只日均增重统计报表（自然月），展示月度平均日均增重（ADG）指标',
    tags=['ranch', 'ads', 'report', 'adg', 'monthly']
) }}

-- ============================================
-- 按月聚合ADG数据
-- ============================================
WITH monthly_adg AS (
    SELECT
        natural_month,
        customer_id,
        ranch_id,
        ranch_name,
        -- 聚合指标
        AVG(period_adg) AS avg_period_adg,
        COUNT(period_adg) AS weigh_event_count,
        COUNT(DISTINCT cattle_id) AS cattle_count,
        -- 计算标准差（可选，用于分析ADG波动）
        STDDEV(period_adg) AS period_adg_stddev,
        -- 计算最小/最大值
        MIN(period_adg) AS min_period_adg,
        MAX(period_adg) AS max_period_adg
    FROM {{ ref('dws_ranch_cattle_weigh_agg_i') }}
    WHERE natural_month IS NOT NULL
      AND period_adg IS NOT NULL  -- 只统计有ADG数据的记录
    GROUP BY
        natural_month,
        customer_id,
        ranch_id,
        ranch_name
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    natural_month,
    -- 将自然月转换为月份开始日期（可选）
    DATE_TRUNC('month', DATE(CAST(natural_month / 100 AS INTEGER) || '-' || LPAD(CAST(natural_month % 100 AS VARCHAR), 2, '0') || '-01')) AS month_start_date,

    -- 组织维度
    customer_id,
    ranch_id,
    ranch_name,

    -- 指标
    ROUND(avg_period_adg, 4) AS avg_period_adg,
    weigh_event_count,
    cattle_count,
    ROUND(period_adg_stddev, 4) AS period_adg_stddev,
    ROUND(min_period_adg, 4) AS min_period_adg,
    ROUND(max_period_adg, 4) AS max_period_adg,

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time
FROM monthly_adg
WHERE avg_period_adg > 0
ORDER BY natural_month, customer_id, ranch_id
