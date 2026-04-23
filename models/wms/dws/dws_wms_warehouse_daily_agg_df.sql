-- =============================================
-- 模型名称：dws_wms_warehouse_daily_agg_df
-- 模型描述：仓库每日聚合表，按仓库+客户+日期维度汇总入库/出库/盘点/库存核心指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date + warehouse_id + customer_id + tenant_id
-- 说明：
--   - 数据源：dwd_wms_inbound_fact_i / dwd_wms_outbound_fact_i / dwd_wms_inventory_snap_df / dwd_wms_inventory_check_fact_i
--   - 核心指标：进出库数量/重量/货值/次数、库存数量/重量/货值、盘点数量/次数
--   - 命名规范参考术语库：inventory_quantity(库存数量), goods_value(货物价值), outbound_quantity(出库数量)
-- =============================================
{{ config(
    materialized='table',
    description='仓库每日聚合表，按仓库+客户+日期维度汇总入库/出库/盘点/库存核心指标',
    tags=['wms', 'dws', 'agg', 'warehouse', 'daily']
) }}

WITH inbound_agg AS (
    SELECT
        DATE(i.finish_date) AS stats_date,
        i.warehouse_id,
        i.customer_id,
        i.tenant_id,
        COUNT(DISTINCT i.inbound_id) AS inbound_times,
        SUM(d.num) AS inbound_charge_num,
        SUM(d.weight) AS inbound_weight_num,
        SUM(d.amount) AS inbound_goods_value
    FROM {{ ref('dwd_wms_inbound_fact_i') }} i
    JOIN {{ ref('dwd_wms_inbound_detail_fact_i') }} d
        ON i.inbound_id = d.inbound_id
    WHERE i.order_status = '3'
      AND i.is_deleted = '0'
      AND d.is_deleted = '0'
      AND i.finish_date IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

outbound_agg AS (
    SELECT
        DATE(o.finish_date) AS stats_date,
        o.warehouse_id,
        o.customer_id,
        o.tenant_id,
        COUNT(DISTINCT o.outbound_id) AS outbound_times,
        SUM(d.num) AS outbound_charge_num,
        SUM(d.weight) AS outbound_weight_num,
        SUM(d.amount) AS outbound_goods_value
    FROM {{ ref('dwd_wms_outbound_fact_i') }} o
    JOIN {{ ref('dwd_wms_outbound_detail_fact_i') }} d
        ON o.outbound_id = d.outbound_id
    WHERE o.order_status = '3'
      AND o.is_deleted = '0'
      AND d.is_deleted = '0'
      AND o.finish_date IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

inventory_agg AS (
    SELECT
        snap_date AS stats_date,
        warehouse_id,
        customer_id,
        tenant_id,
        SUM(COALESCE(remain_num::DOUBLE, 0)) AS inventory_charge_num,
        SUM(COALESCE(remain_weight_num::DOUBLE, 0)) AS inventory_weight_num,
        SUM(COALESCE(remain_num::DOUBLE, 0) * COALESCE(
            (SELECT MAX(inbound_price::DOUBLE) FROM {{ ref('ods_order_inbound_detail') }} WHERE sku_id = inv.sku_id),
            0
        )) AS inventory_goods_value
    FROM {{ ref('dwd_wms_inventory_snap_df') }} inv
    WHERE is_deleted = '0'
    GROUP BY 1, 2, 3, 4
),

check_agg AS (
    SELECT
        DATE(c.over_time) AS stats_date,
        c.warehouse_id,
        c.customer_id,
        c.tenant_id,
        COUNT(DISTINCT c.check_id) AS make_inventory_times,
        SUM(COALESCE(d.actual_num::DOUBLE, 0)) AS make_inventory_num
    FROM {{ ref('dwd_wms_inventory_check_fact_i') }} c
    JOIN {{ ref('dwd_wms_inventory_check_detail_fact_i') }} d
        ON c.check_id = d.check_id
    WHERE c.is_deleted = '0'
      AND d.is_deleted = '0'
      AND c.over_time IS NOT NULL
    GROUP BY 1, 2, 3, 4
),

all_dims AS (
    SELECT stats_date, warehouse_id, customer_id, tenant_id FROM inbound_agg
    UNION
    SELECT stats_date, warehouse_id, customer_id, tenant_id FROM outbound_agg
    UNION
    SELECT stats_date, warehouse_id, customer_id, tenant_id FROM inventory_agg
    UNION
    SELECT stats_date, warehouse_id, customer_id, tenant_id FROM check_agg
)

SELECT
    d.stats_date,
    d.warehouse_id,
    d.customer_id,
    d.tenant_id,
    COALESCE(i.inbound_times, 0) AS inbound_times,
    COALESCE(i.inbound_charge_num, 0) AS inbound_charge_num,
    COALESCE(i.inbound_weight_num, 0) AS inbound_weight_num,
    COALESCE(i.inbound_goods_value, 0) AS inbound_goods_value,
    COALESCE(o.outbound_times, 0) AS outbound_times,
    COALESCE(o.outbound_charge_num, 0) AS outbound_charge_num,
    COALESCE(o.outbound_weight_num, 0) AS outbound_weight_num,
    COALESCE(o.outbound_goods_value, 0) AS outbound_goods_value,
    COALESCE(c.make_inventory_times, 0) AS make_inventory_times,
    COALESCE(c.make_inventory_num, 0) AS make_inventory_num,
    COALESCE(iv.inventory_charge_num, 0) AS inventory_charge_num,
    COALESCE(iv.inventory_weight_num, 0) AS inventory_weight_num,
    COALESCE(iv.inventory_goods_value, 0) AS inventory_goods_value,
    CURRENT_TIMESTAMP AS dw_update_time
FROM all_dims d
LEFT JOIN inbound_agg i
    ON d.stats_date = i.stats_date
    AND d.warehouse_id = i.warehouse_id
    AND d.customer_id = i.customer_id
    AND d.tenant_id = i.tenant_id
LEFT JOIN outbound_agg o
    ON d.stats_date = o.stats_date
    AND d.warehouse_id = o.warehouse_id
    AND d.customer_id = o.customer_id
    AND d.tenant_id = o.tenant_id
LEFT JOIN check_agg c
    ON d.stats_date = c.stats_date
    AND d.warehouse_id = c.warehouse_id
    AND d.customer_id = c.customer_id
    AND d.tenant_id = c.tenant_id
LEFT JOIN inventory_agg iv
    ON d.stats_date = iv.stats_date
    AND d.warehouse_id = iv.warehouse_id
    AND d.customer_id = iv.customer_id
    AND d.tenant_id = iv.tenant_id
