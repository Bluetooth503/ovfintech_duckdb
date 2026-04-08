-- =============================================
-- 模型名称：ads_ranch_nlme_effects_pivot
-- 模型描述：NLME 固定效应透视表，便于业务查询
-- =============================================
{{ config(
    materialized='table',
    description='NLME 固定效应透视表，展示品种和牧场对生长参数的影响',
    tags=['ranch', 'ads', 'report', 'nlme', 'fixed_effects']
) }}

WITH nlme_results AS (
    SELECT * FROM {{ ref('ads_ranch_cattle_gompertz_nlme') }}
    WHERE result_type = 'fixed_effect'
),

-- 基准参数（截距）
intercepts AS (
    SELECT
        parameter,
        estimate as intercept_value
    FROM nlme_results
    WHERE level = 'intercept'
),

-- 品种效应
sku_effects AS (
    SELECT
        nr.parameter,
        nr.level as sku_name,
        nr.estimate as effect_value,
        nr.std_error,
        nr.ci_lower,
        nr.ci_upper,
        i.intercept_value,
        CASE
            WHEN nr.parameter IN ('log_A', 'log_B') THEN EXP(i.intercept_value + nr.estimate)
            ELSE i.intercept_value + nr.estimate
        END as actual_value
    FROM nlme_results nr
    JOIN intercepts i ON nr.parameter = i.parameter
    WHERE nr.level LIKE 'sku_%'
),

-- 牧场效应
ranch_effects AS (
    SELECT
        nr.parameter,
        nr.level as ranch_name,
        nr.estimate as effect_value,
        nr.std_error,
        nr.ci_lower,
        nr.ci_upper,
        i.intercept_value,
        CASE
            WHEN nr.parameter IN ('log_A', 'log_B') THEN EXP(i.intercept_value + nr.estimate)
            ELSE i.intercept_value + nr.estimate
        END as actual_value
    FROM nlme_results nr
    JOIN intercepts i ON nr.parameter = i.parameter
    WHERE nr.level LIKE 'ranch_%'
)

SELECT
    '品种' as effect_type,
    sku_name as dimension_value,
    parameter as growth_parameter,
    effect_value as fixed_effect_estimate,
    std_error,
    ci_lower,
    ci_upper,
    intercept_value as population_mean,
    actual_value as adjusted_parameter,
    CASE
        WHEN parameter = 'log_A' THEN '成熟体重参数'
        WHEN parameter = 'log_B' THEN '生长速率参数'
        WHEN parameter = 'C' THEN '拐点日龄参数'
    END as parameter_description,
    CURRENT_TIMESTAMP as update_time
FROM sku_effects

UNION ALL

SELECT
    '牧场' as effect_type,
    ranch_name as dimension_value,
    parameter as growth_parameter,
    effect_value as fixed_effect_estimate,
    std_error,
    ci_lower,
    ci_upper,
    intercept_value as population_mean,
    actual_value as adjusted_parameter,
    CASE
        WHEN parameter = 'log_A' THEN '成熟体重参数'
        WHEN parameter = 'log_B' THEN '生长速率参数'
        WHEN parameter = 'C' THEN '拐点日龄参数'
    END as parameter_description,
    CURRENT_TIMESTAMP as update_time
FROM ranch_effects

ORDER BY effect_type, growth_parameter, fixed_effect_estimate DESC