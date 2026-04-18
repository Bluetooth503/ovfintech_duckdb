-- =============================================
-- 模型名称：dws_ranch_ai_score_agg_di
-- 模型描述：AI评分日统计表，按日期统计牛只AI评分指标
-- Dbt更新方式：增量（按日期）
-- 粒度：牧场 + 栏舍 + 品种 + 客户 + 日期
-- 说明：
--   - 数据源：dwd_ranch_cattle_ai_score_fact_i（DWD层AI评分明细）+ dim_ranch_cattle（牛只维度表）
--   - 增量策略：按日期追加
--   - 统计指标：AI评分、被毛评分、肌肉评分、出栏体重预测、等级分布等AI指标
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['score_date'],
    description='AI评分日统计表，按日期统计牛只的AI评分指标（体况评分、等级分布等）',
    tags=['ranch', 'dws', 'agg', 'ai', 'score', 'daily']
) }}

WITH ai_score_trx AS (
    -- 从AI评分事务表获取评分数据
    SELECT
        CAST(create_time AS DATE) AS score_date,
        cattle_code,
        NULL AS stall_id,
        NULL AS ranch_id,
        NULL AS customer_id,

        -- AI评分相关
        CAST(score AS DOUBLE) AS ai_score,
        CAST(hair AS DOUBLE) AS hair,
        CAST(muscle AS DOUBLE) AS muscle,
        out_stall_weight,

        -- 体重相关
        weight,

        -- 测量类型
        is_submit,
        score_record_count

    FROM {{ ref('dwd_ranch_cattle_ai_score_fact_i') }}
    WHERE create_time IS NOT NULL
),

