-- =============================================
-- 模型名称：dwd_ranch_cattle_weight_trx_i
-- 模型描述：牧场域牛只体重测量事务明细表，记录牛只体重测量的原子事件
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只体重测量事务明细表，记录每次体重测量事件的原子数据（增量追加）。入栏/出栏体重作为补充称重记录注入',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'weight', 'measure']
) }}

-- ============================================
-- 1. 日常称重记录（原始数据源）
-- ============================================
WITH src_weight AS (
    SELECT
        id::VARCHAR AS id,
        livestock_id AS cattle_id,                      -- 牛只ID
        weight_date,                                    -- 测量日期
        CAST(weight AS DOUBLE) AS weight,               -- 测量体重
        weight_day_age AS day_age,                      -- 日龄
        weight_days,                                    -- 测量天数
        stall_id,                                       -- 栏舍ID
        code AS measure_code,                           -- 测量编码
        CAST(daily_gain AS DOUBLE) AS daily_gain,       -- 日增重（业务系统预计算字段）
        investor_id AS customer_id,                     -- 客户ID
        type AS measure_type,                           -- 测量类型（1=初测，2=复测）
        ai_score,                                       -- AI评分
        remark,                                         -- 备注
        create_time,                                    -- 创建时间
        update_time                                     -- 更新时间
    FROM {{ ref('ods_psi_sample_weight') }}
    WHERE CAST(weight AS DOUBLE) > 0
),

-- ============================================
-- 2. 牛只维度（用于 cattle_code → cattle_id 映射和 stall_id 补充）
-- ============================================
lkp_cattle AS (
    SELECT
        cattle_id,
        cattle_code,
        stall_id
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- 3. 入栏体重（补充生长起点数据）
--    一致性过滤：入栏重量 <= 后续第一次日常称重 + 容差，否则不注入
-- ============================================
src_install_weight AS (
    SELECT
        'INSTALL_' || p.install_id::VARCHAR AS id,
        c.cattle_id::VARCHAR AS cattle_id,
        p.install_date AS weight_date,
        p.weight,
        NULL::BIGINT AS day_age,
        NULL::BIGINT AS weight_days,
        c.stall_id,
        NULL::VARCHAR AS measure_code,
        NULL::DOUBLE AS daily_gain,
        p.customer_id::VARCHAR AS customer_id,
        3::BIGINT AS measure_type,             -- 3=入栏称重
        NULL::VARCHAR AS ai_score,
        '入栏称重' AS remark,
        p.create_time,
        p.update_time
    FROM {{ ref('dwd_ranch_cattle_purchase_trx_i') }} p
    INNER JOIN lkp_cattle c ON CAST(p.cattle_code AS VARCHAR) = CAST(c.cattle_code AS VARCHAR)
    WHERE p.weight > 0
      AND c.cattle_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM src_weight w
          WHERE w.cattle_id = c.cattle_id AND w.weight_date = p.install_date
      )
      -- 一致性过滤：无后续日常称重则保留，否则入栏重量不能大幅高于后续称重
      AND (
          NOT EXISTS (SELECT 1 FROM src_weight w WHERE w.cattle_id = c.cattle_id AND w.weight_date > p.install_date)
          OR p.weight <= (
              SELECT w.weight FROM src_weight w
              WHERE w.cattle_id = c.cattle_id AND w.weight_date > p.install_date
              ORDER BY w.weight_date LIMIT 1
          ) + 20
      )
),

-- ============================================
-- 4. 出栏体重（补充生长终点数据）
--    一致性过滤：出栏重量 >= 前一次日常称重 - 容差，否则不注入
-- ============================================
src_outstall_weight AS (
    SELECT
        'OUTSTALL_' || o.id::VARCHAR AS id,
        o.cattle_id::VARCHAR AS cattle_id,
        o.outstall_date AS weight_date,
        o.weight,
        NULL::BIGINT AS day_age,
        NULL::BIGINT AS weight_days,
        c.stall_id,
        NULL::VARCHAR AS measure_code,
        NULL::DOUBLE AS daily_gain,
        o.customer_id::VARCHAR AS customer_id,
        4::BIGINT AS measure_type,             -- 4=出栏称重
        NULL::VARCHAR AS ai_score,
        '出栏称重' AS remark,
        o.create_time,
        o.update_time
    FROM {{ ref('dwd_ranch_cattle_outstall_trx_i') }} o
    INNER JOIN lkp_cattle c ON CAST(o.cattle_id AS VARCHAR) = CAST(c.cattle_id AS VARCHAR)
    WHERE o.weight > 0
      AND NOT EXISTS (
          SELECT 1 FROM src_weight w
          WHERE w.cattle_id = o.cattle_id AND w.weight_date = o.outstall_date
      )
      -- 一致性过滤：无前置日常称重则保留，否则出栏重量不能大幅低于前置称重
      AND (
          NOT EXISTS (SELECT 1 FROM src_weight w WHERE w.cattle_id = o.cattle_id AND w.weight_date < o.outstall_date)
          OR o.weight >= (
              SELECT w.weight FROM src_weight w
              WHERE w.cattle_id = o.cattle_id AND w.weight_date < o.outstall_date
              ORDER BY w.weight_date DESC LIMIT 1
          ) - 20
      )
)

SELECT
    id,                                      -- 事务ID
    cattle_id,                               -- 牛只ID
    weight_date,                             -- 测量日期
    weight,                                  -- 测量体重
    day_age,                                 -- 日龄
    weight_days,                             -- 测量天数
    daily_gain,                              -- 日增重（业务系统预计算字段）
    stall_id,                                -- 栏舍ID
    measure_code,                            -- 测量编码
    customer_id,                             -- 客户ID
    measure_type,                            -- 测量类型（1=初测，2=复测，3=入栏，4=出栏）
    ai_score,                                -- AI评分
    remark,                                  -- 备注
    create_time,                             -- 创建时间
    update_time                              -- 更新时间
FROM src_weight

UNION ALL

SELECT
    id,
    cattle_id,
    weight_date,
    weight,
    day_age,
    weight_days,
    daily_gain,
    stall_id,
    measure_code,
    customer_id,
    measure_type,
    ai_score,
    remark,
    create_time,
    update_time
FROM src_install_weight

UNION ALL

SELECT
    id,
    cattle_id,
    weight_date,
    weight,
    day_age,
    weight_days,
    daily_gain,
    stall_id,
    measure_code,
    customer_id,
    measure_type,
    ai_score,
    remark,
    create_time,
    update_time
FROM src_outstall_weight

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
