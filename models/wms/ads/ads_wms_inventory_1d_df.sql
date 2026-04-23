-- =============================================
-- 模型名称：ads_wms_inventory_1d_df
-- 模型描述：库存日报表，面向业务应用的SKU维度库存日指标宽表
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date + warehouse_id + sku_id + batch_no + customer_id + tenant_id
-- 说明：
--   - 数据源：dws_wms_inventory_daily_agg_df
--   - 应用场景：客户库存统计明细、在库货值监控等
-- =============================================
{{ config(
    materialized='table',
    description='库存日报表，面向业务应用的SKU维度库存日指标宽表',
    tags=['wms', 'ads', 'rpt', 'inventory', 'daily']
) }}

SELECT
    stats_date,
    warehouse_id,
    sku_id,
    batch_no,
    customer_id,
    tenant_id,
    remain_charge_num,                                                -- 剩余计费数量
    remain_weight_num,                                                -- 剩余重量
    frozen_charge_num,                                                -- 冻结计费数量
    frozen_weight_num,                                                -- 冻结重量
    lock_charge_num,                                                  -- 锁定计费数量
    lock_weight_num,                                                  -- 锁定重量
    instock_charge_num,                                               -- 在库计费数量(剩余+冻结)
    instock_weight_num,                                               -- 在库重量
    instock_goods_value,                                              -- 在库货值
    inventory_goods_value,                                            -- 库存货值(仅剩余)
    CURRENT_TIMESTAMP AS dw_update_time
FROM {{ ref('dws_wms_inventory_daily_agg_df') }}
