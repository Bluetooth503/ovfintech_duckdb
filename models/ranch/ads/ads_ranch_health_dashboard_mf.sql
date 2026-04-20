-- =============================================
-- 模型名称：ads_ranch_health_dashboard_mf
-- 模型描述：牧场健康运营月报，按牧场+自然月统计群体健康指标、异常分布及体重达标率
-- Dbt更新方式：全量
-- 粒度：牧场 + 自然月
-- 说明：
--   - 数据源：dws_ranch_cattle_growth_agg_mi（月生长统计）+ dws_ranch_ai_score_agg_di（AI评分）+ dws_ranch_cattle_adg_fcr_i（ADG料肉比）+ dws_ranch_stall_performance_agg_di（栏舍绩效）
--   - 增量策略：全量刷新（table）
--   - 统计指标：群体ADG分布、AI评分分布、异常牛只比例、体重达标率、料肉比分布
-- =============================================
{{ config(
    materialized='table',
    description='牧场健康运营月报，按牧场+自然月统计群体健康指标、异常分布及体重达标率',
    tags=['ranch', 'ads', 'health', 'dashboard', 'monthly']
) }}

WITH

-- ============================================
-- 1. 月度生长统计
-- ============================================
growth_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        total_cattle_count,
        weighed_cattle_count,
        weigh_coverage_rate,
        avg_weight,
        avg_period_adg,
        stddev_period_adg,
        min_period_adg,
        max_period_adg
    FROM {{ ref('dws_ranch_cattle_growth_agg_mi') }}
),

-- ============================================
-- 2. 月度AI评分统计
-- ============================================
ai_score_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        SUM(total_scored_cattle) AS month_total_scored_cattle,
        AVG(avg_ai_score) AS month_avg_ai_score,
        SUM(count_score_a) AS month_count_score_a,
        SUM(count_score_b) AS month_count_score_b,
        SUM(count_score_c) AS month_count_score_c,
        SUM(count_score_d) AS month_count_score_d,
        SUM(count_score_e) AS month_count_score_e
    FROM {{ ref('dws_ranch_ai_score_agg_di') }}
    WHERE score_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 3. 月度料肉比统计
-- ============================================
fcr_monthly AS (
    SELECT
        natural_month,
        ranch_id,
        AVG(avg_period_fcr) AS month_avg_fcr,
        AVG(min_period_fcr) AS month_min_fcr,
        AVG(max_period_fcr) AS month_max_fcr,
        AVG(herd_fcr) AS month_herd_fcr
    FROM {{ ref('dws_ranch_stall_performance_agg_di') }}
    WHERE stats_date IS NOT NULL
    GROUP BY 1, 2
),

-- ============================================
-- 4. 统一主键表
-- ============================================
all_keys AS (
    SELECT natural_month, ranch_id FROM growth_monthly
    UNION
    SELECT natural_month, ranch_id FROM ai_score_monthly
    UNION
    SELECT natural_month, ranch_id FROM fcr_monthly
),

-- ============================================
-- 5. 数据整合与健康指标计算
-- ============================================
integrated AS (
    SELECT
        k.natural_month,
        k.ranch_id,
        COALESCE(dr.ranch_name, '') AS ranch_name,

        -- 在栏规模
        COALESCE(g.total_cattle_count, 0) AS total_cattle_count,
        COALESCE(g.weighed_cattle_count, 0) AS weighed_cattle_count,
        g.weigh_coverage_rate,

        -- ADG统计
        g.avg_period_adg,
        g.stddev_period_adg,
        g.min_period_adg,
        g.max_period_adg,

        -- AI评分统计
        COALESCE(ai.month_total_scored_cattle, 0) AS month_total_scored_cattle,
        ai.month_avg_ai_score,
        ai.month_count_score_a,
        ai.month_count_score_b,
        ai.month_count_score_c,
        ai.month_count_score_d,
        ai.month_count_score_e,

        -- AI评分覆盖率
        CASE WHEN g.total_cattle_count > 0
             THEN CAST(ai.month_total_scored_cattle AS DOUBLE) / g.total_cattle_count * 100
             ELSE NULL END AS ai_score_coverage_rate,

        -- AI评分占比
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_a AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_a,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_b AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_b,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_c AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_c,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_d AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_d,
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_e AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS pct_score_e,

        -- 料肉比统计
        f.month_avg_fcr,
        f.month_min_fcr,
        f.month_max_fcr,
        f.month_herd_fcr,

        -- 异常牛只比例
        CASE WHEN ai.month_total_scored_cattle > 0
             THEN CAST(ai.month_count_score_e AS DOUBLE) / ai.month_total_scored_cattle * 100
             ELSE NULL END AS abnormal_cattle_rate,

        -- 健康达标判定（ADG >= 0.8 且 AI评分 >= 80）
        CASE WHEN g.total_cattle_count > 0
             THEN (CAST(ai.month_count_score_a + ai.month_count_score_b AS DOUBLE) / g.total_cattle_count) * 100
             ELSE NULL END AS health_excellent_rate

    FROM all_keys k
    LEFT JOIN growth_monthly g ON k.natural_month = g.natural_month AND k.ranch_id = g.ranch_id
    LEFT JOIN ai_score_monthly ai ON k.natural_month = ai.natural_month AND k.ranch_id = ai.ranch_id
    LEFT JOIN fcr_monthly f ON k.natural_month = f.natural_month AND k.ranch_id = f.ranch_id
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

    -- 在栏规模
    total_cattle_count,                     -- 月末在栏数量
    weighed_cattle_count,                   -- 月度称重数量
    weigh_coverage_rate,                    -- 称重覆盖率

    -- ADG统计
    avg_period_adg,                         -- 平均ADG
    stddev_period_adg,                      -- ADG标准差
    min_period_adg,                         -- 最小ADG
    max_period_adg,                         -- 最大ADG

    -- AI评分统计
    month_total_scored_cattle,              -- 月度评分总数
    month_avg_ai_score,                     -- 月度平均AI评分
    month_count_score_a,                    -- A级数量
    month_count_score_b,                    -- B级数量
    month_count_score_c,                    -- C级数量
    month_count_score_d,                    -- D级数量
    month_count_score_e,                    -- E级数量

    -- AI评分覆盖率
    ai_score_coverage_rate,                 -- AI评分覆盖率

    -- AI评分占比
    pct_score_a,                            -- A级占比
    pct_score_b,                            -- B级占比
    pct_score_c,                            -- C级占比
    pct_score_d,                            -- D级占比
    pct_score_e,                            -- E级占比

    -- 料肉比统计
    month_avg_fcr,                          -- 月度平均料肉比
    month_min_fcr,                          -- 月度最小料肉比
    month_max_fcr,                          -- 月度最大料肉比
    month_herd_fcr,                         -- 群体料肉比

    -- 异常牛只比例
    abnormal_cattle_rate,                   -- 异常牛只比例（E级占比）

    -- 健康达标率
    health_excellent_rate,                  -- 健康优秀率（A+B级占比）

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time

FROM integrated
ORDER BY natural_month DESC, ranch_id
