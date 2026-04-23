-- =============================================
-- 模型名称：ads_wms_warehouse_member_1d_df
-- 模型描述：客户维度仓库日报表，按客户+租户+日期汇总仓库指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date + customer_id + tenant_id
-- 说明：
--   - 数据源：dws_wms_warehouse_daily_agg_df
--   - 应用场景：客户贷款余额及风险指标表、客户库存统计等
--   - 将仓库维度聚合到客户维度，支持跨仓库客户级分析
-- =============================================
{{ config(
    materialized='table',
    description='客户维度仓库日报表，按客户+租户+日期汇总仓库指标',
    tags=['wms', 'ads', 'rpt', 'member', 'daily']
) }}

SELECT
    stats_date,
    customer_id,
    tenant_id,
    SUM(inbound_times) AS inbound_times,                              -- 入库次数
    SUM(inbound_charge_num) AS inbound_charge_num,                    -- 入库计费数量
    SUM(inbound_weight_num) AS inbound_weight_num,                    -- 入库重量
    SUM(inbound_goods_value) AS inbound_goods_value,                  -- 入库货值
    SUM(outbound_times) AS outbound_times,                            -- 出库次数
    SUM(outbound_charge_num) AS outbound_charge_num,                  -- 出库计费数量
    SUM(outbound_weight_num) AS outbound_weight_num,                  -- 出库重量
    SUM(outbound_goods_value) AS outbound_goods_value,                -- 出库货值
    SUM(make_inventory_times) AS make_inventory_times,                -- 盘点次数
    SUM(make_inventory_num) AS make_inventory_num,                    -- 盘点数量
    SUM(inventory_charge_num) AS inventory_charge_num,                -- 库存计费数量
    SUM(inventory_weight_num) AS inventory_weight_num,                -- 库存重量
    SUM(inventory_goods_value) AS inventory_goods_value,              -- 库存货值
    CURRENT_TIMESTAMP AS dw_update_time
FROM {{ ref('dws_wms_warehouse_daily_agg_df') }}
GROUP BY stats_date, customer_id, tenant_id
