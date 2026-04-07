-- =============================================
-- 模型名称：dws_ranch_cattle_purchase_agg_1d_d
-- 模型描述：牛只采购日统计表
-- 作者：dbt
-- 创建时间：2026-04-03
-- 粒度：牧场 + 日期
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='ranch_id,stat_date',
    description='牛只采购日统计表，按牧场维度统计每日采购情况',
    tags=['ranch', 'dws', 'agg', 'cattle', 'purchase', 'daily']
) }}

WITH purchase_trx AS (
    SELECT
        ranch_id,
        upstream_customer_id,
        install_date,
        weight,
        total_price
    FROM {{ ref('dwd_ranch_cattle_purchase_trx_i') }}
    WHERE install_date IS NOT NULL
),

purchase_agg AS (
    SELECT
        ranch_id,
        install_date AS stat_date,

        -- 数量统计
        COUNT(*) AS purchase_count,                             -- 采购牛只数
        COUNT(DISTINCT upstream_customer_id) AS supplier_count, -- 供应商数

        -- 重量统计
        SUM(COALESCE(weight, 0)) AS total_weight,               -- 总重量
        AVG(weight) AS avg_weight,                              -- 平均重量

        -- 金额统计
        SUM(COALESCE(total_price, 0)) AS total_amount,          -- 总金额

        -- 单价统计
        CASE WHEN SUM(weight) > 0 THEN SUM(total_price) / SUM(weight) ELSE NULL END AS avg_unit_price,                                  -- 平均单价(元/斤)

        CURRENT_TIMESTAMP AS dw_update_time

    FROM purchase_trx
    GROUP BY ranch_id, install_date
)

SELECT
    p.stat_date,
    p.ranch_id,
    r.ranch_name,
    p.purchase_count,
    p.supplier_count,
    ROUND(p.total_weight, 2) AS total_weight,
    ROUND(p.avg_weight, 2) AS avg_weight,
    ROUND(p.total_amount, 2) AS total_amount,
    ROUND(p.avg_unit_price, 2) AS avg_unit_price,
    p.dw_update_time
FROM purchase_agg p
LEFT JOIN {{ ref('dim_ranch') }} r ON p.ranch_id = r.ranch_id

-- {% if is_incremental() %}
-- WHERE p.stat_date > (SELECT COALESCE(MAX(stat_date), '1900-01-01') FROM {{ this }})
-- {% endif %}
