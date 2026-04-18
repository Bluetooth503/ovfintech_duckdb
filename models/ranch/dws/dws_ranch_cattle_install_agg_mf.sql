-- =============================================
-- 模型名称：dws_ranch_cattle_install_agg_mf
-- 模型描述：牛只入栏月度聚合表，按自然月统计入栏情况
-- Dbt更新方式：全量
-- 粒度：牧场 + 栏舍 + SKU + 自然月
-- 说明：
--   - 数据源：dwd_ranch_cattle_install_fact_i（DWD层入栏明细）
--   - 增量策略：全量刷新
--   - 统计指标：入栏数量、总重量、平均重量等入栏指标
-- =============================================
{{ config(
    materialized='table',
    description='牛只入栏月度聚合表，按牧场+栏舍+SKU+自然月统计入栏数量、总重量、平均重量',
    tags=['ranch', 'dws', 'agg', 'cattle', 'install', 'monthly']
) }}

WITH install_detail AS (
    SELECT
        EXTRACT(YEAR FROM install_date) * 100 + EXTRACT(MONTH FROM install_date) AS natural_month,
        tenant_id AS ranch_id,
        stall_id,
        sku_id AS cattle_sku_id,
        weight
    FROM {{ ref('dwd_ranch_cattle_install_fact_i') }}
    WHERE install_date IS NOT NULL
)

SELECT
    natural_month,                           -- 自然月
    ranch_id,                                -- 牧场ID
    stall_id,                                -- 栏舍ID
    cattle_sku_id,                           -- SKU ID
    COUNT(*) AS install_count,               -- 入栏数量
    SUM(weight) AS install_total_weight,     -- 入栏总重量
    AVG(weight) AS install_avg_weight,       -- 入栏平均重量
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM install_detail
GROUP BY natural_month, ranch_id, stall_id, cattle_sku_id
ORDER BY natural_month DESC, ranch_id, stall_id, cattle_sku_id
