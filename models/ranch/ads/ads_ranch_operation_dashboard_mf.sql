-- =============================================
-- 模型名称：ads_ranch_operation_dashboard_mf
-- 模型描述：牧场运营月报，按牧场+自然月统计栏舍利用率、周转效率、饲料效率及配方效果
-- Dbt更新方式：全量
-- 粒度：牧场 + 自然月
-- 说明：
--   - 数据源：dws_ranch_stall_capacity_agg_di（栏舍容量）+ dws_ranch_stall_performance_agg_di（栏舍绩效）+ dws_ranch_stall_feed_agg_di（栏舍饲料）+ dws_ranch_recipe_performance_agg_mi（配方效果）+ dws_ranch_ai_score_agg_di（AI评分）
--   - 增量策略：全量刷新（table）
--   - 统计指标：栏舍利用率、周转效率、饲料转化效率、配方执行率、AI覆盖率和评分
-- =============================================
{{ config(
    materialized='table',
    description='牧场运营月报，按牧场+自然月统计栏舍利用率、周转效率、饲料效率及配方效果',
    tags=['ranch', 'ads', 'operation', 'dashboard', 'monthly']
) }}

WITH
-- ============================================
-- 1. 月度栏舍容量统计
-- ============================================
capacity_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(design_cattle_count) AS month_total_capacity,
        SUM(actual_cattle_count) AS month_total_actual_cattle,
        SUM(design_weight_capacity) AS month_total_weight_capacity,
        SUM(actual_total_weight) AS month_total_actual_weight,
        AVG(cattle_capacity_utilization) AS month_avg_capacity_utilization
    FROM {{ ref('dws_ranch_stall_capacity_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 2. 月度周转统计
-- ============================================
turnover_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(total_cattle_count) AS month_total_cattle_count,
        SUM(count_under_30d) AS month_count_under_30d,
        SUM(count_30_60d) AS month_count_30_60d,
        SUM(count_60_90d) AS month_count_60_90d,
        SUM(count_90_120d) AS month_count_90_120d,
        SUM(count_120_150d) AS month_count_120_150d,
        SUM(count_150_180d) AS month_count_150_180d,
        SUM(count_over_180d) AS month_count_over_180d
    FROM {{ ref('dws_ranch_stall_performance_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 3. 月度饲料效率统计
-- ============================================
feed_efficiency_monthly AS (
    SELECT
        EXTRACT(YEAR FROM stats_date) * 100 + EXTRACT(MONTH FROM stats_date) AS natural_month,
        ranch_id,
        SUM(act_feed_quantity) AS month_total_feed_quantity,
        SUM(total_feed_cost) AS month_total_feed_cost,
        AVG(feed_plan_completion_rate) AS month_avg_feed_completion_rate,
        AVG(leftover_rate) AS month_avg_leftover_rate,
        AVG(concentrate_ratio) AS month_avg_concentrate_ratio,
        AVG(roughage_ratio) AS month_avg_roughage_ratio
    FROM {{ ref('dws_ranch_stall_feed_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 4. 月度配方效果统计（配方表无牧场维度，暂不关联）
-- ============================================
-- recipe_monthly AS (
--     SELECT
--         EXTRACT(YEAR FROM stats_month) * 100 + EXTRACT(MONTH FROM stats_month) AS natural_month,
--         'ALL' AS ranch_id,
--         COUNT(DISTINCT recipe_id) AS month_recipe_count,
--         SUM(cattle_count) AS month_recipe_cattle_count,
--         AVG(avg_period_adg) AS month_recipe_avg_adg,
--         AVG(actual_fcr) AS month_recipe_avg_fcr,
--         AVG(feed_cost_per_kg_gain) AS month_avg_feed_cost_per_kg_gain
--     FROM {{ ref('dws_ranch_recipe_performance_agg_mi') }}
--     WHERE stats_month IS NOT NULL
--     GROUP BY 1, 2
-- ),

-- ============================================
-- 5. 月度AI评分统计
-- ============================================
ai_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(total_scored_cattle) AS month_total_ai_scored_cattle,
        AVG(avg_ai_score) AS month_avg_ai_score
    FROM {{ ref('dws_ranch_ai_score_agg_di') }}
    WHERE score_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 6. 统一主键表
-- ============================================
all_keys AS (
    SELECT CAST(natural_month AS INTEGER) AS natural_month, ranch_id FROM capacity_monthly
    UNION
    SELECT CAST(natural_month AS INTEGER), ranch_id FROM turnover_monthly
    UNION
    SELECT CAST(natural_month AS INTEGER), ranch_id FROM feed_efficiency_monthly
    UNION
    SELECT CAST(natural_month AS INTEGER), ranch_id FROM ai_monthly
),

-- ============================================
-- 7. 数据整合与运营指标计算
-- ============================================
integrated AS (
    SELECT
        k.natural_month,
        k.ranch_id,
        COALESCE(dr.ranch_name, '') AS ranch_name,

        -- 栏舍利用率
        c.month_total_capacity,
        c.month_total_actual_cattle,
        c.month_total_weight_capacity,
        c.month_total_actual_weight,
        c.month_avg_capacity_utilization,
        CASE WHEN c.month_total_capacity > 0
             THEN CAST(c.month_total_actual_cattle AS DOUBLE) / c.month_total_capacity * 100
             ELSE NULL END AS overall_capacity_utilization_rate,

        -- 周转效率
        t.month_total_cattle_count,
        t.month_count_under_30d,
        t.month_count_30_60d,
        t.month_count_60_90d,
        t.month_count_90_120d,
        t.month_count_120_150d,
        t.month_count_150_180d,
        t.month_count_over_180d,

        -- 周转天数分布占比
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_under_30d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_under_30d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_30_60d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_30_60d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_60_90d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_60_90d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_90_120d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_90_120d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_120_150d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_120_150d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_150_180d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_150_180d,
        CASE WHEN t.month_total_cattle_count > 0
             THEN CAST(t.month_count_over_180d AS DOUBLE) / t.month_total_cattle_count * 100
             ELSE NULL END AS pct_over_180d,

        -- 饲料效率
        fe.month_total_feed_quantity,
        fe.month_total_feed_cost,
        fe.month_avg_feed_completion_rate,
        fe.month_avg_leftover_rate,
        fe.month_avg_concentrate_ratio,
        fe.month_avg_roughage_ratio,

        -- AI覆盖
        ai.month_total_ai_scored_cattle,
        ai.month_avg_ai_score,
        CASE WHEN c.month_total_actual_cattle > 0
             THEN CAST(ai.month_total_ai_scored_cattle AS DOUBLE) / c.month_total_actual_cattle * 100
             ELSE NULL END AS ai_score_coverage_rate

    FROM all_keys k
    LEFT JOIN capacity_monthly c ON k.natural_month = c.natural_month AND k.ranch_id = c.ranch_id
    LEFT JOIN turnover_monthly t ON k.natural_month = t.natural_month AND k.ranch_id = t.ranch_id
    LEFT JOIN feed_efficiency_monthly fe ON k.natural_month = fe.natural_month AND k.ranch_id = fe.ranch_id
    LEFT JOIN ai_monthly ai ON k.natural_month = ai.natural_month AND k.ranch_id = ai.ranch_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON k.ranch_id = dr.ranch_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 时间维度
    natural_month,
    ranch_id,
    ranch_name,

    -- 栏舍利用率
    month_total_capacity,                  -- 月总容量（牛只数）
    month_total_actual_cattle,             -- 月实际在栏数
    month_total_weight_capacity,           -- 月总容量（重量）
    month_total_actual_weight,             -- 月实际总重量
    month_avg_capacity_utilization,        -- 平均容量利用率
    overall_capacity_utilization_rate,     -- 整体容量利用率

    -- 周转效率
    month_total_cattle_count,              -- 月总牛只数
    month_count_under_30d,                 -- 30天内数量
    month_count_30_60d,                    -- 30-60天数量
    month_count_60_90d,                    -- 60-90天数量
    month_count_90_120d,                   -- 90-120天数量
    month_count_120_150d,                  -- 120-150天数量
    month_count_150_180d,                  -- 150-180天数量
    month_count_over_180d,                 -- 180天以上数量

    -- 周转天数分布占比
    pct_under_30d,                         -- 30天内占比
    pct_30_60d,                            -- 30-60天占比
    pct_60_90d,                            -- 60-90天占比
    pct_90_120d,                           -- 90-120天占比
    pct_120_150d,                          -- 120-150天占比
    pct_150_180d,                          -- 150-180天占比
    pct_over_180d,                         -- 180天以上占比

    -- 饲料效率
    month_total_feed_quantity,             -- 月总饲料消耗量
    month_total_feed_cost,                 -- 月总饲料成本
    month_avg_feed_completion_rate,        -- 平均投喂完成率
    month_avg_leftover_rate,               -- 平均剩料率
    month_avg_concentrate_ratio,           -- 平均精料占比
    month_avg_roughage_ratio,              -- 平均粗料占比

    -- AI覆盖
    month_total_ai_scored_cattle,          -- 月AI评分总数
    month_avg_ai_score,                    -- 月平均AI评分
    ai_score_coverage_rate,                -- AI评分覆盖率

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time

FROM integrated
ORDER BY natural_month DESC, ranch_id
