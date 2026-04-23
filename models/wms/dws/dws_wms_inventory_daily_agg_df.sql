-- =============================================
-- 模型名称：dws_wms_inventory_daily_agg_df
-- 模型描述：库存日聚合表，按仓库+SKU+批次+客户+日期维度汇总库存指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date + warehouse_id + sku_id + batch_no + customer_id + tenant_id
-- 说明：
--   - 数据源：dwd_wms_inventory_snap_df（库存日快照）
--   - 核心指标：库存计费数量、库存重量、库存货值、冻结/锁定数量
-- =============================================
{{ config(
    materialized='table',
    description='库存日聚合表，按仓库+SKU+批次+客户+日期维度汇总库存指标',
    tags=['wms', 'dws', 'agg', 'inventory', 'daily']
) }}

WITH price_lookup AS (
    -- 获取SKU最新入库价格用于估算库存货值
    SELECT
        sku_id,
        MAX(inbound_price::DECIMAL) AS latest_inbound_price
    FROM {{ ref('ods_order_inbound_detail') }}
    WHERE inbound_price IS NOT NULL
      AND inbound_price <> ''
      AND inbound_price::DECIMAL > 0
    GROUP BY sku_id
)

SELECT
    inv.snap_date AS stats_date,
    inv.warehouse_id,
    inv.sku_id,
    inv.batch_no,
    inv.customer_id,
    inv.tenant_id,
    SUM(inv.remain_num::DECIMAL) AS remain_charge_num,                         -- 剩余计费数量(件数)
    SUM(inv.remain_weight_num::DECIMAL) AS remain_weight_num,                  -- 剩余重量
    SUM(inv.frozen_num::DECIMAL) AS frozen_charge_num,                         -- 冻结计费数量
    SUM(inv.frozen_weight_num::DECIMAL) AS frozen_weight_num,                  -- 冻结重量
    SUM(inv.lock_num::DECIMAL) AS lock_charge_num,                             -- 锁定计费数量
    SUM(inv.lock_weight_num::DECIMAL) AS lock_weight_num,                      -- 锁定重量
    SUM(COALESCE(inv.remain_num::DECIMAL, 0) + COALESCE(inv.frozen_num::DECIMAL, 0)) AS instock_charge_num,  -- 在库计费数量(剩余+冻结)
    SUM(COALESCE(inv.remain_weight_num::DECIMAL, 0) + COALESCE(inv.frozen_weight_num::DECIMAL, 0)) AS instock_weight_num,  -- 在库重量
    SUM((COALESCE(inv.remain_num::DECIMAL, 0) + COALESCE(inv.frozen_num::DECIMAL, 0)) * COALESCE(p.latest_inbound_price, 0)) AS instock_goods_value,  -- 在库货值
    SUM(COALESCE(inv.remain_num::DECIMAL, 0) * COALESCE(p.latest_inbound_price, 0)) AS inventory_goods_value,  -- 库存货值(仅剩余)
    CURRENT_TIMESTAMP AS dw_update_time
FROM {{ ref('dwd_wms_inventory_snap_df') }} inv
LEFT JOIN price_lookup p
    ON inv.sku_id = p.sku_id
WHERE inv.is_deleted = '0'
GROUP BY 1, 2, 3, 4, 5, 6
