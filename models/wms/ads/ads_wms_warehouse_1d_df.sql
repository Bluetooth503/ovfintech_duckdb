-- =============================================
-- 模型名称：ads_wms_warehouse_1d_df
-- 模型描述：仓库日报表，面向业务应用的仓库维度日指标宽表
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date + warehouse_id + customer_id + tenant_id
-- 说明：
--   - 数据源：dws_wms_warehouse_daily_agg_df
--   - 应用场景：客户库存统计、最大在库天数、风控预警日报等
--   - 直接透传DWS指标，保持与积木报表口径一致
-- =============================================
{{ config(
    materialized='table',
    description='仓库日报表，面向业务应用的仓库维度日指标宽表',
    tags=['wms', 'ads', 'rpt', 'warehouse', 'daily']
) }}

SELECT
    stats_date,
    warehouse_id,
    customer_id,
    tenant_id,
    inbound_times,                                                    -- 入库次数
    inbound_charge_num,                                               -- 入库计费数量
    inbound_weight_num,                                               -- 入库重量
    inbound_goods_value,                                              -- 入库货值
    outbound_times,                                                   -- 出库次数
    outbound_charge_num,                                              -- 出库计费数量
    outbound_weight_num,                                              -- 出库重量
    outbound_goods_value,                                             -- 出库货值
    make_inventory_times,                                             -- 盘点次数
    make_inventory_num,                                               -- 盘点数量
    inventory_charge_num,                                             -- 库存计费数量
    inventory_weight_num,                                             -- 库存重量
    inventory_goods_value,                                            -- 库存货值
    CURRENT_TIMESTAMP AS dw_update_time
FROM {{ ref('dws_wms_warehouse_daily_agg_df') }}
