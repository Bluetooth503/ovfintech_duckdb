-- =============================================
-- 模型名称：dim_wms_warehouse_goods_owner_rel
-- 模型描述：仓库与货主（客户）映射关系表，从库存明细表提取
-- 粒度：tenant_id + warehouse_id + customer_id
-- 说明：
--   - 数据源：dwd_wms_inventory_fact_i（库存明细事实表）
--   - 1个仓库可服务多个货主（同一租户下）
--   - 1个货主可在多个仓库存储货物
--   - 关联逻辑：从库存记录中提取仓库-货主-租户三元组
-- =============================================

-- =============================================
-- 从数仓ods_inventory计算出来的结果
-- SELECT DISTINCT
--     warehouse_id,
--     warehouse_name,
--     CASE WHEN customer_id = '0' THEN org_id ELSE customer_id END AS customer_id,
--     CASE WHEN customer_id = '0' THEN org_name ELSE customer_name END AS customer_name,
--     CURRENT_TIMESTAMP AS dw_update_time
-- FROM ods_inventory
-- WHERE remain_weight_num + remain_charge_num > 0
-- =============================================



{{ config(
    materialized='table',
    description='仓库与货主（客户）映射关系表',
    tags=['wms', 'dim', 'rel', 'warehouse', 'customer']
) }}

SELECT DISTINCT
    warehouse_id,                                      -- 仓库ID
    warehouse_name,                                    -- 仓库名称
    customer_id,                                       -- 客户ID（货主）
    customer_name,                                     -- 客户名称（货主名称）
    CURRENT_TIMESTAMP AS dw_update_time                -- 数据仓库更新时间
FROM {{ ref('dwd_wms_inventory_fact_i') }}
