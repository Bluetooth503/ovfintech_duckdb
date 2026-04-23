-- =============================================
-- 模型名称：dwd_wms_inventory_fact_i
-- 模型描述：库存明细事实表，记录库存的增量状态变化数据
-- Dbt更新方式：增量（事件级）
-- 粒度：inventory_id + update_time
-- 说明：
--   - 数据源：ods_inventory（库存表）
--   - 增量策略：按 update_time 增量追加，记录库存每次状态变化
--   - 统计指标：剩余数量、剩余重量、冻结数量、冻结重量、锁定数量、锁定重量、内部锁定、订单锁定
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='inventory_id',
    description='库存明细事实表，记录库存的增量状态变化数据',
    tags=['wms', 'dwd', 'fact', 'inventory']
) }}

WITH src_inventory AS (
    SELECT
        id AS inventory_id,                                   -- 库存ID
        org_id,                                               -- 原始租户ID
        org_name,                                             -- 原始租户名称
        org_id AS tenant_id,                                  -- 租户ID
        org_name AS tenant_name,                              -- 租户名称
        CASE WHEN customer_id = '0' THEN org_id ELSE customer_id END AS customer_id,        -- 客户ID(货主，为0时取租户ID)
        CASE WHEN customer_id = '0' THEN org_name ELSE customer_name END AS customer_name,  -- 客户名称(为0时取租户名称)
        warehouse_id,                                         -- 仓库ID
        warehouse_name,                                       -- 仓库名称
        warehouse_area_id,                                    -- 库区ID
        warehouse_area_name,                                  -- 库区名称
        warehouse_position_id,                                -- 库位ID
        warehouse_position_name,                              -- 库位名称
        sku_id,                                               -- 商品SKU ID
        sku_name,                                             -- 商品SKU名称
        batch_no,                                             -- 批次号
        barcode,                                              -- 条形码
        net_content,                                          -- 净含量
        package_name,                                         -- 包装名称
        production_date,                                      -- 生产日期
        quality_days,                                         -- 保质期天数
        expiring_date AS expire_date,                         -- 过期日期
        category_id,                                          -- 类别ID
        category_name,                                        -- 类别名称
        producer,                                             -- 生产厂家
        is_standard_product,                                  -- 是否标准品
        inbound_price,                                        -- 入库价格
        inbound_date,                                         -- 入库日期
        latest_price,                                         -- 最新价格
        weight_unit,                                          -- 重量单位
        unit_translation,                                     -- 单位换算
        charge_unit,                                          -- 件数单位
        remain_charge_num AS remain_num,                      -- 剩余数量(件数)
        remain_weight_num,                                    -- 剩余重量
        frozen_charge_num AS frozen_num,                      -- 冻结数量
        frozen_weight_num,                                    -- 冻结重量
        lock_charge_num AS lock_num,                          -- 锁定数量
        lock_weight_num,                                      -- 锁定重量
        inner_lock_charge_num AS inner_lock_num,              -- 内部锁定数量
        inner_lock_weight_num AS inner_lock_weight,           -- 内部锁定重量
        order_lock_charge_num AS order_lock_num,              -- 订单锁定数量
        order_lock_weight_num AS order_lock_weight,           -- 订单锁定重量
        assets_id,                                            -- 资产ID
        batch_remark,                                         -- 批次备注
        is_deleted,                                           -- 删除标记
        create_time::timestamp AS create_time,                -- 创建时间
        frozen_time::timestamp AS frozen_time,                -- 冻结时间
        create_time::timestamp AS update_time                 -- 更新时间(使用create_time)
    FROM {{ ref('ods_inventory') }}
    WHERE is_deleted = '0'
)

SELECT
    inventory_id,                                        -- 库存ID
    tenant_id,                                           -- 租户ID
    tenant_name,                                         -- 租户名称
    customer_id,                                         -- 客户ID(货主)
    customer_name,                                       -- 客户名称
    warehouse_id,                                        -- 仓库ID
    warehouse_name,                                      -- 仓库名称
    warehouse_area_id,                                   -- 库区ID
    warehouse_area_name,                                 -- 库区名称
    warehouse_position_id,                               -- 库位ID
    warehouse_position_name,                             -- 库位名称
    sku_id,                                              -- 商品SKU ID
    sku_name,                                            -- 商品SKU名称
    batch_no,                                            -- 批次号
    barcode,                                             -- 条形码
    net_content,                                         -- 净含量
    package_name,                                        -- 包装名称
    production_date,                                     -- 生产日期
    quality_days,                                        -- 保质期天数
    expire_date,                                         -- 过期日期
    category_id,                                         -- 类别ID
    category_name,                                       -- 类别名称
    producer,                                            -- 生产厂家
    is_standard_product,                                 -- 是否标准品
    inbound_price,                                       -- 入库价格
    inbound_date,                                        -- 入库日期
    latest_price,                                        -- 最新价格
    weight_unit,                                         -- 重量单位
    unit_translation,                                    -- 单位换算
    charge_unit,                                         -- 件数单位
    remain_num,                                          -- 剩余数量(件数)
    remain_weight_num,                                   -- 剩余重量
    frozen_num,                                          -- 冻结数量
    frozen_weight_num,                                   -- 冻结重量
    lock_num,                                            -- 锁定数量
    lock_weight_num,                                     -- 锁定重量
    inner_lock_num,                                      -- 内部锁定数量
    inner_lock_weight,                                   -- 内部锁定重量
    order_lock_num,                                      -- 订单锁定数量
    order_lock_weight,                                   -- 订单锁定重量
    assets_id,                                           -- 资产ID
    batch_remark,                                        -- 批次备注
    is_deleted,                                          -- 删除标记
    create_time,                                         -- 创建时间
    frozen_time,                                         -- 冻结时间
    update_time                                          -- 更新时间
FROM src_inventory

-- {% if is_incremental() %}
-- WHERE update_time > (SELECT COALESCE(MAX(update_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
