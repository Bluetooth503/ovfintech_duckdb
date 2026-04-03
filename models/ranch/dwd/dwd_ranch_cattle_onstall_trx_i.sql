-- =============================================
-- 模型名称：dwd_ranch_cattle_onstall_trx_i
-- 模型描述：牧场域牛只在栏状态事务明细表，记录牛只每日状态快照
-- 作者：dbt
-- 创建时间：2026-04-03
-- 数据源：ods_ranch_onstall_history（每日快照）
-- 粒度：牛只 + 快照日期
-- 更新方式：增量追加
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='id',
    description='牧场域牛只在栏状态事务明细表，记录牛只每日状态快照数据（增量追加）',
    tags=['ranch', 'dwd', 'trx', 'cattle', 'onstall', 'snap']
) }}

WITH source_onstall AS (
    -- 从历史快照表获取每日在栏状态
    SELECT
        id,
        stall_id,
        code AS cattle_code,
        vice_code,
        commodity_id AS sku_id,
        snap_date::DATE AS snap_date,
        investor_id AS customer_id,
        livestock_id,
        tenant_id AS ranch_id,
        CAST(total_loan_money AS DOUBLE) AS total_loan_money,
        CAST(real_price AS DOUBLE) AS real_price,
        CAST(estimated_weight AS DOUBLE) AS estimated_weight,
        CAST(weight_add AS DOUBLE) AS weight_add,
        CAST(feed_quantity AS DOUBLE) AS feed_quantity,
        CAST(feed_dry_quantity AS DOUBLE) AS feed_dry_quantity,
        is_loan,
        if_sick,
        funding_id,
        purchase_id,
        CAST(other1_loan_money AS DOUBLE) AS other1_loan_money,
        CAST(other2_loan_money AS DOUBLE) AS other2_loan_money,
        CAST(in_stall_loan_money AS DOUBLE) AS in_stall_loan_money,
        CAST(weight_add_loan_money AS DOUBLE) AS weight_add_loan_money,
        CAST(total_feed_cost AS DOUBLE) AS total_feed_cost,
        CAST(feed_cost AS DOUBLE) AS feed_cost,
        CURRENT_TIMESTAMP AS dw_load_time
    FROM {{ ref('ods_ranch_onstall_history') }}
    WHERE snap_date IS NOT NULL
)

SELECT
    id,                                 -- 事务ID (快照记录ID)
    stall_id,                           -- 栏舍ID
    cattle_code,                        -- 牛只编号
    vice_code,                          -- 副编号
    sku_id,                             -- 商品ID/品种
    snap_date,                          -- 快照日期
    customer_id,                        -- 客户ID
    livestock_id,                       -- 牲畜ID
    ranch_id,                           -- 牧场ID
    total_loan_money,                   -- 贷款总额
    real_price,                         -- 实际单价
    estimated_weight,                   -- 预估体重
    weight_add,                         -- 增重
    feed_quantity,                      -- 饲料采食量
    feed_dry_quantity,                  -- 干物质采食量
    is_loan,                            -- 是否贷款
    if_sick,                            -- 是否生病
    funding_id,                         -- 资金方ID
    purchase_id,                        -- 采购单ID
    other1_loan_money,                  -- 其他1贷款
    other2_loan_money,                  -- 其他2贷款
    in_stall_loan_money,                -- 入栏贷款
    weight_add_loan_money,              -- 增重贷款
    total_feed_cost,                    -- 总饲料成本
    feed_cost,                          -- 饲料成本
    dw_load_time                        -- 数据加载时间
FROM source_onstall

{% if is_incremental() %}
WHERE snap_date > (SELECT COALESCE(MAX(snap_date), '1900-01-01'::DATE) FROM {{ this }})
{% endif %}
