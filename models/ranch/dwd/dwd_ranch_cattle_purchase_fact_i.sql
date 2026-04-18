-- =============================================
-- 模型名称：dwd_ranch_cattle_purchase_fact_i
-- 模型描述：牧场域牛只采购事务明细表，记录牛只采购的增量交易数据（牛只级别）
-- Dbt更新方式：增量（事件级）
-- 粒度：cattle_id + purchase_id
-- 说明：
--   - 数据源：ods_ranch_purchase（采购表）、ods_ranch_install（入栏表）
--   - 增量策略：按 id 增量追加
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只采购事务明细表，通过关联采购单和入栏记录实现牛只级别明细（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'purchase']
) }}

WITH src_purchase AS (
    -- 采购单基础信息
    SELECT
        id AS purchase_id,
        code AS purchase_code,
        customer_id AS upstream_customer_id,
        investor_id AS customer_id,
        quantity,
        CAST(purchase_cost AS DOUBLE) AS purchase_amount,
        purchase_date::DATE AS purchase_date,
        create_time::timestamp AS purchase_create_time
    FROM {{ ref('ods_psi_cattle_purchase') }}
    WHERE create_time IS NOT NULL
),

src_install AS (
    -- 入栏记录（牛只级别）
    SELECT
        id,
        purchase_id,
        code AS cattle_code,
        vice_code,
        stall_id,
        commodity_id AS sku_id,
        CAST(weight AS DOUBLE) AS weight,
        CAST(price AS DOUBLE) AS price,
        CAST(total_price AS DOUBLE) AS total_price,
        install_date::DATE AS install_date,
        tenant_id AS  ranch_id,
        create_time::timestamp AS install_create_time
    FROM {{ ref('ods_ranch_install') }}
    WHERE create_time IS NOT NULL
    -- 过滤掉没有关联采购单的记录（如直接入栏的牛）
    AND purchase_id IS NOT NULL
),

purchase_detail AS (
    -- 关联采购单和入栏记录，生成牛只级别采购明细
    SELECT
        install.id AS install_id,                              -- 入栏记录ID
        install.purchase_id,                                   -- 采购单ID
        purchase.purchase_code,                                -- 采购单号
        purchase.purchase_date,                                -- 采购日期
        install.cattle_code,                                   -- 牛只编号
        install.vice_code,                                     -- 副编号
        install.stall_id,                                      -- 栏舍ID
        install.sku_id,                                        -- 商品ID
        install.weight,                                        -- 入栏重量
        install.price,                                         -- 单价
        install.total_price,                                   -- 总价
        install.install_date,                                  -- 入栏日期
        purchase.upstream_customer_id,                         -- 上游客户ID（供应商）
        purchase.customer_id,                                  -- 客户ID（投资人）
        purchase.quantity,                                     -- 采购数量（批次）
        purchase.purchase_amount,                              -- 采购成本（批次）
        install.ranch_id,                                      -- 牧场ID
        COALESCE(install.install_create_time, purchase.purchase_create_time) AS create_time,  -- 创建时间
        COALESCE(install.install_create_time, purchase.purchase_create_time) AS update_time   -- 更新时间
    FROM src_install install
    LEFT JOIN src_purchase purchase ON install.purchase_id = purchase.purchase_id
)

SELECT
    install_id,                                     -- 入栏记录ID
    purchase_id,                                    -- 采购单ID
    purchase_code,                                  -- 采购单号
    purchase_date,                                  -- 采购日期
    cattle_code,                                    -- 牛只编号
    vice_code,                                      -- 副编号
    stall_id,                                       -- 栏舍ID
    sku_id,                                         -- 商品ID
    weight,                                         -- 入栏重量
    price,                                          -- 单价
    total_price,                                    -- 总价
    install_date,                                   -- 入栏日期
    upstream_customer_id,                           -- 上游客户ID（供应商）
    customer_id,                                    -- 客户ID（投资人）
    quantity,                                       -- 采购数量（批次）
    purchase_amount,                                -- 采购成本（批次）
    ranch_id,                                       -- 租户ID
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM purchase_detail

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}
