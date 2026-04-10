-- =============================================
-- 模型名称：dwd_wms_outbound_detail_trx_i
-- 模型描述：出库单明细表，记录出库SKU级别的增量事务数据
-- 作者：dbt
-- 创建时间：2026-04-08
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='outbound_detail_id',
    description='出库单明细表，记录出库SKU级别的增量事务数据',
    tags=['wms', 'dwd', 'trx', 'outbound', 'detail']
) }}

WITH src_detail AS (
    SELECT
        id AS outbound_detail_id,                       -- 出库明细ID
        outbound_id,                                    -- 出库单ID
        inventory_id AS outbound_no,                    -- 出库单号(冗余)
        sku_id,                                         -- 商品SKU ID
        batch_no,                                       -- 批次号
        plan_charge_num AS num,                         -- 计划数量
        plan_weight_num AS weight,                      -- 计划重量
        outbound_price AS price,                        -- 出库单价
        CAST(NULL AS VARCHAR) AS amount,                -- 金额(CSV中无此字段)
        warehouse_position_id,                          -- 库位ID
        is_deleted,                                     -- 删除标记
        CAST(NULL AS VARCHAR) AS tenant_id,             -- 租户ID(明细表无此字段,可从header表关联获取)
        CASE
            WHEN create_time ~ '^\d{4}-\d{2}-\d{2}' THEN create_time::timestamp
            ELSE NULL
        END AS create_time,                             -- 创建时间
        CASE
            WHEN create_time ~ '^\d{4}-\d{2}-\d{2}' THEN create_time::timestamp
            ELSE NULL
        END AS update_time                              -- 更新时间(CSV中无此字段,使用create_time)
    FROM {{ ref('ods_order_outbound_detail') }}
    WHERE create_time IS NOT NULL
)

SELECT
    outbound_detail_id,                             -- 出库明细ID
    outbound_id,                                    -- 出库单ID
    outbound_no,                                    -- 出库单号(冗余)
    sku_id,                                         -- 商品SKU ID
    batch_no,                                       -- 批次号
    num,                                            -- 数量
    weight,                                         -- 重量
    price,                                          -- 单价
    amount,                                         -- 金额
    warehouse_position_id,                          -- 库位ID
    is_deleted,                                     -- 删除标记
    tenant_id,                                      -- 租户ID
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM src_detail

{% if is_incremental() %}
WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
{% endif %}
