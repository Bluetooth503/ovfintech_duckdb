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
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_3') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_4') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_5') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_6') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_7') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_8') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_9') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_10') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_11') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_12') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_13') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_14') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_15') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_16') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_17') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_18') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_19') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_20') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_21') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_22') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_23') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_24') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_25') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_26') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_27') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_28') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_29') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_30') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_31') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_32') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_33') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_34') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_35') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_36') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_37') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_38') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_39') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_40') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_41') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_42') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_43') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_44') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_45') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_46') }}
    WHERE date IS NOT NULL

    UNION ALL

    SELECT
        id,
        livestock_id AS cattle_id,
        stall_id,
        commodity_id AS feed_sku_id,
        commodity_name AS feed_sku_name,
        CAST(act_quantity AS DOUBLE) AS act_feed_quantity,
        CAST(act_cost AS DOUBLE) AS act_feed_cost,
        date::DATE AS feed_date,
        date AS create_time,
        date AS update_time
    FROM {{ ref('ods_psi_cattle_feed_detail_47') }}
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
