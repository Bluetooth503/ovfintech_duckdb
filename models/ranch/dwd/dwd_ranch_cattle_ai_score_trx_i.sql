-- =============================================
-- 模型名称：dwd_ranch_cattle_ai_score_trx_i
-- 模型描述：牧场域牛只AI评分事务明细表，记录牛只AI评分的增量数据
-- 作者：dbt
-- 创建时间：2026-04-03
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只AI评分事务明细表，记录牛只AI评分数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'ai_score']
) }}

WITH src_ai_score AS (
    SELECT
        id,                                             -- 事务ID
        cattle_code,                                    -- 牛只编号
        CAST(weight AS DOUBLE) AS weight,               -- 当前体重
        score,                                          -- 综合评分
        CAST(hair AS DOUBLE) AS hair,                   -- 毛发评分
        CAST(muscle AS DOUBLE) AS muscle,               -- 肌肉评分
        variety_name,                                   -- 品类名称
        CAST(out_stall_weight AS DOUBLE) AS out_stall_weight,  -- 预估出栏体重
        CAST(feed_ratio AS DOUBLE) AS feed_ratio,       -- 料肉比
        is_submit,                                      -- 是否提交
        score_record_count,                             -- 评分记录条数
        gender,                                         -- 性别
        address,                                        -- 地址
        create_time::timestamp AS create_time,          -- 创建时间
        COALESCE(update_time::timestamp, create_time::timestamp) AS update_time  -- 更新时间
    FROM {{ ref('ods_psi_cattle_ai_score_result') }}
    WHERE create_time IS NOT NULL
)

SELECT
    id,                                             -- 事务ID
    cattle_code,                                    -- 牛只编号
    weight,                                         -- 当前体重
    score,                                          -- 综合评分
    hair,                                           -- 毛发评分
    muscle,                                         -- 肌肉评分
    variety_name,                                   -- 品类名称
    out_stall_weight,                               -- 预估出栏体重
    feed_ratio,                                     -- 料肉比
    is_submit,                                      -- 是否提交
    score_record_count,                             -- 评分记录条数
    gender,                                         -- 性别
    address,                                        -- 地址
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM src_ai_score

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
