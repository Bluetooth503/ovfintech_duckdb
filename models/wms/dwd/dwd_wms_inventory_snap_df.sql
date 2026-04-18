-- =============================================
-- 模型名称：dwd_wms_inventory_snap_df
-- 模型描述：库存日快照表，记录每日库存快照数据
-- Dbt更新方式：全量
-- 粒度：inventory_id
-- 说明：
--   - 数据源：ods_inventory（库存表）
--   - 增量策略：全量每日刷新
-- =============================================
{{ config(
    materialized='table',
    description='库存日快照表，记录每日库存快照数据（全量每日刷新）',
    tags=['wms', 'dwd', 'snap', 'inventory', 'daily']
) }}

WITH src_inventory AS (
    SELECT
        id AS inventory_id,                             -- 库存ID
        sku_id,                                         -- 商品SKU ID
        batch_no,                                       -- 批次号
        warehouse_id,                                   -- 仓库ID
        warehouse_area_id,                              -- 库区ID
        warehouse_position_id,                          -- 库位ID
        customer_id,                                    -- 客户ID(货主)
        remain_charge_num AS remain_num,                -- 剩余数量(件数)
        remain_weight_num,                              -- 剩余重量
        CAST(NULL AS VARCHAR) AS available_num,         -- 可用数量(CSV中无)
        CAST(NULL AS VARCHAR) AS available_weight_num,  -- 可用重量(CSV中无)
        frozen_charge_num AS frozen_num,                -- 冻结数量
        frozen_weight_num,                              -- 冻结重量
        lock_charge_num AS lock_num,                    -- 锁定数量
        lock_weight_num,                                -- 锁定重量
        production_date,                                -- 生产日期
        quality_days,                                   -- 保质期天数
        expiring_date AS expire_date,                   -- 过期日期
        is_deleted,                                     -- 删除标记
        org_id AS tenant_id,                            -- 租户ID
        create_time::timestamp AS create_time,          -- 创建时间
        frozen_time,                                    -- 冻结时间
        create_time::timestamp AS update_time           -- 更新时间(CSV中无此字段,使用create_time)
    FROM {{ ref('ods_inventory') }}
    WHERE is_deleted = '0'
)

SELECT
    inventory_id,                                   -- 库存ID
    sku_id,                                         -- 商品SKU ID
    batch_no,                                       -- 批次号
    warehouse_id,                                   -- 仓库ID
    warehouse_area_id,                              -- 库区ID
    warehouse_position_id,                          -- 库位ID
    customer_id,                                    -- 客户ID(货主)
    remain_num,                                     -- 剩余数量(件数)
    remain_weight_num,                              -- 剩余重量
    available_num,                                  -- 可用数量
    available_weight_num,                           -- 可用重量
    frozen_num,                                     -- 冻结数量
    frozen_weight_num,                              -- 冻结重量
    lock_num,                                       -- 锁定数量
    lock_weight_num,                                -- 锁定重量
    production_date,                                -- 生产日期
    quality_days,                                   -- 保质期天数
    expire_date,                                    -- 过期日期
    is_deleted,                                     -- 删除标记
    tenant_id,                                      -- 租户ID
    CURRENT_DATE AS snap_date,                      -- 快照日期
    create_time,                                    -- 创建时间
    update_time,                                    -- 更新时间
    CURRENT_TIMESTAMP AS etl_time                   -- ETL处理时间
FROM src_inventory
