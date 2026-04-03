-- =============================================
-- 模型名称：dws_ranch_cattle_balance_agg_1d_d
-- 模型描述：在栏牛只日统计表，按牧场/栏舍维度统计在栏牛只情况
-- 作者：dbt
-- 创建时间：2026-04-03
-- 更新方式：增量（按日期）
-- 粒度：牧场 + 栏舍 + 日期
-- =============================================
{{ config(
    materialized='incremental',
    unique_key='ranch_id,stall_id,stat_date',
    description='在栏牛只日统计表，按牧场、栏舍维度统计在栏牛只的数量、重量、价值等',
    tags=['ranch', 'dws', 'agg', 'cattle', 'balance', 'daily']
) }}

WITH cattle_state AS (
    SELECT
        cattle_id,
        stall_id,
        ranch_id,
        sku_id,
        customer_id,
        status,
        current_weight,
        install_weight,
        weight_add,
        total_loan_money,
        estimated_value,
        total_feed_cost,
        is_loan,
        if_sick,
        install_date,
        update_time
    FROM {{ ref('dws_ranch_cattle_state_f') }}
),

-- 按牧场+栏舍+SKU维度聚合
balance_agg AS (
    SELECT
        ranch_id,
        stall_id,
        sku_id,
        customer_id,

        -- 数量统计
        COUNT(*) AS total_cattle_count,                     -- 总牛只数
        SUM(CASE WHEN status = 1 THEN 1 ELSE 0 END) AS instock_count,      -- 在栏数
        SUM(CASE WHEN is_loan = 1 THEN 1 ELSE 0 END) AS loan_cattle_count, -- 质押数
        SUM(CASE WHEN if_sick = 1 THEN 1 ELSE 0 END) AS sick_cattle_count, -- 病牛数

        -- 重量统计
        SUM(COALESCE(current_weight, 0)) AS total_current_weight,    -- 当前总重量
        AVG(current_weight) AS avg_current_weight,                   -- 平均体重
        SUM(COALESCE(install_weight, 0)) AS total_install_weight,    -- 入栏总重量
        SUM(COALESCE(weight_add, 0)) AS total_weight_add,            -- 总增重
        AVG(weight_add) AS avg_weight_add,                           -- 平均增重

        -- 价值统计
        SUM(COALESCE(estimated_value, 0)) AS total_estimated_value,  -- 总预估价值
        SUM(COALESCE(total_loan_money, 0)) AS total_loan_money,      -- 总贷款金额
        SUM(COALESCE(total_feed_cost, 0)) AS total_feed_cost,        -- 总饲料成本

        -- 计算字段
        CASE
            WHEN SUM(install_weight) > 0
            THEN SUM(weight_add) / SUM(install_weight) * 100
            ELSE NULL
        END AS weight_add_ratio,                           -- 增重率(%)

        CASE
            WHEN SUM(weight_add) > 0 AND SUM(total_feed_cost) > 0
            THEN SUM(total_feed_cost) / SUM(weight_add)
            ELSE NULL
        END AS feed_cost_per_kg,                           -- 每公斤增重成本

        CURRENT_DATE AS stat_date,
        CURRENT_TIMESTAMP AS dw_update_time

    FROM cattle_state
    GROUP BY ranch_id, stall_id, sku_id, customer_id
),

-- 关联维度获取名称
ranch_dim AS (
    SELECT ranch_id, ranch_name FROM {{ ref('dim_ranch') }}
),

stall_dim AS (
    SELECT stall_id, stall_name FROM {{ ref('dim_ranch_stall') }}
),

sku_dim AS (
    SELECT sku_id, sku_name FROM {{ ref('dim_ranch_sku') }}
)

SELECT
    b.stat_date,
    b.ranch_id,
    r.ranch_name,
    b.stall_id,
    s.stall_name,
    b.sku_id,
    k.sku_name,
    b.customer_id,

    -- 数量统计
    b.total_cattle_count,
    b.instock_count,
    b.loan_cattle_count,
    b.sick_cattle_count,

    -- 重量统计
    ROUND(b.total_current_weight, 2) AS total_current_weight,
    ROUND(b.avg_current_weight, 2) AS avg_current_weight,
    ROUND(b.total_install_weight, 2) AS total_install_weight,
    ROUND(b.total_weight_add, 2) AS total_weight_add,
    ROUND(b.avg_weight_add, 2) AS avg_weight_add,

    -- 价值统计
    ROUND(b.total_estimated_value, 2) AS total_estimated_value,
    ROUND(b.total_loan_money, 2) AS total_loan_money,
    ROUND(b.total_feed_cost, 2) AS total_feed_cost,

    -- 计算字段
    ROUND(b.weight_add_ratio, 2) AS weight_add_ratio,
    ROUND(b.feed_cost_per_kg, 2) AS feed_cost_per_kg,

    -- 质押率
    CASE
        WHEN b.total_estimated_value > 0 AND b.total_loan_money > 0
        THEN ROUND(b.total_loan_money / b.total_estimated_value * 100, 2)
        ELSE NULL
    END AS pledge_ratio,

    b.dw_update_time

FROM balance_agg b
LEFT JOIN ranch_dim r ON b.ranch_id = r.ranch_id
LEFT JOIN stall_dim s ON b.stall_id = s.stall_id
LEFT JOIN sku_dim k ON b.sku_id = k.sku_id

{% if is_incremental() %}
WHERE b.stat_date > (SELECT COALESCE(MAX(stat_date), '1900-01-01') FROM {{ this }})
{% endif %}
