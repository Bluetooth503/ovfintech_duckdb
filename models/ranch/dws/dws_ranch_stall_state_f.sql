-- =============================================
-- 模型名称：dws_ranch_stall_state_f
-- 模型描述：栏舍当前状态全量表，反映栏舍的最新状态
-- 作者：dbt
-- 创建时间：2026-04-03
-- 更新方式：全量覆盖（table）
-- =============================================
{{ config(
    materialized='table',
    description='栏舍当前状态全量表，记录每个栏舍的最新状态信息及牛只汇总统计',
    tags=['ranch', 'dws', 'state', 'stall']
) }}

WITH stall_base AS (
    -- 从栏舍表获取基础信息
    SELECT
        id AS stall_id,
        name AS stall_name,
        stock_man AS feeder_name,
        recipe_id,
        recipe_name,
        tenant_id AS ranch_id,
        area_name AS region_name,
        area_id AS region_id,
        real_count AS real_cattle_count,
        CAST(total_weight AS DOUBLE) AS total_cattle_weight,
        CAST(weight AS DOUBLE) AS unit_weight,
        type AS stall_type,
        investor_id AS customer_id,
        name_sort AS sort_order,
        CAST(morning_one_weight AS DOUBLE) AS morning_feed_weight,
        CAST(noon_one_weight AS DOUBLE) AS noon_feed_weight,
        CAST(night_one_weight AS DOUBLE) AS night_feed_weight,
        CAST(recipe_total_weight AS DOUBLE) AS recipe_total_weight,
        system_cattle_num,
        CAST(morning_one_value AS DOUBLE) AS morning_feed_value,
        CAST(noon_one_value AS DOUBLE) AS noon_feed_value,
        CAST(night_one_value AS DOUBLE) AS night_feed_value,
        deleted,
        create_time::timestamp AS create_time,
        COALESCE(update_time::timestamp, create_time::timestamp) AS update_time
    FROM {{ ref('ods_ranch_stall') }}
    WHERE deleted = 0
),

-- 关联牧场维度
ranch_dim AS (
    SELECT
        ranch_id,
        ranch_name,
        ranch_code
    FROM {{ ref('dim_ranch') }}
),

-- 关联配方维度
recipe_dim AS (
    SELECT
        recipe_id,
        recipe_name,
        feed_meat_ratio AS target_feed_ratio
    FROM {{ ref('dim_ranch_recipe') }}
),

-- 从牛只状态表聚合栏舍级别的统计
cattle_stats AS (
    SELECT
        stall_id,
        COUNT(*) AS cattle_count,                           -- 在栏牛只数
        SUM(current_weight) AS total_current_weight,        -- 当前总重量
        AVG(current_weight) AS avg_current_weight,          -- 平均体重
        SUM(install_weight) AS total_install_weight,        -- 入栏总重量
        SUM(weight_add) AS total_weight_add,                -- 总增重
        AVG(weight_add) AS avg_weight_add,                  -- 平均增重
        SUM(total_loan_money) AS total_loan_money,          -- 总贷款金额
        SUM(estimated_value) AS total_estimated_value,      -- 总预估价值
        SUM(total_feed_cost) AS total_feed_cost,            -- 总饲料成本
        SUM(CASE WHEN is_loan = 1 THEN 1 ELSE 0 END) AS loan_cattle_count,  -- 贷款牛只数
        SUM(CASE WHEN if_sick = 1 THEN 1 ELSE 0 END) AS sick_cattle_count   -- 病牛数
    FROM {{ ref('dws_ranch_cattle_state_f') }}
    GROUP BY stall_id
),

-- 合并所有信息
stall_enriched AS (
    SELECT
        s.stall_id,
        s.stall_name,
        s.feeder_name,
        s.recipe_id,
        s.recipe_name,
        rec.target_feed_ratio,
        s.ranch_id,
        r.ranch_name,
        r.ranch_code,
        s.region_name,
        s.region_id,
        s.stall_type,
        s.customer_id,
        s.sort_order,

        -- 栏舍配置信息
        s.recipe_total_weight,
        s.morning_feed_weight,
        s.noon_feed_weight,
        s.night_feed_weight,
        s.morning_feed_value,
        s.noon_feed_value,
        s.night_feed_value,

        -- 系统统计（来自栏舍表）
        s.system_cattle_num,
        s.real_cattle_count,
        s.total_cattle_weight,
        s.unit_weight,

        -- 牛只聚合统计
        COALESCE(c.cattle_count, 0) AS cattle_count,
        COALESCE(c.total_current_weight, 0) AS total_current_weight,
        COALESCE(c.avg_current_weight, 0) AS avg_current_weight,
        COALESCE(c.total_install_weight, 0) AS total_install_weight,
        COALESCE(c.total_weight_add, 0) AS total_weight_add,
        COALESCE(c.avg_weight_add, 0) AS avg_weight_add,
        COALESCE(c.total_loan_money, 0) AS total_loan_money,
        COALESCE(c.total_estimated_value, 0) AS total_estimated_value,
        COALESCE(c.total_feed_cost, 0) AS total_feed_cost,
        COALESCE(c.loan_cattle_count, 0) AS loan_cattle_count,
        COALESCE(c.sick_cattle_count, 0) AS sick_cattle_count,

        -- 计算字段
        CASE
            WHEN c.total_install_weight > 0
            THEN (c.total_current_weight - c.total_install_weight) / c.total_install_weight * 100
            ELSE NULL
        END AS total_weight_add_ratio,                      -- 总增重率(%)

        CASE
            WHEN c.cattle_count > 0 AND c.total_weight_add > 0
            THEN c.total_weight_add / c.cattle_count
            ELSE NULL
        END AS avg_adg,                                     -- 平均日增重(简化)

        CASE
            WHEN c.total_weight_add > 0 AND c.total_feed_cost > 0
            THEN c.total_feed_cost / c.total_weight_add
            ELSE NULL
        END AS actual_feed_ratio,                           -- 实际料肉比

        CASE
            WHEN s.recipe_total_weight > 0
            THEN COALESCE(c.total_current_weight, 0) / s.recipe_total_weight * 100
            ELSE NULL
        END AS capacity_utilization,                        -- 容量利用率(%)

        CASE
            WHEN c.cattle_count > 0
            THEN CAST(c.loan_cattle_count AS DOUBLE) / c.cattle_count * 100
            ELSE 0
        END AS loan_cattle_ratio,                           -- 质押牛只比例(%)

        s.create_time,
        s.update_time

    FROM stall_base s
    LEFT JOIN ranch_dim r ON s.ranch_id = r.ranch_id
    LEFT JOIN recipe_dim rec ON s.recipe_id = rec.recipe_id
    LEFT JOIN cattle_stats c ON s.stall_id = c.stall_id
)

SELECT * FROM stall_enriched
