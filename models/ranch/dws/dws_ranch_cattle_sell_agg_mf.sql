-- =============================================
-- 模型名称：dws_ranch_cattle_sell_agg_mf
-- 模型描述：牛只出栏月度聚合表，按自然月统计出栏情况
-- Dbt更新方式：全量
-- 粒度：牧场 + 栏舍 + SKU + 自然月
-- 说明：
--   - 数据源：dwd_ranch_cattle_sell_fact_i（DWD层出栏明细）
--   - 增量策略：全量刷新
--   - 统计指标：出栏数量、总重量、平均重量、销售金额等出栏指标
-- =============================================
{{ config(
    materialized='table',
    description='牛只出栏月度聚合表，按牧场+栏舍+SKU+自然月统计出栏数量、总重量、平均重量、销售金额',
    tags=['ranch', 'dws', 'agg', 'cattle', 'sell', 'monthly']
) }}

WITH sell_detail AS (
    SELECT
        EXTRACT(YEAR FROM sell_date) * 100 + EXTRACT(MONTH FROM sell_date) AS natural_month,
        ranch_id,
        stall_id,
        sku_id AS cattle_sku_id,
        weight,
        total_amount
    FROM {{ ref('dwd_ranch_cattle_sell_fact_i') }}
    WHERE sell_date IS NOT NULL
)

SELECT
    natural_month,                           -- 自然月
    ranch_id,                                -- 牧场ID
    stall_id,                                -- 栏舍ID
    cattle_sku_id,                           -- SKU ID
    COUNT(*) AS sell_count,                  -- 出栏数量
    SUM(weight) AS sell_total_weight,        -- 出栏总重量
    AVG(weight) AS sell_avg_weight,          -- 出栏平均重量
    SUM(total_amount) AS sell_total_amount,  -- 销售总额
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM sell_detail
GROUP BY natural_month, ranch_id, stall_id, cattle_sku_id
ORDER BY natural_month DESC, ranch_id, stall_id, cattle_sku_id
