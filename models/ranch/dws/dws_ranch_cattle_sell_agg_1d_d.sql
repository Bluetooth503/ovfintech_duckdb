-- =============================================
-- 模型名称：dws_ranch_cattle_sell_agg_1d_d
-- 模型描述：牛只销售日统计表
-- 作者：dbt
-- 创建时间：2026-04-03
-- 粒度：牧场 + 日期
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='ranch_id,stat_date',
    description='牛只销售日统计表，按牧场维度统计每日销售情况',
    tags=['ranch', 'dws', 'agg', 'cattle', 'sell', 'daily']
) }}

WITH sell_trx AS (
    SELECT
        ranch_id,
        downstream_customer_id,
        sell_date,
        outstall_date,
        weight,
        total_amount,
        out_type,
        loan_amount
    FROM {{ ref('dwd_ranch_cattle_sell_trx_i') }}
    WHERE sell_date IS NOT NULL
),

sell_agg AS (
    SELECT
        ranch_id,
        sell_date AS stat_date,

        -- 数量统计
        COUNT(*) AS sell_count,                                -- 销售牛只数
        COUNT(DISTINCT downstream_customer_id) AS buyer_count, -- 买家数

        -- 重量统计
        SUM(COALESCE(weight, 0)) AS total_weight,              -- 总重量
        AVG(weight) AS avg_weight,                             -- 平均重量

        -- 金额统计
        SUM(COALESCE(total_amount, 0)) AS total_sell_amount,   -- 总销售金额
        SUM(COALESCE(loan_amount, 0)) AS total_loan_repay,     -- 总还款金额

        -- 单价统计
        CASE
            WHEN SUM(weight) > 0
            THEN SUM(total_amount) / SUM(weight)
            ELSE NULL
        END AS avg_unit_price,                                 -- 平均单价(元/斤)

        -- 出栏类型分布
        SUM(CASE WHEN out_type = 1 THEN 1 ELSE 0 END) AS normal_sell_count,    -- 正常销售
        SUM(CASE WHEN out_type = 2 THEN 1 ELSE 0 END) AS death_count,          -- 死亡
        SUM(CASE WHEN out_type = 3 THEN 1 ELSE 0 END) AS loss_count,           -- 丢失

        CURRENT_TIMESTAMP AS dw_update_time

    FROM sell_trx
    GROUP BY ranch_id, sell_date
)

SELECT
    s.stat_date,
    s.ranch_id,
    r.ranch_name,
    s.sell_count,
    s.buyer_count,
    ROUND(s.total_weight, 2) AS total_weight,
    ROUND(s.avg_weight, 2) AS avg_weight,
    ROUND(s.total_sell_amount, 2) AS total_sell_amount,
    ROUND(s.total_loan_repay, 2) AS total_loan_repay,
    ROUND(s.avg_unit_price, 2) AS avg_unit_price,
    s.normal_sell_count,
    s.death_count,
    s.loss_count,
    s.dw_update_time
FROM sell_agg s
LEFT JOIN {{ ref('dim_ranch') }} r ON s.ranch_id = r.ranch_id

{% if is_incremental() %}
WHERE s.stat_date > (SELECT COALESCE(MAX(stat_date), '1900-01-01') FROM {{ this }})
{% endif %}
