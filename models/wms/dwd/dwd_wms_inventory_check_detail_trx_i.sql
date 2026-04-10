-- =============================================
-- 模型名称：dwd_wms_inventory_check_detail_trx_i
-- 模型描述：盘点单明细表，记录盘点SKU级别的增量事务数据
-- 作者：dbt
-- 创建时间：2026-04-08
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='check_detail_id',
    description='盘点单明细表，记录盘点SKU级别的增量事务数据',
    tags=['wms', 'dwd', 'trx', 'check', 'detail']
) }}

WITH src_detail AS (
    SELECT
        id AS check_detail_id,                          -- 盘点明细ID
        inventory_id AS check_id,                       -- 盘点单ID
        inventory_plan_id,                              -- 盘点计划ID
        sku_id,                                         -- 商品SKU ID
        sku_name,                                       -- 商品名称
        batch_no,                                       -- 批次号
        warehouse_area_id,                              -- 库区ID
        warehouse_area_name,                            -- 库区名称
        warehouse_position_id,                          -- 库位ID
        warehouse_position_name,                        -- 库位名称
        plan_weight_num AS plan_weight,                 -- 计划重量
        actual_num,                                     -- 实际数量
        recheck_weight_num AS recheck_weight,           -- 复盘重量
        profit_loss_weight_num,                         -- 盘亏重量
        frozen_profit_loss_weight_num,                  -- 冻结盘亏重量
        profit_loss_num,                                -- 盘亏数量
        frozen_profit_loss_charge_num,                  -- 冻结盘亏件数
        net_content,                                    -- 净含量
        is_deleted,                                     -- 删除标记
        producer,                                       -- 生产商
        category_id,                                    -- 分类ID
        category_name,                                  -- 分类名称
        remarks AS remark,                              -- 备注
        create_time::timestamp AS create_time,          -- 创建时间
        update_time::timestamp AS update_time           -- 更新时间
    FROM {{ ref('ods_make_inventory_detail') }}
    WHERE create_time IS NOT NULL
)

SELECT
    check_detail_id,                                -- 盘点明细ID
    check_id,                                       -- 盘点单ID
    inventory_plan_id,                              -- 盘点计划ID
    sku_id,                                         -- 商品SKU ID
    sku_name,                                       -- 商品名称
    batch_no,                                       -- 批次号
    warehouse_area_id,                              -- 库区ID
    warehouse_area_name,                            -- 库区名称
    warehouse_position_id,                          -- 库位ID
    warehouse_position_name,                        -- 库位名称
    plan_weight,                                    -- 计划重量
    actual_num,                                     -- 实际数量
    recheck_weight,                                 -- 复盘重量
    profit_loss_weight_num,                         -- 盘亏重量
    frozen_profit_loss_weight_num,                  -- 冻结盘亏重量
    profit_loss_num,                                -- 盘亏数量
    frozen_profit_loss_charge_num,                  -- 冻结盘亏件数
    net_content,                                    -- 净含量
    is_deleted,                                     -- 删除标记
    producer,                                       -- 生产商
    category_id,                                    -- 分类ID
    category_name,                                  -- 分类名称
    remark,                                         -- 备注
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM src_detail

{% if is_incremental() %}
WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
{% endif %}
