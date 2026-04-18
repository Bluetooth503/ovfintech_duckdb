-- =============================================
-- 模型名称：dws_ranch_cattle_return_agg_mf
-- 模型描述：牛只退回月度聚合表，按自然月统计退回情况
-- Dbt更新方式：全量
-- 粒度：牧场 + 栏舍 + SKU + 自然月
-- 说明：
--   - 数据源：dwd_ranch_cattle_return_fact_i（DWD层退回明细）+ dim_ranch_cattle（牛只维度表）
--   - 增量策略：全量刷新
--   - 统计指标：退回数量、总重量等退回指标
-- =============================================
{{ config(
    materialized='table',
    description='牛只退回月度聚合表，按牧场+栏舍+SKU+自然月统计退回数量、总重量',
    tags=['ranch', 'dws', 'agg', 'cattle', 'return', 'monthly']
) }}

WITH return_with_dim AS (
    SELECT
        r.cattle_id,
        r.return_date,
        r.return_weight,
        r.ranch_id,
        d.stall_id,
        d.cattle_sku_id AS sku_id
    FROM {{ ref('dwd_ranch_cattle_return_fact_i') }} r
    LEFT JOIN {{ ref('dim_ranch_cattle') }} d ON CAST(r.cattle_id AS VARCHAR) = CAST(d.cattle_id AS VARCHAR) AND d.is_current = '1'
    WHERE r.return_date IS NOT NULL
),

return_detail AS (
    SELECT
        EXTRACT(YEAR FROM return_date) * 100 + EXTRACT(MONTH FROM return_date) AS natural_month,
        ranch_id,
        stall_id,
        sku_id AS cattle_sku_id,
        return_weight
    FROM return_with_dim
)

SELECT
    natural_month,                           -- 自然月
    ranch_id,                                -- 牧场ID
    stall_id,                                -- 栏舍ID
    cattle_sku_id,                           -- SKU ID
    COUNT(*) AS return_count,                -- 退回数量
    SUM(return_weight) AS return_total_weight,  -- 退回总重量
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM return_detail
GROUP BY natural_month, ranch_id, stall_id, cattle_sku_id
ORDER BY natural_month DESC, ranch_id, stall_id, cattle_sku_id
