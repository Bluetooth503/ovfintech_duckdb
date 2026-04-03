-- =============================================
-- 模型名称：dwd_ranch_cattle_weight_trx_i
-- 模型描述：牧场域牛只体重测量事务明细表，记录牛只体重测量的原子事件
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只体重测量事务明细表，记录每次体重测量事件的原子数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'weight', 'measure']
) }}

WITH src_weight AS (
    SELECT
        id,
        livestock_id AS cattle_id,             -- 牛只ID
        weight_date,                           -- 测量日期
        CAST(weight AS DOUBLE) AS weight,      -- 测量体重
        weight_day_age AS day_age,             -- 日龄
        weight_days,                           -- 测量天数
        stall_id,                              -- 栏舍ID
        code AS measure_code,                  -- 测量编码
        CAST(daily_gain AS DOUBLE) AS daily_gain,  -- 日增重（业务系统预计算字段）
        investor_id AS customer_id,            -- 客户ID
        type AS measure_type,                  -- 测量类型（1=初测，2=复测）
        ai_score,                              -- AI评分
        remark,                                -- 备注
        create_time,                           -- 创建时间
        update_time                            -- 更新时间
    FROM {{ ref('ods_psi_sample_weight') }}
    -- 过滤无效体重数据
    WHERE CAST(weight AS DOUBLE) > 0
)

SELECT
    id,                                 -- 事务ID
    cattle_id,                          -- 牛只ID
    weight_date,                        -- 测量日期
    weight,                             -- 测量体重
    day_age,                            -- 日龄
    weight_days,                        -- 测量天数
    daily_gain,                         -- 日增重（业务系统预计算字段）
    stall_id,                           -- 栏舍ID
    measure_code,                       -- 测量编码
    customer_id,                        -- 客户ID
    measure_type,                       -- 测量类型（1=初测，2=复测）
    ai_score,                           -- AI评分
    remark,                             -- 备注
    create_time,                        -- 创建时间
    update_time                         -- 更新时间
FROM src_weight

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
