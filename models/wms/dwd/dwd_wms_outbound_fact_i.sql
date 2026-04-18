-- =============================================
-- 模型名称：dwd_wms_outbound_fact_i
-- 模型描述：出库单表，记录出库订单级别的增量事务数据
-- Dbt更新方式：增量（事件级）
-- 粒度：outbound_id
-- 说明：
--   - 数据源：ods_order_outbound（出库单表）
--   - 增量策略：按 outbound_id 增量追加
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='outbound_id',
    description='出库单表，记录出库订单级别的增量事务数据',
    tags=['wms', 'dwd', 'trx', 'outbound']
) }}

WITH src_header AS (
    SELECT
        id AS outbound_id,                              -- 出库单ID
        outbound_no,                                    -- 出库单号
        order_type,                                     -- 订单类型
        storage_status,                                 -- 出库状态
        customer_id,                                    -- 客户ID(货主)
        warehouse_id,                                   -- 仓库ID
        receiver_id AS consignee_id,                    -- 收货方ID
        plan_date,                                      -- 计划日期
        over_time AS finish_date,                       -- 完成日期(over_time)
        number_plate AS car_no,                         -- 车牌号
        driver,                                         -- 司机
        phone_number AS driver_phone,                   -- 司机电话
        remarks AS remark,                              -- 备注
        is_deleted,                                     -- 删除标记
        org_id AS tenant_id,                            -- 租户ID
        creator_id AS create_by,                        -- 创建人
        create_time::timestamp AS create_time,          -- 创建时间
        COALESCE(update_time::timestamp, create_time::timestamp) AS update_time  -- 更新时间
    FROM {{ ref('ods_order_outbound') }}
    WHERE create_time IS NOT NULL
)

SELECT
    outbound_id,                                    -- 出库单ID
    outbound_no,                                    -- 出库单号
    order_type,                                     -- 订单类型
    storage_status,                                 -- 出库状态
    customer_id,                                    -- 客户ID(货主)
    warehouse_id,                                   -- 仓库ID
    consignee_id,                                   -- 收货方ID
    plan_date,                                      -- 计划日期
    finish_date,                                    -- 完成日期
    car_no,                                         -- 车牌号
    driver,                                         -- 司机
    driver_phone,                                   -- 司机电话
    remark,                                         -- 备注
    is_deleted,                                     -- 删除标记
    tenant_id,                                      -- 租户ID
    create_by,                                      -- 创建人
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM src_header

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
