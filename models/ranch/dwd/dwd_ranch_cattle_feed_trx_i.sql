-- =============================================
-- 模型名称：dwd_ranch_cattle_feed_trx_i
-- 模型描述：牧场域牛只投喂事务明细表，记录牛只饲料投喂的增量交易数据
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只投喂事务明细表，记录牛只饲料投喂数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'feed']
) }}

WITH src_feed AS (
    SELECT
        id,
        livestock_id AS cattle_id,             -- 牛只ID
        stall_id,                              -- 栏舍ID
        commodity_id AS feed_sku_id,           -- 商品ID（饲料）
        commodity_name AS feed_sku_name,       -- 商品名称
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,  -- 实际投喂量
        CAST(act_cost AS DOUBLE) AS act_feed_cost,          -- 实际投喂成本
        date::DATE AS feed_date,               -- 投喂日期
        date AS create_time,                   -- 创建时间（使用投喂日期）
        date AS update_time                    -- 更新时间（使用投喂日期）
    FROM {{ ref('ods_psi_cattle_feed_detail') }}
    -- 过滤无效数据（放宽条件：允许0值，只过滤完全无效的记录）
    WHERE date IS NOT NULL
)

SELECT
    id,                                       -- 事务ID
    cattle_id,                                -- 牛只ID
    stall_id,                                 -- 栏舍ID
    feed_sku_id,                              -- 商品ID（饲料）
    feed_sku_name,                            -- 商品名称
    feed_date,                                -- 投喂日期
    act_feed_quantity,                        -- 实际投喂量
    act_feed_cost,                            -- 实际投喂成本
    create_time,                              -- 创建时间
    update_time                               -- 更新时间
FROM src_feed

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
