-- =============================================
-- 模型名称：dwd_wms_warehouse_member_rel_f_d
-- 模型描述：仓库-货主关系事实表，记录实际业务关联
-- Dbt更新方式：增量（按日期）
-- 粒度：仓库 + 货主 + 日期
-- 说明：
--   - 数据源：dwd_wms_inventory_snap_df（库存快照）
--   - 从库存明细中抽取仓库-货主关系
--   - 记录每个货主在每个仓库的货值、占比等
-- =============================================
{{ config(
    materialized='table',
    description='仓库-货主关系事实表，记录实际业务关联（增量按日期）',
    tags=['wms', 'dwd', 'rel', 'warehouse', 'member']
) }}

WITH inventory_rel AS (
    SELECT
        CURRENT_DATE AS snap_date,
        warehouse_id,
        customer_id AS member_id,
        
        -- 关联关系属性
        '有货' AS relation_type,
        CURRENT_DATE AS relation_start_date,
        CAST(NULL AS DATE) AS relation_end_date,
        
        -- 货主在该仓库的库存统计
        COUNT(DISTINCT sku_id) AS sku_cnt,
        SUM(CAST(remain_num AS DECIMAL) + CAST(frozen_num AS DECIMAL) + CAST(lock_num AS DECIMAL)) AS total_charge_num,
        SUM(remain_weight_num + frozen_weight_num + lock_weight_num) AS total_weight_num,
        
        -- 货值计算（需要关联商品价格表）
        SUM((CAST(remain_num AS DECIMAL) + CAST(frozen_num AS DECIMAL) + CAST(lock_num AS DECIMAL)) * COALESCE(latest_price, 0)) AS total_goods_value,
        
        -- 权重计算
        SUM(CAST(remain_num AS DECIMAL) * COALESCE(latest_price, 0)) AS remain_goods_value,
        SUM(CAST(frozen_num AS DECIMAL) * COALESCE(latest_price, 0)) AS frozen_goods_value,
        SUM(CAST(lock_num AS DECIMAL) * COALESCE(latest_price, 0)) AS locked_goods_value,
        
        -- 关系状态
        CASE
            WHEN SUM(CAST(remain_num AS DECIMAL)) > 0 THEN '活跃'
            WHEN SUM(CAST(frozen_num AS DECIMAL) + CAST(lock_num AS DECIMAL)) > 0 THEN '锁定/冻结'
            ELSE '历史'
        END AS relation_status,
        
        CURRENT_TIMESTAMP AS etl_time

    FROM {{ ref('dwd_wms_inventory_snap_df') }}
    WHERE customer_id IS NOT NULL
    GROUP BY
        warehouse_id,
        customer_id
),

-- 计算仓库维度占比
warehouse_total AS (
    SELECT
        snap_date,
        warehouse_id,
        SUM(total_goods_value) AS warehouse_total_goods_value
    FROM inventory_rel
    GROUP BY
        snap_date,
        warehouse_id
),

-- 计算货主维度占比
member_total AS (
    SELECT
        snap_date,
        member_id,
        SUM(total_goods_value) AS member_total_goods_value
    FROM inventory_rel
    GROUP BY
        snap_date,
        member_id
)

SELECT
    ir.snap_date,
    ir.warehouse_id,
    ir.member_id,
    ir.relation_type,
    ir.relation_start_date,
    ir.relation_end_date,
    ir.sku_cnt,
    ir.total_charge_num,
    ir.total_weight_num,
    ir.total_goods_value,
    ir.remain_goods_value,
    ir.frozen_goods_value,
    ir.locked_goods_value,
    
    -- 占比计算（按仓库维度）
    CASE
        WHEN wt.warehouse_total_goods_value > 0
        THEN ir.total_goods_value * 100.0 / wt.warehouse_total_goods_value
        ELSE 0
    END AS goods_value_warehouse_rate,
    
    -- 占比计算（按货主维度）
    CASE
        WHEN mt.member_total_goods_value > 0
        THEN ir.total_goods_value * 100.0 / mt.member_total_goods_value
        ELSE 0
    END AS goods_value_member_rate,
    
    ir.relation_status,
    ir.etl_time

FROM inventory_rel ir
LEFT JOIN warehouse_total wt ON ir.snap_date = wt.snap_date AND ir.warehouse_id = wt.warehouse_id
LEFT JOIN member_total mt ON ir.snap_date = mt.snap_date AND ir.member_id = mt.member_id

-- {% if is_incremental() %}
-- AND snap_date > (SELECT COALESCE(MAX(snap_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}
