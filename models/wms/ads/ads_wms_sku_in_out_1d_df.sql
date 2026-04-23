-- =============================================
-- 模型名称：ads_wms_sku_in_out_1d_df
-- 模型描述：SKU出入库日报表，面向业务应用的SKU维度日指标宽表
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date + warehouse_id + sku_id + batch_no + customer_id + tenant_id
-- 说明：
--   - 数据源：dws_wms_sku_in_out_daily_agg_df
--   - 应用场景：SKU出入库日报、最大在库天数按批次计算等
-- =============================================
{{ config(
    materialized='table',
    description='SKU出入库日报表，面向业务应用的SKU维度日指标宽表',
    tags=['wms', 'ads', 'rpt', 'sku', 'in_out', 'daily']
) }}

SELECT
    stats_date,
    warehouse_id,
    sku_id,
    batch_no,
    customer_id,
    tenant_id,
    in_charge_num,                                                    -- 入库计费数量
    in_weight_num,                                                    -- 入库重量
    inbound_price,                                                    -- 入库单价
    in_goods_value,                                                   -- 入库货值
    out_charge_num,                                                   -- 出库计费数量
    out_weight_num,                                                   -- 出库重量
    outbound_price,                                                   -- 出库单价
    out_goods_value,                                                  -- 出库货值
    CURRENT_TIMESTAMP AS dw_update_time
FROM {{ ref('dws_wms_sku_in_out_daily_agg_df') }}
