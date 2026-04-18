-- =============================================
-- 模型名称：dws_ranch_cattle_inventory_snap_mf
-- 模型描述：牛只在栏月度快照聚合表，按自然月统计期初/期末在栏情况
-- Dbt更新方式：全量
-- 粒度：牧场 + 栏舍 + SKU + 自然月
-- 说明：
--   - 数据源：dwd_ranch_cattle_onstall_fact_di（DWD层在栏明细）
--   - 增量策略：全量刷新
--   - 统计指标：期初/期末在栏数量、平均体重、贷款总额、饲料成本等库存指标
--   - 聚合逻辑：取每月第一天和最后一天快照数据，分别作为期初和期末数据
-- =============================================
{{ config(
    materialized='table',
    description='牛只在栏月度快照聚合表，按牧场+栏舍+SKU+自然月统计期初/期末在栏数量、平均体重、贷款总额、饲料成本',
    tags=['ranch', 'dws', 'agg', 'cattle', 'inventory', 'monthly', 'snap']
) }}

WITH onstall_detail AS (
    SELECT
        EXTRACT(YEAR FROM snap_date) * 100 + EXTRACT(MONTH FROM snap_date) AS natural_month,
        snap_date,
        ranch_id,
        stall_id,
        sku_id AS cattle_sku_id,
        livestock_id,
        estimated_weight,
        total_loan_money,
        weight_add,
        total_feed_cost
    FROM {{ ref('dwd_ranch_cattle_onstall_fact_di') }}
    WHERE snap_date IS NOT NULL
),

month_boundary AS (
    SELECT
        natural_month,
        MIN(snap_date) AS month_start_date,
        MAX(snap_date) AS month_end_date
    FROM onstall_detail
    GROUP BY natural_month
),

begin_inventory AS (
    SELECT
        o.natural_month,
        o.ranch_id,
        o.stall_id,
        o.cattle_sku_id,
        COUNT(DISTINCT o.livestock_id) AS begin_cattle_count,
        AVG(o.estimated_weight) AS begin_avg_weight,
        SUM(COALESCE(o.total_loan_money, 0)) AS begin_total_loan
    FROM onstall_detail o
    INNER JOIN month_boundary mb ON o.natural_month = mb.natural_month AND o.snap_date = mb.month_start_date
    GROUP BY o.natural_month, o.ranch_id, o.stall_id, o.cattle_sku_id
),

end_inventory AS (
    SELECT
        o.natural_month,
        o.ranch_id,
        o.stall_id,
        o.cattle_sku_id,
        COUNT(DISTINCT o.livestock_id) AS end_cattle_count,
        AVG(o.estimated_weight) AS end_avg_weight,
        SUM(COALESCE(o.total_loan_money, 0)) AS end_total_loan,
        AVG(o.weight_add) AS end_avg_weight_add,
        SUM(COALESCE(o.total_feed_cost, 0)) AS end_total_feed_cost
    FROM onstall_detail o
    INNER JOIN month_boundary mb ON o.natural_month = mb.natural_month AND o.snap_date = mb.month_end_date
    GROUP BY o.natural_month, o.ranch_id, o.stall_id, o.cattle_sku_id
)

SELECT
    COALESCE(b.natural_month, e.natural_month) AS natural_month,
    COALESCE(b.ranch_id, e.ranch_id) AS ranch_id,
    COALESCE(b.stall_id, e.stall_id) AS stall_id,
    COALESCE(b.cattle_sku_id, e.cattle_sku_id) AS cattle_sku_id,
    b.begin_cattle_count,                    -- 期初在栏数
    b.begin_avg_weight,                      -- 期初平均体重
    b.begin_total_loan,                      -- 期初贷款总额
    e.end_cattle_count,                      -- 期末在栏数
    e.end_avg_weight,                        -- 期末平均体重
    e.end_total_loan,                        -- 期末贷款总额
    e.end_avg_weight_add,                    -- 期末平均增重
    e.end_total_feed_cost,                   -- 期末总饲料成本
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM begin_inventory b
FULL OUTER JOIN end_inventory e ON b.natural_month = e.natural_month AND b.ranch_id = e.ranch_id AND b.stall_id = e.stall_id AND b.cattle_sku_id = e.cattle_sku_id
ORDER BY natural_month DESC, ranch_id, stall_id, cattle_sku_id
