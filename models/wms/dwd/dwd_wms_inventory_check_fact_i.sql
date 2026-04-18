-- =============================================
-- 模型名称：dwd_wms_inventory_check_fact_i
-- 模型描述：库存盘点表，记录库存盘点任务级别的增量事务数据
-- Dbt更新方式：增量（事件级）
-- 粒度：check_id
-- 说明：
--   - 数据源：ods_make_inventory（盘点单表）
--   - 增量策略：按 check_id 增量追加
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='check_id',
    description='库存盘点表，记录库存盘点任务级别的增量事务数据',
    tags=['wms', 'dwd', 'trx', 'check']
) }}

WITH src_header AS (
    SELECT
        id AS check_id,                                 -- 盘点单ID
        serial_no,                                      -- 盘点单号
        inventory_no,                                   -- 盘点编号
        make_type AS check_type,                        -- 盘点类型
        warehouse_id,                                   -- 仓库ID
        warehouse_name,                                 -- 仓库名称
        plan_date,                                      -- 计划日期
        customer_id,                                    -- 客户ID
        customer_name,                                  -- 客户名称
        status,                                         -- 状态
        inventory_status,                               -- 盘点状态
        use_pda,                                        -- 是否使用PDA
        is_deleted,                                     -- 删除标记
        remarks AS remark,                              -- 备注
        org_id AS tenant_id,                            -- 租户ID
        org_name AS tenant_name,                        -- 租户名称
        creator_id AS create_by,                        -- 创建人
        creator_name AS create_by_name,                 -- 创建人名称
        create_time::timestamp AS create_time,          -- 创建时间
        over_time,                                      -- 结束时间
        reviewer_id,                                    -- 审核人ID
        reviewer_name,                                  -- 审核人名称
        reviewer_time,                                  -- 审核时间
        operator_id,                                    -- 操作人ID
        operator_name,                                  -- 操作人名称
        operator_time,                                  -- 操作时间
        checker_id,                                     -- 盘点人ID
        checker_name                                    -- 盘点人名称
    FROM {{ ref('ods_make_inventory') }}
    WHERE create_time IS NOT NULL
)

SELECT
    check_id,                                       -- 盘点单ID
    serial_no,                                      -- 盘点单号
    inventory_no,                                   -- 盘点编号
    check_type,                                     -- 盘点类型
    warehouse_id,                                   -- 仓库ID
    warehouse_name,                                 -- 仓库名称
    plan_date,                                      -- 计划日期
    customer_id,                                    -- 客户ID
    customer_name,                                  -- 客户名称
    status,                                         -- 状态
    inventory_status,                               -- 盘点状态
    use_pda,                                        -- 是否使用PDA
    is_deleted,                                     -- 删除标记
    remark,                                         -- 备注
    tenant_id,                                      -- 租户ID
    tenant_name,                                    -- 租户名称
    create_by,                                      -- 创建人
    create_by_name,                                 -- 创建人名称
    create_time,                                    -- 创建时间
    over_time,                                      -- 结束时间
    reviewer_id,                                    -- 审核人ID
    reviewer_name,                                  -- 审核人名称
    reviewer_time,                                  -- 审核时间
    operator_id,                                    -- 操作人ID
    operator_name,                                  -- 操作人名称
    operator_time,                                  -- 操作时间
    checker_id,                                     -- 盘点人ID
    checker_name                                    -- 盘点人名称
FROM src_header

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
