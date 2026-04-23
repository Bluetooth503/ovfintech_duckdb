-- =============================================
-- 模型名称：dwd_wms_outbound_detail_fact_i
-- 模型描述：出库单明细表，记录出库SKU级别的增量事务数据
-- Dbt更新方式：增量（事件级）
-- 粒度：outbound_detail_id
-- 说明：
--   - 数据源：ods_order_outbound_detail（出库明细表）
--   - 增量策略：按 outbound_detail_id 增量追加
--   - 关联逻辑：LEFT JOIN 出库单头表补充 tenant_id
--   - 衍生字段：amount = charge_num * outbound_price
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='outbound_detail_id',
    description='出库单明细表，记录出库SKU级别的增量事务数据',
    tags=['wms', 'dwd', 'trx', 'outbound', 'detail']
) }}

WITH src_detail AS (
    SELECT
        d.id AS outbound_detail_id,
        d.outbound_id,
        d.inventory_id AS outbound_no,
        d.sku_id,
        d.sku_name,
        d.batch_no,
        CASE WHEN d.plan_charge_num ~ '^[0-9]+\.?[0-9]*$' THEN d.plan_charge_num::DOUBLE ELSE NULL END AS plan_num,
        CASE WHEN d.charge_num ~ '^[0-9]+\.?[0-9]*$' THEN d.charge_num::DOUBLE ELSE NULL END AS num,
        CASE WHEN d.plan_weight_num ~ '^[0-9]+\.?[0-9]*$' THEN d.plan_weight_num::DOUBLE ELSE NULL END AS plan_weight,
        CASE WHEN d.actual_weight_num ~ '^[0-9]+\.?[0-9]*$' THEN d.actual_weight_num::DOUBLE ELSE NULL END AS weight,
        CASE WHEN d.recheck_weight_num ~ '^[0-9]+\.?[0-9]*$' THEN d.recheck_weight_num::DOUBLE ELSE NULL END AS recheck_weight,
        CASE WHEN d.outbound_price ~ '^[0-9]+\.?[0-9]*$' THEN d.outbound_price::DOUBLE ELSE NULL END AS price,
        COALESCE(CASE WHEN d.charge_num ~ '^[0-9]+\.?[0-9]*$' THEN d.charge_num::DOUBLE ELSE NULL END, 0)
            * COALESCE(CASE WHEN d.outbound_price ~ '^[0-9]+\.?[0-9]*$' THEN d.outbound_price::DOUBLE ELSE NULL END, 0) AS amount,
        d.warehouse_area_id,
        d.warehouse_area_name,
        d.warehouse_position_id,
        d.warehouse_position_name,
        d.category_id,
        d.category_name,
        d.is_deleted,
        d.remarks AS remark,
        CASE WHEN d.create_time ~ '^\d{4}-\d{2}-\d{2}' THEN d.create_time::timestamp ELSE NULL END AS create_time,
        CASE WHEN d.create_time ~ '^\d{4}-\d{2}-\d{2}' THEN d.create_time::timestamp ELSE NULL END AS update_time
    FROM {{ ref('ods_order_outbound_detail') }} d
    WHERE d.create_time IS NOT NULL
),

src_header AS (
    SELECT
        outbound_id,
        tenant_id,
        order_status
    FROM {{ ref('dwd_wms_outbound_fact_i') }}
)

SELECT
    d.outbound_detail_id,
    d.outbound_id,
    d.outbound_no,
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
    d.category_id,
    d.category_name,
    d.is_deleted,
    d.remark,
    h.tenant_id,
    h.order_status,
    d.create_time,
    d.update_time
FROM src_detail d
LEFT JOIN src_header h ON d.outbound_id = h.outbound_id

-- {% if is_incremental() %}
-- WHERE d.create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
