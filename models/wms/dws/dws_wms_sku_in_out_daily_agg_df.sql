-- =============================================
-- 模型名称：dws_wms_sku_in_out_daily_agg_df
-- 模型描述：SKU出入库日聚合表，按仓库+SKU+批次+客户+日期维度汇总出入库指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date + warehouse_id + sku_id + batch_no + customer_id + tenant_id
-- 说明：
--   - 数据源：dwd_wms_inbound_fact_i / dwd_wms_outbound_fact_i 及对应明细
--   - 核心指标：入库/出库计费数量、重量、单价
-- =============================================
{{ config(
    materialized='table',
    description='SKU出入库日聚合表，按仓库+SKU+批次+客户+日期维度汇总出入库指标',
    tags=['wms', 'dws', 'agg', 'sku', 'in_out', 'daily']
) }}

WITH inbound_sku_agg AS (
    SELECT
        DATE(i.finish_date) AS stats_date,
        i.warehouse_id,
        d.sku_id,
        d.batch_no,
        i.customer_id,
        i.tenant_id,
        SUM(d.num) AS in_charge_num,                                    -- 入库计费数量
        SUM(d.weight) AS in_weight_num,                                 -- 入库重量
        AVG(d.price) AS inbound_price,                                  -- 入库单价(平均)
        SUM(d.amount) AS in_goods_value                                 -- 入库货值
    FROM {{ ref('dwd_wms_inbound_fact_i') }} i
    JOIN {{ ref('dwd_wms_inbound_detail_fact_i') }} d
        ON i.inbound_id = d.inbound_id
    WHERE i.order_status = '3'
      AND i.is_deleted = '0'
      AND d.is_deleted = '0'
      AND i.finish_date IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6
),

outbound_sku_agg AS (
    SELECT
        DATE(o.finish_date) AS stats_date,
        o.warehouse_id,
        d.sku_id,
        d.batch_no,
        o.customer_id,
        o.tenant_id,
        SUM(d.num) AS out_charge_num,                                   -- 出库计费数量
        SUM(d.weight) AS out_weight_num,                                -- 出库重量
        AVG(d.price) AS outbound_price,                                 -- 出库单价(平均)
        SUM(d.amount) AS out_goods_value                                -- 出库货值
    FROM {{ ref('dwd_wms_outbound_fact_i') }} o
    JOIN {{ ref('dwd_wms_outbound_detail_fact_i') }} d
        ON o.outbound_id = d.outbound_id
    WHERE o.order_status = '3'
      AND o.is_deleted = '0'
      AND d.is_deleted = '0'
      AND o.finish_date IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6
),

all_dims AS (
    SELECT stats_date, warehouse_id, sku_id, batch_no, customer_id, tenant_id
    FROM inbound_sku_agg
    UNION
    SELECT stats_date, warehouse_id, sku_id, batch_no, customer_id, tenant_id
    FROM outbound_sku_agg
)

SELECT
    d.stats_date,
    d.warehouse_id,
    d.sku_id,
    d.batch_no,
    d.customer_id,
    d.tenant_id,
    COALESCE(i.in_charge_num, 0) AS in_charge_num,                    -- 入库计费数量
    COALESCE(i.in_weight_num, 0) AS in_weight_num,                    -- 入库重量
    COALESCE(i.inbound_price, 0) AS inbound_price,                    -- 入库单价
    COALESCE(i.in_goods_value, 0) AS in_goods_value,                  -- 入库货值
    COALESCE(o.out_charge_num, 0) AS out_charge_num,                  -- 出库计费数量
    COALESCE(o.out_weight_num, 0) AS out_weight_num,                  -- 出库重量
    COALESCE(o.outbound_price, 0) AS outbound_price,                  -- 出库单价
    COALESCE(o.out_goods_value, 0) AS out_goods_value,                -- 出库货值
    CURRENT_TIMESTAMP AS dw_update_time
FROM all_dims d
LEFT JOIN inbound_sku_agg i
    ON d.stats_date = i.stats_date
    AND d.warehouse_id = i.warehouse_id
    AND d.sku_id = i.sku_id
    AND d.batch_no = i.batch_no
    AND d.customer_id = i.customer_id
    AND d.tenant_id = i.tenant_id
LEFT JOIN outbound_sku_agg o
    ON d.stats_date = o.stats_date
    AND d.warehouse_id = o.warehouse_id
    AND d.sku_id = o.sku_id
    AND d.batch_no = o.batch_no
    AND d.customer_id = o.customer_id
    AND d.tenant_id = o.tenant_id
