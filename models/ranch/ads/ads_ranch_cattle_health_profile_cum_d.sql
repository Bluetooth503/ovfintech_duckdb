-- =============================================
-- 模型名称：ads_ranch_cattle_health_profile_cum_d
-- 模型描述：牛只健康画像宽表（至今），每头牛一条记录，汇总最新生长指标、AI评分、健康等级标签
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- =============================================
{{ config(
    materialized='table',
    description='牛只健康画像宽表（至今），汇总每头牛的最新生长指标、AI评分、健康等级标签',
    tags=['ranch', 'ads', 'health', 'cattle', 'profile']
) }}

WITH cattle_base AS (
    SELECT
        cattle_id,
        cattle_code AS cattle_no,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        birth_date,
        in_stall_date,
        in_stall_weight,
        cattle_status AS dim_cattle_status
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

latest_adg AS (
    SELECT
        cattle_id,
        stats_date AS latest_adg_date,
        current_weight AS latest_weight,
        period_adg,
        overall_adg
    FROM (
        SELECT
            cattle_id, stats_date, current_weight, period_adg, overall_adg,
            ROW_NUMBER() OVER (PARTITION BY cattle_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_cattle_adg_fcr_i') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

integrated AS (
    SELECT
        b.cattle_id,
        b.cattle_no,
        b.ranch_id,
        b.ranch_name,
        b.stall_id,
        b.stall_name,
        b.cattle_sku_id,
        b.cattle_sku_name,
        b.brand_name,
        b.birth_date,
        b.in_stall_date,
        b.in_stall_weight,
        b.dim_cattle_status,
        a.latest_weight,
        a.latest_adg_date,
        a.period_adg,
        a.overall_adg,
        CURRENT_TIMESTAMP AS dw_update_time
    FROM cattle_base b
    LEFT JOIN latest_adg a ON b.cattle_id::VARCHAR = a.cattle_id::VARCHAR
)

SELECT
    cattle_id,
    cattle_no,
    ranch_id,
    ranch_name,
    stall_id,
    stall_name,
    cattle_sku_id,
    cattle_sku_name,
    brand_name,
    birth_date,
    in_stall_date,
    in_stall_weight,
    dim_cattle_status,
    latest_weight,
    latest_adg_date,
    period_adg,
    overall_adg,
    dw_update_time
FROM integrated
ORDER BY ranch_id, stall_id, cattle_id
