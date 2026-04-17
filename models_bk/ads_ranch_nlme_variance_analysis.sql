-- =============================================
-- 模型名称：ads_ranch_nlme_variance_analysis
-- 模型描述：NLME 方差分解分析表
-- =============================================
{{ config(
    materialized='table',
    description='NLME 方差分解分析，量化各维度对生长变异的贡献',
    tags=['ranch', 'ads', 'report', 'nlme', 'variance_decomposition']
) }}

WITH variance_results AS (
    SELECT * FROM {{ ref('ads_ranch_cattle_gompertz_nlme') }}
    WHERE result_type = 'variance'
),

total_variance AS (
    SELECT
        SUM(CASE WHEN parameter LIKE '%u_log_A%' THEN estimate ELSE 0 END) as var_log_A,
        SUM(CASE WHEN parameter LIKE '%u_log_B%' THEN estimate ELSE 0 END) as var_log_B,
        SUM(CASE WHEN parameter LIKE '%u_C%' THEN estimate ELSE 0 END) as var_C
    FROM variance_results
),

variance_by_param AS (
    SELECT
        'log_A (成熟体重)' as parameter_group,
        var_log_A as variance_component,
        var_log_A / (var_log_A + var_log_B + var_C) * 100 as contribution_pct
    FROM total_variance

    UNION ALL

    SELECT
        'log_B (生长速率)' as parameter_group,
        var_log_B as variance_component,
        var_log_B / (var_log_A + var_log_B + var_C) * 100 as contribution_pct
    FROM total_variance

    UNION ALL

    SELECT
        'C (拐点日龄)' as parameter_group,
        var_C as variance_component,
        var_C / (var_log_A + var_log_B + var_C) * 100 as contribution_pct
    FROM total_variance
)

SELECT
    parameter_group,
    ROUND(variance_component, 4) as variance_value,
    ROUND(contribution_pct, 2) as contribution_percentage,
    CASE
        WHEN contribution_pct > 50 THEN '主导因素'
        WHEN contribution_pct > 20 THEN '重要因素'
        WHEN contribution_pct > 10 THEN '一般因素'
        ELSE '次要因素'
    END as importance_level,
    CURRENT_TIMESTAMP as analysis_time
FROM variance_by_param
ORDER BY contribution_percentage DESC