cattle_dim AS (
    -- 从牛只维度获取完整维度信息（包含栏舍名称、牧场名称、品种信息）
    SELECT
        cattle_id,
        cattle_code,
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        customer_id
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- 关联维度信息
ai_score_with_dim AS (
    SELECT
        t.score_date,
        c.cattle_id,
        c.stall_id,
        c.stall_name,
        c.ranch_id,
        c.ranch_name,
        c.customer_id,
        t.ai_score,
        t.hair,
        t.muscle,
        t.out_stall_weight,
        t.weight,
        t.is_submit,
        t.score_record_count,
        c.cattle_sku_id,
        c.cattle_sku_name,
        c.brand_name,

        -- 计算自然周和自然月
        EXTRACT(YEAR FROM t.score_date) * 100 + EXTRACT(WEEK FROM t.score_date) AS natural_week,
        EXTRACT(YEAR FROM t.score_date) * 100 + EXTRACT(MONTH FROM t.score_date) AS natural_month

    FROM ai_score_trx t
    LEFT JOIN cattle_dim c ON t.cattle_code::VARCHAR = c.cattle_code::VARCHAR
),

-- 按牧场 + 栏舍 + 日期维度聚合
ai_score_daily AS (
    SELECT
        score_date,
        natural_week,
        natural_month,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        customer_id,

        -- ====================
        -- 数量统计
        -- ====================
        COUNT(DISTINCT cattle_id) AS total_scored_cattle,     -- 本日评分牛只总数

        -- ====================
        -- AI评分统计
        -- ====================
        AVG(ai_score) AS avg_ai_score,                       -- 平均AI评分
        MIN(ai_score) AS min_ai_score,                       -- 最低AI评分
        MAX(ai_score) AS max_ai_score,                       -- 最高AI评分
        STDDEV(ai_score) AS stddev_ai_score,                 -- AI评分标准差

        -- AI评分分布（按等级）
        COUNT(DISTINCT CASE WHEN ai_score >= 90 THEN cattle_id END) AS count_score_a,          -- A级（90分以上）
        COUNT(DISTINCT CASE WHEN ai_score >= 80 AND ai_score < 90 THEN cattle_id END) AS count_score_b,  -- B级（80-89分）
        COUNT(DISTINCT CASE WHEN ai_score >= 70 AND ai_score < 80 THEN cattle_id END) AS count_score_c,  -- C级（70-79分）
        COUNT(DISTINCT CASE WHEN ai_score >= 60 AND ai_score < 70 THEN cattle_id END) AS count_score_d,  -- D级（60-69分）
        COUNT(DISTINCT CASE WHEN ai_score < 60 THEN cattle_id END) AS count_score_e,           -- E级（60分以下）

        -- ====================
        -- 被毛评分统计
        -- ====================
        AVG(hair) AS avg_hair_score,                         -- 平均被毛评分
        MIN(hair) AS min_hair_score,
        MAX(hair) AS max_hair_score,

        -- 被毛评分分布
        COUNT(DISTINCT CASE WHEN hair >= 4.5 THEN cattle_id END) AS count_hair_excellent,     -- 优秀（4.5分以上）
        COUNT(DISTINCT CASE WHEN hair >= 4.0 AND hair < 4.5 THEN cattle_id END) AS count_hair_good,  -- 良好（4.0-4.4分）
        COUNT(DISTINCT CASE WHEN hair >= 3.5 AND hair < 4.0 THEN cattle_id END) AS count_hair_fair,  -- 中等（3.5-3.9分）
        COUNT(DISTINCT CASE WHEN hair < 3.5 THEN cattle_id END) AS count_hair_poor,           -- 较差（3.5分以下）

        -- ====================
        -- 肌肉评分统计
        -- ====================
        AVG(muscle) AS avg_muscle_score,                     -- 平均肌肉评分
        MIN(muscle) AS min_muscle_score,
        MAX(muscle) AS max_muscle_score,

        -- 肌肉评分分布
        COUNT(DISTINCT CASE WHEN muscle >= 4.5 THEN cattle_id END) AS count_muscle_excellent, -- 优秀（4.5分以上）
        COUNT(DISTINCT CASE WHEN muscle >= 4.0 AND muscle < 4.5 THEN cattle_id END) AS count_muscle_good, -- 良好（4.0-4.4分）
        COUNT(DISTINCT CASE WHEN muscle >= 3.5 AND muscle < 4.0 THEN cattle_id END) AS count_muscle_fair, -- 中等（3.5-3.9分）
        COUNT(DISTINCT CASE WHEN muscle < 3.5 THEN cattle_id END) AS count_muscle_poor,       -- 较差（3.5分以下）

        -- ====================
        -- 出栏体重预测统计
        -- ====================
        AVG(out_stall_weight) AS avg_out_stall_weight,        -- 平均预测出栏体重
        MIN(out_stall_weight) AS min_out_stall_weight,        -- 最小预测出栏体重
        MAX(out_stall_weight) AS max_out_stall_weight,        -- 最大预测出栏体重

        -- 出栏体重预测分布
        COUNT(DISTINCT CASE WHEN out_stall_weight < 400 THEN cattle_id END) AS count_out_weight_under_400,
        COUNT(DISTINCT CASE WHEN out_stall_weight >= 400 AND out_stall_weight < 500 THEN cattle_id END) AS count_out_weight_400_500,
        COUNT(DISTINCT CASE WHEN out_stall_weight >= 500 AND out_stall_weight < 600 THEN cattle_id END) AS count_out_weight_500_600,
        COUNT(DISTINCT CASE WHEN out_stall_weight >= 600 AND out_stall_weight < 700 THEN cattle_id END) AS count_out_weight_600_700,
        COUNT(DISTINCT CASE WHEN out_stall_weight >= 700 THEN cattle_id END) AS count_out_weight_over_700,

        -- ====================
        -- 体重统计
        -- ====================
        AVG(weight) AS avg_weight,                           -- 平均体重
        SUM(weight) AS total_weight,                         -- 总重量

        CURRENT_TIMESTAMP AS dw_update_time

    FROM ai_score_with_dim
    GROUP BY
        score_date,
        natural_week,
        natural_month,
        ranch_id, ranch_name,
        stall_id, stall_name,
        cattle_sku_id, cattle_sku_name, brand_name,
        customer_id
)

SELECT
    -- ====================
    -- 维度字段
    -- ====================
    score_date,
    natural_week,
    natural_month,
    ranch_id,
    ranch_name,
    stall_id,
    stall_name,
    cattle_sku_id,
    cattle_sku_name,
    brand_name,
    customer_id,

    -- ====================
    -- 数量统计
    -- ====================
    total_scored_cattle,

    -- ====================
    -- AI评分统计（四舍五入保留2位小数）
    -- ====================
    ROUND(avg_ai_score, 2) AS avg_ai_score,
    ROUND(min_ai_score, 2) AS min_ai_score,
    ROUND(max_ai_score, 2) AS max_ai_score,
    ROUND(stddev_ai_score, 2) AS stddev_ai_score,

    -- AI评分分布
    count_score_a,
    count_score_b,
    count_score_c,
    count_score_d,
    count_score_e,

    -- 评分等级占比
    ROUND(CAST(count_score_a AS DOUBLE) / NULLIF(total_scored_cattle, 0) * 100, 2) AS pct_score_a,
    ROUND(CAST(count_score_b AS DOUBLE) / NULLIF(total_scored_cattle, 0) * 100, 2) AS pct_score_b,
    ROUND(CAST(count_score_c AS DOUBLE) / NULLIF(total_scored_cattle, 0) * 100, 2) AS pct_score_c,
    ROUND(CAST(count_score_d AS DOUBLE) / NULLIF(total_scored_cattle, 0) * 100, 2) AS pct_score_d,
    ROUND(CAST(count_score_e AS DOUBLE) / NULLIF(total_scored_cattle, 0) * 100, 2) AS pct_score_e,

    -- ====================
    -- 被毛评分统计（四舍五入保留2位小数）
    -- ====================
    ROUND(avg_hair_score, 2) AS avg_hair_score,
    ROUND(min_hair_score, 2) AS min_hair_score,
    ROUND(max_hair_score, 2) AS max_hair_score,

    -- 被毛评分分布
    count_hair_excellent,
    count_hair_good,
    count_hair_fair,
    count_hair_poor,

    -- ====================
    -- 肌肉评分统计（四舍五入保留2位小数）
    -- ====================
    ROUND(avg_muscle_score, 2) AS avg_muscle_score,
    ROUND(min_muscle_score, 2) AS min_muscle_score,
    ROUND(max_muscle_score, 2) AS max_muscle_score,

    -- 肌肉评分分布
    count_muscle_excellent,
    count_muscle_good,
    count_muscle_fair,
    count_muscle_poor,

    -- ====================
    -- 出栏体重预测统计（四舍五入保留2位小数）
    -- ====================
    ROUND(avg_out_stall_weight, 2) AS avg_out_stall_weight,
    ROUND(min_out_stall_weight, 2) AS min_out_stall_weight,
    ROUND(max_out_stall_weight, 2) AS max_out_stall_weight,

    -- 出栏体重预测分布
    count_out_weight_under_400,
    count_out_weight_400_500,
    count_out_weight_500_600,
    count_out_weight_600_700,
    count_out_weight_over_700,

    -- ====================
    -- 体重统计（四舍五入保留2位小数）
    -- ====================
    ROUND(avg_weight, 2) AS avg_weight,
    ROUND(total_weight, 2) AS total_weight,

    dw_update_time

FROM ai_score_daily

-- {% if is_incremental() %}
-- WHERE score_date > (SELECT COALESCE(MAX(score_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}

ORDER BY score_date DESC, ranch_id, stall_id
