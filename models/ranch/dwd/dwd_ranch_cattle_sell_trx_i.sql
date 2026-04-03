-- =============================================
-- 模型名称：dwd_ranch_cattle_sell_trx_i
-- 模型描述：牧场域牛只销售事务明细表，记录牛只销售的增量交易数据（牛只级别）
-- 作者：dbt
-- 创建时间：2026-04-03
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只销售事务明细表，通过关联销售单和出栏记录实现牛只级别明细（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'sell']
) }}

WITH src_sell AS (
    -- 销售单基础信息
    SELECT
        id AS sell_id,
        code AS sell_code,
        ranch_id,
        customer_id AS downstream_customer_id,
        quantity,
        CAST(sell_cost AS DOUBLE) AS sell_amount,
        sell_date::DATE AS sell_date,
        work_order_no AS sell_order_no,
        create_time::timestamp AS sell_create_time
    FROM {{ ref('ods_psi_cattle_sell') }}
    WHERE create_time IS NOT NULL
),

src_outstall AS (
    -- 出栏记录（牛只级别）
    SELECT
        id,
        sell_id,
        livestock_id AS cattle_id,
        code AS cattle_code,
        outstall_date::DATE AS outstall_date,
        CAST(weight AS DOUBLE) AS weight,
        CAST(price AS DOUBLE) AS price,
        reason,
        out_type,
        tenant_id AS ranch_id,
        CAST(loan_money AS DOUBLE) AS loan_amount,
        investor_id AS customer_id,
        investor_name AS customer_name,
        commodity_id AS sku_id,
        commodity_name AS sku_name,
        status
    FROM {{ ref('ods_ranch_outstall') }}
    WHERE id IS NOT NULL
),

-- 获取栏舍信息（从在栏牛只表关联获取）
src_cattle_stall AS (
    SELECT
        code AS cattle_code,
        stall_id,
        tenant_id AS ranch_id
    FROM {{ ref('ods_ranch_onstall') }}
    WHERE stall_id IS NOT NULL
),

sell_detail AS (
    -- 关联销售单和出栏记录，生成牛只级别销售明细
    SELECT
        outstall.id AS outstall_id,                           -- 出栏记录ID
        outstall.sell_id,                                     -- 销售单ID
        sell.sell_code,                                       -- 销售单号
        sell.sell_date,                                       -- 销售日期
        outstall.cattle_id,                                   -- 牛只ID
        outstall.cattle_code,                                 -- 牛只编号
        cattle_stall.stall_id,                                -- 栏舍ID
        sell.ranch_id,                                        -- 牧场ID
        outstall.weight,                                      -- 出栏重量
        outstall.price,                                       -- 销售单价
        (outstall.weight * COALESCE(outstall.price, 0)) AS total_amount,     -- 销售总额
        sell.downstream_customer_id,                          -- 下游客户ID（买家）
        outstall.reason,                                      -- 出栏原因
        outstall.out_type,                                    -- 出栏类型
        sell.quantity,                                        -- 销售数量（批次）
        sell.sell_amount,                                     -- 销售成本（批次）
        sell.sell_order_no,                                   -- 工单号
        outstall.loan_amount,                                 -- 贷款金额
        outstall.customer_id,                                 -- 投资人ID
        outstall.customer_name,                               -- 投资人名称
        outstall.sku_id,                                      -- 商品ID
        outstall.sku_name,                                    -- 商品名称
        outstall.status,                                      -- 状态
        outstall.outstall_date,                               -- 出栏日期
        sell.sell_create_time AS create_time,                 -- 创建时间
        sell.sell_create_time AS update_time                  -- 更新时间
    FROM src_outstall outstall
    LEFT JOIN src_sell sell ON outstall.sell_id = sell.sell_id
    LEFT JOIN src_cattle_stall cattle_stall ON CAST(outstall.cattle_code AS VARCHAR) = CAST(cattle_stall.cattle_code AS VARCHAR)
)

SELECT
    outstall_id,                                    -- 出栏记录ID
    sell_id,                                        -- 销售单ID
    sell_code,                                      -- 销售单号
    sell_date,                                      -- 销售日期
    cattle_id,                                      -- 牛只ID
    cattle_code,                                    -- 牛只编号
    stall_id,                                       -- 栏舍ID
    ranch_id,                                       -- 牧场ID
    weight,                                         -- 出栏重量
    price,                                          -- 销售单价
    total_amount,                                   -- 销售总额
    downstream_customer_id,                         -- 客户ID（买家）
    reason,                                         -- 出栏原因
    out_type,                                       -- 出栏类型
    quantity,                                       -- 销售数量（批次）
    sell_amount,                                    -- 销售成本（批次）
    sell_order_no,                                  -- 工单号
    loan_amount,                                    -- 贷款金额
    customer_id,                                    -- 投资人ID
    customer_name,                                  -- 投资人名称
    sku_id,                                         -- 商品ID
    sku_name,                                       -- 商品名称
    status,                                         -- 状态
    outstall_date,                                  -- 出栏日期
    create_time,                                    -- 创建时间
    update_time                                     -- 更新时间
FROM sell_detail

-- {% if is_incremental() %}
-- WHERE create_time > (SELECT COALESCE(MAX(create_time), '1900-01-01'::timestamp) FROM {{ this }})
-- {% endif %}