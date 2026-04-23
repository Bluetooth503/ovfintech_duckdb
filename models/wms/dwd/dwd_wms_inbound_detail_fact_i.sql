-- =============================================
-- 模型名称：dwd_wms_inbound_detail_fact_i
-- 模型描述：入库单明细表，记录入库SKU级别的增量事务数据
-- Dbt更新方式：增量（事件级）
-- 粒度：inbound_detail_id
-- 说明：
--   - 数据源：ods_order_inbound_detail（入库明细表）
--   - 增量策略：按 inbound_detail_id 增量追加
--   - 关联逻辑：LEFT JOIN 入库单头表补充 tenant_id
--   - 衍生字段：amount = charge_num * inbound_price
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='inbound_detail_id',
    description='入库单明细表，记录入库SKU级别的增量事务数据',
    tags=['wms', 'dwd', 'trx', 'inbound', 'detail']
) }}

WITH src_detail AS (
    SELECT
        d.id AS inbound_detail_id,                      -- 入库明细ID
        d.inbound_id,                                   -- 入库单ID
        d.in_inventory_id AS inbound_no,                -- 入库单号(冗余)
        d.sku_id,                                       -- 商品SKU ID
        d.sku_name,                                     -- 商品名称
        d.batch_no,                                     -- 批次号
        CASE WHEN d.plan_charge_num ~ '^[0-9]+\.?[0-9]*$' THEN d.plan_charge_num::DOUBLE ELSE NULL END AS plan_num,
        CASE WHEN d.charge_num ~ '^[0-9]+\.?[0-9]*$' THEN d.charge_num::DOUBLE ELSE NULL END AS num,
        CASE WHEN d.plan_weight_num ~ '^[0-9]+\.?[0-9]*$' THEN d.plan_weight_num::DOUBLE ELSE NULL END AS plan_weight,
        CASE WHEN d.actual_weight_num ~ '^[0-9]+\.?[0-9]*$' THEN d.actual_weight_num::DOUBLE ELSE NULL END AS weight,
        CASE WHEN d.recheck_weight_num ~ '^[0-9]+\.?[0-9]*$' THEN d.recheck_weight_num::DOUBLE ELSE NULL END AS recheck_weight,
        CASE WHEN d.inbound_price ~ '^[0-9]+\.?[0-9]*$' THEN d.inbound_price::DOUBLE ELSE NULL END AS price,
        COALESCE(CASE WHEN d.charge_num ~ '^[0-9]+\.?[0-9]*$' THEN d.charge_num::DOUBLE ELSE NULL END, 0)
            * COALESCE(CASE WHEN d.inbound_price ~ '^[0-9]+\.?[0-9]*$' THEN d.inbound_price::DOUBLE ELSE NULL END, 0) AS amount,
        d.warehouse_area_id,                            -- 库区ID
        d.warehouse_area_name,                          -- 库区名称
        d.warehouse_position_id,                        -- 库位ID
        d.warehouse_position_name,                      -- 库位名称
        d.production_date,                              -- 生产日期
        d.quality_days,                                 -- 保质期天数
        d.is_deleted,                                   -- 删除标记
        d.category_id,                                  -- 分类ID
        d.category_name,                                -- 分类名称
        d.producer,                                     -- 生产商
        d.create_time::timestamp AS create_time,        -- 创建时间
        d.create_time::timestamp AS update_time         -- 更新时间(CSV中无此字段,使用create_time)
    FROM {{ ref('ods_order_inbound_detail') }} d
    WHERE d.create_time IS NOT NULL
),

src_header AS (
    SELECT
        inbound_id,
        tenant_id,
        order_status
    FROM {{ ref('dwd_wms_inbound_fact_i') }}
)

SELECT
    d.inbound_detail_id,
    d.inbound_id,
    d.inbound_no,
    d.sku_id,
    d.sku_name,
    d.batch_no,
    d.plan_num,
    d.num,
    d.plan_weight,
    d.weight,
    d.recheck_weight,
    d.price,
    d.amount,
    d.warehouse_area_id,
    d.warehouse_area_name,
    d.warehouse_position_id,
    d.warehouse_position_name,
    d.production_date,
    d.quality_days,
    d.is_deleted,
    d.category_id,
    d.category_name,
    d.producer,
    h.tenant_id,
    h.order_status,
    d.create_time,
    d.update_time
FROM src_detail d
LEFT JOIN src_header h ON d.inbound_id = h.inbound_id

-- {% if is_incremental() %}
-- WHERE d.create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
