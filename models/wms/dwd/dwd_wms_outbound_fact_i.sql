-- =============================================
-- 模型名称：dwd_wms_outbound_fact_i
-- 模型描述：出库单表，记录出库订单级别的增量事务数据
-- Dbt更新方式：增量（事件级）
-- 粒度：outbound_id
-- 说明：
--   - 数据源：ods_order_outbound（出库单表）
--   - 增量策略：按 outbound_id 增量追加
--   - 关键字段：覆盖单号、状态、审核/操作人、资金代理方等
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
        serial_no,                                      -- 流水号
        outbound_no,                                    -- 出库单号
        order_type,                                     -- 订单类型
        order_status,                                   -- 订单状态
        storage_status,                                 -- 出库状态
        use_pda,                                        -- 是否使用PDA
        customer_id,                                    -- 客户ID(货主)
        customer_name,                                  -- 客户名称
        warehouse_id,                                   -- 仓库ID
        warehouse_name,                                 -- 仓库名称
        receiver_id AS consignee_id,                    -- 收货方ID
        receiver_name AS consignee_name,                -- 收货方名称
        plan_date,                                      -- 计划日期
        over_time AS finish_date,                       -- 完成日期
        number_plate AS car_no,                         -- 车牌号
        driver,                                         -- 司机
        phone_number AS driver_phone,                   -- 司机电话
        remarks AS remark,                              -- 备注
        is_deleted,                                     -- 删除标记
        org_id AS tenant_id,                            -- 租户ID
        org_name AS tenant_name,                        -- 租户名称
        creator_id AS create_by,                        -- 创建人
        creator_name AS create_by_name,                 -- 创建人名称
        create_time::timestamp AS create_time,          -- 创建时间
        update_time::timestamp AS update_time,          -- 更新时间
        reviewer_id,                                    -- 审核人ID
        reviewer_name,                                  -- 审核人名称
        reviewer_time::timestamp AS reviewer_time,      -- 审核时间
        operator_id,                                    -- 操作人ID
        operator_name,                                  -- 操作人名称
        operator_time::timestamp AS operator_time,      -- 操作时间
        checker_id,                                     -- 盘点人ID
        checker_name,                                   -- 盘点人名称
        fund_agent_id,                                  -- 资金代理方ID
        fund_agent_name,                                -- 资金代理方名称
        approve_type,                                   -- 审批类型
        purchase_id,                                    -- 采购单ID
        purchase_name,                                  -- 采购方名称
        in_warehouse_id,                                -- 入库仓库ID
        in_warehouse_name,                              -- 入库仓库名称
        handling_type                                   -- 装卸类型
    FROM {{ ref('ods_order_outbound') }}
    WHERE create_time IS NOT NULL
)

SELECT
    outbound_id,
    serial_no,
    outbound_no,
    order_type,
    order_status,
    storage_status,
    use_pda,
    customer_id,
    customer_name,
    warehouse_id,
    warehouse_name,
    consignee_id,
    consignee_name,
    plan_date,
    finish_date,
    car_no,
    driver,
    driver_phone,
    remark,
    is_deleted,
    tenant_id,
    tenant_name,
    create_by,
    create_by_name,
    create_time,
    update_time,
    reviewer_id,
    reviewer_name,
    reviewer_time,
    operator_id,
    operator_name,
    operator_time,
    checker_id,
    checker_name,
    fund_agent_id,
    fund_agent_name,
    approve_type,
    purchase_id,
    purchase_name,
    in_warehouse_id,
    in_warehouse_name,
    handling_type
FROM src_header

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
