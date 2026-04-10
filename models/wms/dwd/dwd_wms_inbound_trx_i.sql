-- =============================================
-- 模型名称：dwd_wms_inbound_trx_i
-- 模型描述：入库单表，记录入库订单级别的增量事务数据
-- 作者：dbt
-- 创建时间：2026-04-08
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='inbound_id',
    description='入库单表，记录入库订单级别的增量事务数据',
    tags=['wms', 'dwd', 'trx', 'inbound']
) }}

WITH src_header AS (
    SELECT
        id AS inbound_id,                               -- 入库单ID
        inbound_no,                                     -- 入库单号
        order_type,                                     -- 订单类型
        storage_status,                                 -- 入库状态
        customer_id,                                    -- 客户ID(货主)
        warehouse_id,                                   -- 仓库ID
        provider_id,                                    -- 供应商ID
        plan_date,                                      -- 计划日期
        over_time AS finish_date,                       -- 完成日期(over_time)
        remarks AS remark,                              -- 备注
        is_deleted,                                     -- 删除标记
        org_id AS tenant_id,                            -- 租户ID
        creator_id AS create_by,                        -- 创建人
        create_time::timestamp AS create_time,          -- 创建时间
        COALESCE(update_time::timestamp, create_time::timestamp) AS update_time  -- 更新时间
    FROM {{ ref('ods_order_inbound') }}
    WHERE create_time IS NOT NULL
)

SELECT
    inbound_id,                                     -- 入库单ID
    inbound_no,                                     -- 入库单号
    order_type,                                     -- 订单类型
    storage_status,                                 -- 入库状态
    customer_id,                                    -- 客户ID(货主)
    warehouse_id,                                   -- 仓库ID
    provider_id,                                    -- 供应商ID
    plan_date,                                      -- 计划日期
    finish_date,                                    -- 完成日期
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
