-- =============================================
-- 模型名称：dws_ranch_cattle_sell_agg_df
-- 模型描述：牛只出栏聚合表（cattle-level），汇总每头已出栏牛的销售信息
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：dwd_ranch_cattle_sell_fact_i（DWD层出栏明细）
--   - 增量策略：全量刷新
--   - 统计指标：出栏日期、出栏体重、销售单价、销售总额、买家信息等出栏指标
-- =============================================
{{ config(
    materialized='table',
    description='牛只出栏聚合表，按牛只ID汇总出栏日期、体重、价格、金额及买家信息',
    tags=['ranch', 'dws', 'agg', 'cattle', 'sell']
) }}

WITH sell_detail AS (
    SELECT
        cattle_id,
        outstall_date AS sell_date,
        weight AS sell_weight,
        price AS sell_price,
        total_amount AS sell_total_amount,
        downstream_customer_id AS sell_buyer_id,
        ranch_id AS sell_ranch_id,
        stall_id AS sell_stall_id,
        sku_id AS sell_sku_id,
        out_type
    FROM {{ ref('dwd_ranch_cattle_sell_fact_i') }}
    WHERE cattle_id IS NOT NULL
)

SELECT
    cattle_id,                               -- 牛只ID
    sell_date,                               -- 出栏日期
    sell_weight,                             -- 出栏体重
    sell_price,                              -- 销售单价
    sell_total_amount,                       -- 销售总额
    sell_buyer_id,                           -- 买家ID
    sell_ranch_id,                           -- 出栏牧场ID
    sell_stall_id,                           -- 出栏栏舍ID
    sell_sku_id,                             -- 出栏SKU ID
    out_type,                                -- 出栏类型
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM sell_detail
ORDER BY cattle_id
