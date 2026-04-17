-- =============================================
-- 模型名称：ads_ranch_nlme_ranch_efficiency
-- 模型描述：基于NLME模型的牧场效率排名分析
-- 说明：
--   - 使用NLME固定效应系数计算牧场校正因子
--   - 排名牧场生长表现
--   - 量化改进潜力
-- =============================================
{{ config(
    materialized='table',
    description='基于NLME模型的牧场效率排名与改进潜力分析',
    tags=['ranch', 'ads', 'report', 'nlme', 'efficiency', 'ranking']
) }}

WITH nlme_params AS (
    -- 从 NLME 结果表获取牧场效应
    SELECT
        dimension_value as ranch_name,
        fixed_effect_estimate as effect_log_A
    FROM {{ ref('ads_ranch_nlme_effects_pivot') }}
    WHERE effect_type = '牧场'
        AND growth_parameter = 'log_A'
),

ranch_stats AS (
    -- 牧场基础统计
    SELECT
        ranch_id,
        ranch_name,
        COUNT(DISTINCT cattle_id) AS n_cattle,
        COUNT(*) AS n_obs,
        AVG(current_weight) AS avg_weight,
        AVG(period_adg) AS avg_adg,
        STDDEV(current_weight) / NULLIF(AVG(current_weight), 0) AS cv_weight
    FROM {{ ref('dws_ranch_cattle_adg_agg_i') }}
    GROUP BY ranch_id, ranch_name
),

ranch_with_nlme AS (
    -- 合并NLME参数
    SELECT
        s.*,
        COALESCE(p.effect_log_A, 0) AS nlme_log_A_effect,
        -- 计算校正后的成熟体重估计
        EXP(6.47 + COALESCE(p.effect_log_A, 0)) AS estimated_mature_weight
    FROM ranch_stats s
    LEFT JOIN nlme_params p ON s.ranch_name = p.ranch_name
),

ranked_ranches AS (
    SELECT
        *,
        -- 基于成熟体重预测排名
        RANK() OVER (ORDER BY estimated_mature_weight DESC) AS rank_by_mature_weight,
        -- 基于CV排名（越低越好）
        RANK() OVER (ORDER BY cv_weight ASC) AS rank_by_consistency,
        -- 综合排名
        RANK() OVER (
            ORDER BY
                (RANK() OVER (ORDER BY estimated_mature_weight DESC)) * 0.6 +
                (RANK() OVER (ORDER BY cv_weight ASC)) * 0.4
        ) AS overall_rank
    FROM ranch_with_nlme
),

benchmark AS (
    -- 计算标杆牧场水平
    SELECT
        MAX(estimated_mature_weight) AS benchmark_mature_weight,
        AVG(cv_weight) AS avg_cv
    FROM ranked_ranches
    WHERE n_cattle >= 50  -- 只考虑样本充足的牧场
),

improvement_potential AS (
    -- 计算各牧场改进潜力
    SELECT
        r.*,
        b.benchmark_mature_weight,
        b.benchmark_mature_weight - r.estimated_mature_weight AS weight_gap_kg,
        -- 假设达到标杆水平，每头牛可多增重
        (b.benchmark_mature_weight - r.estimated_mature_weight) * r.n_cattle AS total_potential_kg
    FROM ranked_ranches r
    CROSS JOIN benchmark b
)

SELECT
    ranch_id,
    ranch_name,
    n_cattle,
    n_obs,
    ROUND(avg_weight, 2) AS avg_weight_kg,
    ROUND(avg_adg, 4) AS avg_adg_kg_day,
    ROUND(cv_weight, 4) AS weight_cv,
    ROUND(estimated_mature_weight, 2) AS estimated_mature_weight_kg,
    ROUND(nlme_log_A_effect, 4) AS nlme_mature_weight_effect
    overall_rank,
    rank_by_mature_weight,
    rank_by_consistency,
    ROUND(weight_gap_kg, 2) AS gap_to_benchmark_kg,
    ROUND(total_potential_kg, 2) AS total_improvement_potential_kg,
    -- 效率等级
    CASE
        WHEN overall_rank <= 3 THEN '优秀'
        WHEN overall_rank <= 7 THEN '良好'
        WHEN overall_rank <= 10 THEN '一般'
        ELSE '需改进'
    END AS efficiency_grade,
    CURRENT_TIMESTAMP AS analysis_date
FROM improvement_potential
ORDER BY overall_rank
