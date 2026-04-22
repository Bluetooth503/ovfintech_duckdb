-- =============================================
-- 模型名称：dws_ranch_cattle_price_state_df
-- 模型描述：活牛价格当前状态表，记录每个牧场每个SKU的最新市场单价
-- Dbt更新方式：全量
-- 粒度：牧场 + SKU
-- 说明：
--   - 数据源：dwd_ranch_cattle_price_fact_i（DWD层价格明细）
--   - 更新策略：每日全量覆盖，计算最新价格状态，不保留历史数据
--   - 统计指标：最新市场单价、价格生效日期、适用体重区间等价格指标
--   - 聚合逻辑：按牧场+SKU取价格生效日期最新的记录
--   - 命名说明：_state_df 表示当前价格状态快照，日全量覆盖，不保留历史
-- =============================================
{{ config(
    materialized='table',
    description='活牛价格当前状态表，记录每个牧场每个SKU的最新市场单价、价格生效日期及适用体重区间',
    tags=['ranch', 'dws', 'state', 'cattle', 'price', 'latest']
) }}

WITH price_ranked AS (
    SELECT
        ranch_id,
        sku_id AS cattle_sku_id,
        unit_price AS latest_unit_price,
        price_change_date AS latest_price_date,
        start_weight AS price_start_weight,
        end_weight AS price_end_weight,
        ROW_NUMBER() OVER (PARTITION BY ranch_id, sku_id ORDER BY price_change_date DESC, update_time DESC) AS rn  -- 取牧场+SKU最新价格
    FROM {{ ref('dwd_ranch_cattle_price_fact_i') }}
)

SELECT
    ranch_id,                                -- 牧场ID
    cattle_sku_id,                           -- SKU ID
    latest_unit_price,                       -- 最新市场单价(元/斤)
    latest_price_date,                       -- 最新价格生效日期
    price_start_weight,                      -- 适用起始体重
    price_end_weight,                        -- 适用结束体重
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM price_ranked
WHERE rn = 1
ORDER BY ranch_id, cattle_sku_id
