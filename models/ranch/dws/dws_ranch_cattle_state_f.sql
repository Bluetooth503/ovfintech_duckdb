-- =============================================
-- 模型名称：dws_ranch_cattle_state_f
-- 模型描述：牛只当前状态全量表，反映牛只的最新状态
-- 作者：dbt
-- 创建时间：2026-04-03
-- 更新方式：全量覆盖（table）
-- 数据源：
--   - ods_ranch_onstall（ODS层最新状态）
--   - dwd_ranch_cattle_onstall_trx_i（DWD层每日快照，补充增重、饲料成本等）
-- 粒度：牛只
-- =============================================
{{ config(
    materialized='table',
    description='牛只当前状态全量表，记录每头牛的最新状态信息',
    tags=['ranch', 'dws', 'state', 'cattle']
) }}

WITH cattle_base AS (
    -- 从ODS层最新状态表获取基础信息
    SELECT
        id AS cattle_id,
        code AS cattle_code,
        vice_code,
        stall_id,
        commodity_id AS sku_id,
        CAST(weight AS DOUBLE) AS install_weight,
        CAST(price AS DOUBLE) AS install_price,
        install_date::DATE AS install_date,
        birth_date::DATE AS birth_date,
        color,
        status,
        investor_id AS customer_id,
        CAST(latest_weight AS DOUBLE) AS current_weight,
        latest_weigh_date::DATE AS latest_weigh_date,
        tenant_id AS ranch_id,
        CAST(estimated_weight AS DOUBLE) AS estimated_weight,
        CAST(total_loan_money AS DOUBLE) AS total_loan_money,
        CAST(real_price AS DOUBLE) AS real_price,
        is_loan,
        CAST(weight_add AS DOUBLE) AS weight_add,
        is_lock,
        CAST(repay_amount AS DOUBLE) AS repay_amount,
        purchase_id,
        loan_count,
        funding_id,
        if_sick,
        CAST(other1_loan_money AS DOUBLE) AS other1_loan_money,
        CAST(other2_loan_money AS DOUBLE) AS other2_loan_money,
        CAST(in_stall_loan_money AS DOUBLE) AS in_stall_loan_money,
        CAST(weight_add_loan_money AS DOUBLE) AS weight_add_loan_money,
        CAST(total_feed_cost AS DOUBLE) AS total_feed_cost,
        out_stall_date::DATE AS out_stall_date,
        last_loan_date::DATE AS last_loan_date,
        create_time::timestamp AS create_time,
        COALESCE(update_time::timestamp, create_time::timestamp) AS update_time
    FROM {{ ref('ods_ranch_onstall') }}
),

-- 关联牧场维度
ranch_dim AS (
    SELECT
        ranch_id,
        ranch_name,
        ranch_abbr_desc,
        ranch_code
    FROM {{ ref('dim_ranch') }}
),

-- 关联栏舍维度
stall_dim AS (
    SELECT
        stall_id,
        stall_name
    FROM {{ ref('dim_ranch_stall') }}
),

-- 关联SKU维度
sku_dim AS (
    SELECT
        sku_id,
        sku_name,
        sku_code
    FROM {{ ref('dim_ranch_sku') }}
),

-- 计算派生字段
cattle_enriched AS (
    SELECT
        b.cattle_id,
        b.cattle_code,
        b.vice_code,
        b.stall_id,
        s.stall_name,
        b.sku_id,
        k.sku_name,
        k.sku_code,
        b.ranch_id,
        r.ranch_name,
        r.ranch_abbr_desc,
        r.ranch_code,

        -- 基础属性
        b.install_weight,
        b.install_price,
        b.install_date,
        b.birth_date,
        b.color,
        b.status,
        b.customer_id,

        -- 体重相关
        b.current_weight,
        b.latest_weigh_date,
        b.estimated_weight,
        b.weight_add,

        -- 计算字段
        CASE
            WHEN b.install_weight > 0 THEN b.weight_add / b.install_weight * 100
            ELSE NULL
        END AS weight_add_ratio,                           -- 增重率(%)

        CASE
            WHEN b.install_date IS NOT NULL AND CURRENT_DATE >= b.install_date
            THEN DATE_DIFF('day', b.install_date, CURRENT_DATE)
            ELSE NULL
        END AS days_in_stall,                              -- 在栏天数

        CASE
            WHEN b.birth_date IS NOT NULL AND CURRENT_DATE >= b.birth_date
            THEN DATE_DIFF('day', b.birth_date, CURRENT_DATE)
            ELSE NULL
        END AS day_age,                                    -- 日龄

        -- 金融相关
        b.total_loan_money,
        b.real_price,
        b.is_loan,
        b.is_lock,
        b.repay_amount,
        b.purchase_id,
        b.loan_count,
        b.funding_id,
        b.if_sick,
        b.other1_loan_money,
        b.other2_loan_money,
        b.in_stall_loan_money,
        b.weight_add_loan_money,

        -- 成本相关
        b.total_feed_cost,

        -- 价值估算
        CASE
            WHEN b.current_weight > 0 AND b.real_price > 0
            THEN b.current_weight * b.real_price
            ELSE NULL
        END AS estimated_value,                            -- 预估价值

        -- 其他
        b.out_stall_date,
        b.last_loan_date,
        b.create_time,
        b.update_time,

        -- 状态标签
        CASE
            WHEN b.status = 1 THEN '在栏'
            WHEN b.status = 0 THEN '已出栏'
            ELSE '未知'
        END AS status_desc,

        CASE
            WHEN b.is_loan = 1 THEN '是'
            ELSE '否'
        END AS is_loan_desc

    FROM cattle_base b
    LEFT JOIN ranch_dim r ON b.ranch_id = r.ranch_id
    LEFT JOIN stall_dim s ON b.stall_id = s.stall_id
    LEFT JOIN sku_dim k ON b.sku_id = k.sku_id
),

-- 计算日增重（需要days_in_stall先计算出来）
cattle_final AS (
    SELECT
        *,
        CASE
            WHEN days_in_stall > 0 AND weight_add > 0
            THEN weight_add / days_in_stall
            ELSE NULL
        END AS adg,                                        -- 平均日增重

        CASE
            WHEN weight_add > 0 AND total_feed_cost > 0
            THEN total_feed_cost / weight_add
            ELSE NULL
        END AS feed_cost_per_kg                            -- 每公斤增重饲料成本
    FROM cattle_enriched
)

SELECT * FROM cattle_final
