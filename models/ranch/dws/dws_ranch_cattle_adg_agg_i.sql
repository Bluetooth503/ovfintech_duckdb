-- =============================================
-- 模型名称：dws_ranch_cattle_adg_agg_i
-- 模型描述：牧场域牛只ADG区间汇总表（增量），计算区间ADG和料肉比基础指标
-- 作者：dbt
-- 创建时间：2026-04-02
-- 说明：
--   - 粒度：每头牛每个称重日一条记录（每天去重，保留最后一次）
--   - ADG计算：使用窗口函数计算区间增重和日增重
--   - 饲料消耗：关联饲料交易数据，计算区间料肉比
--   - 品种匹配：按 sku_id + 体重区间匹配生长阶段配置
--   - 增量更新策略：增量追加（append）
--   - 表类型：agg（聚合表），不是原子事务表
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_date'],
    description='牧场域牛只ADG区间汇总表，计算区间ADG和料肉比基础指标（增量更新）',
    tags=['ranch', 'dws', 'adg', 'fcr', 'agg', 'incremental']
) }}

-- ============================================
-- 源数据：称重交易记录（原子事实数据）
-- ============================================
WITH src_weight AS (
    SELECT
        cattle_id,
        weight_date,
        weight,
        stall_id,
        customer_id,
        weight_days,
        measure_code,
        measure_type,
        ai_score
    FROM {{ ref('dwd_ranch_cattle_weight_trx_i') }}
    -- WHERE {% if target.is_incremental %}
    --     weight_date >= (SELECT MAX(stats_date) FROM {{ this }}) - INTERVAL '30 days'
    -- {% endif %}
),

-- ============================================
-- 去重：每天只保留最后一次称重记录
-- ============================================
dedup_weight AS (
    SELECT
        cattle_id,
        weight_date,
        weight,
        stall_id,
        customer_id,
        weight_days,
        measure_code,
        measure_type,
        ai_score,
        ROW_NUMBER() OVER (PARTITION BY cattle_id, weight_date ORDER BY weight_date DESC) AS rn
    FROM src_weight
),
src_weight_dedup AS (
    SELECT
        cattle_id,
        weight_date,
        weight,
        stall_id,
        customer_id,
        weight_days,
        measure_code,
        measure_type,
        ai_score
    FROM dedup_weight
    WHERE rn = 1
),

-- ============================================
-- 计算称重区间（使用窗口函数计算上次称重和区间指标）
-- ============================================
calc_interval_metrics AS (
    SELECT
        cattle_id,
        weight_date AS current_weight_date,
        weight AS current_weight,
        stall_id,
        customer_id,
        weight_days,
        measure_code,
        measure_type,
        ai_score,
        -- 窗口函数：获取上次称重信息
        LAG(weight_date) OVER (PARTITION BY cattle_id ORDER BY weight_date) AS prev_weight_date,
        LAG(weight) OVER (PARTITION BY cattle_id ORDER BY weight_date) AS prev_weight,
        -- 窗口函数：计算区间增重
        weight - LAG(weight) OVER (PARTITION BY cattle_id ORDER BY weight_date) AS period_weight_gain,
        -- 窗口函数：计算区间日均增重（ADG）
        CASE WHEN LAG(weight_date) OVER (PARTITION BY cattle_id ORDER BY weight_date) IS NOT NULL
            THEN (weight - LAG(weight) OVER (PARTITION BY cattle_id ORDER BY weight_date)) / NULLIF(DATE_DIFF('day', LAG(weight_date) OVER (PARTITION BY cattle_id ORDER BY weight_date), weight_date), 0)
            ELSE NULL END AS period_adg,
        -- 称重事件序号（第几个有效称重日）
        ROW_NUMBER() OVER (PARTITION BY cattle_id ORDER BY weight_date) AS weigh_event_no
    FROM src_weight_dedup
),

-- ============================================
-- 过滤有效区间（排除第一次称重和异常间隔）
-- ============================================
filter_valid_intervals AS (
    SELECT
        cattle_id,
        current_weight_date,
        current_weight,
        prev_weight_date,
        prev_weight,
        stall_id,
        customer_id,
        period_weight_gain,
        period_adg,
        weigh_event_no,
        measure_code,
        measure_type,
        ai_score,
        -- 计算区间天数
        DATE_DIFF('day', prev_weight_date, current_weight_date) AS interval_days
    FROM calc_interval_metrics
    WHERE prev_weight_date IS NOT NULL  -- 排除第一次称重（没有上次数据）
),

-- ============================================
-- 维度：牛只信息（已包含牧场、栏舍、配方等完整维度信息）
-- ============================================
lkp_cattle AS (
    SELECT
        cattle_id,
        cattle_code,
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        cattle_sku_id AS sku_id,
        cattle_sku_name AS sku_name,
        brand_name,
        birth_date,
        in_stall_weight,
        in_stall_date
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- 源数据：饲料消耗记录
-- ============================================
src_feed AS (
    SELECT
        cattle_id,
        feed_date,
        act_feed_quantity,
        act_feed_cost
    FROM {{ ref('dwd_ranch_cattle_feed_trx_i') }}
),

-- ============================================
-- 维度：生长阶段配置（按品种区分）
-- ============================================
lkp_grow_stage AS (
    SELECT
        stage_id,
        stage_name,
        sku_id,
        sku_name,
        brand_name,
        start_weight AS stage_start_weight,
        end_weight AS stage_end_weight,
        plan_weight_add,
        feed_meat_ratio AS stage_target_fcr,
        days AS stage_days
    FROM {{ ref('dim_ranch_grow_stage') }}
    WHERE is_current = '1'
),

-- ============================================
-- 关联维度信息，匹配生长阶段
-- ============================================
join_base AS (
    SELECT
        m.current_weight_date AS stats_date,
        m.cattle_id,
        m.stall_id,
        m.customer_id,
        m.current_weight,
        m.prev_weight,
        m.period_weight_gain,
        m.interval_days,
        m.period_adg,
        m.weigh_event_no,
        m.measure_code,
        m.measure_type,
        m.ai_score,
        c.cattle_code,
        c.sku_id,
        c.sku_name,
        c.brand_name,
        c.birth_date,
        c.in_stall_weight,
        c.in_stall_date,
        c.stall_name,
        c.ranch_id,
        c.ranch_name,
        -- 计算日龄
        CASE WHEN c.birth_date IS NOT NULL THEN DATE_DIFF('day', c.birth_date, m.current_weight_date) ELSE NULL END AS age_days,
        -- 入栏后天数
        DATE_DIFF('day', c.in_stall_date, m.current_weight_date) AS days_since_entry,
        -- 累计增重（从入栏至今）
        m.current_weight - c.in_stall_weight AS cumulative_gain,
        -- 整体ADG（从入栏至今）
        CASE WHEN c.in_stall_date IS NOT NULL AND m.current_weight_date > c.in_stall_date
            THEN (m.current_weight - c.in_stall_weight) / NULLIF(DATE_DIFF('day', c.in_stall_date, m.current_weight_date), 0)
            ELSE NULL END AS overall_adg,
        -- 上次称重日期（用于关联饲料数据）
        m.prev_weight_date
    FROM filter_valid_intervals m
    LEFT JOIN lkp_cattle c ON m.cattle_id::VARCHAR = c.cattle_id::VARCHAR
    WHERE m.current_weight_date IS NOT NULL
),

-- ============================================
-- 添加生长阶段信息（按品种 + 体重区间匹配）
-- ============================================
join_growth_stage AS (
    SELECT
        b.*,
        -- 匹配生长阶段：根据品种 + 当前体重匹配阶段
        gs.stage_id,
        gs.stage_name,
        gs.stage_start_weight,
        gs.stage_end_weight,
        gs.plan_weight_add,
        gs.stage_target_fcr,
        gs.stage_days
    FROM join_base b
    LEFT JOIN lkp_grow_stage gs ON b.sku_id::VARCHAR = gs.sku_id::VARCHAR 
        AND b.current_weight >= gs.stage_start_weight AND b.current_weight < gs.stage_end_weight
),

-- ============================================
-- 计算区间饲料消耗和料肉比
-- ============================================
calc_feed_consumption AS (
    SELECT
        s.cattle_id,
        s.stats_date AS current_weight_date,
        s.prev_weight_date,
        -- 区间内饲料消耗总量
        SUM(f.act_feed_quantity) AS period_feed_consumption,
        -- 区间内饲料成本
        SUM(f.act_feed_cost) AS period_feed_cost
    FROM join_growth_stage s
    LEFT JOIN src_feed f ON s.cattle_id::VARCHAR = f.cattle_id::VARCHAR AND f.feed_date > s.prev_weight_date AND f.feed_date <= s.stats_date
    GROUP BY s.cattle_id, s.stats_date, s.prev_weight_date
),

-- ============================================
-- 关联饲料消耗，计算实际料肉比
-- ============================================
join_feed AS (
    SELECT
        s.stats_date,
        s.cattle_id,
        s.cattle_code,
        s.ranch_id,
        s.ranch_name,
        s.stall_id,
        s.stall_name,
        s.customer_id,
        s.sku_id,
        s.sku_name,
        s.brand_name,
        s.birth_date,
        s.in_stall_weight,
        s.in_stall_date,
        s.age_days,
        s.days_since_entry,
        s.prev_weight_date,
        s.interval_days,
        s.prev_weight,
        s.current_weight,
        s.period_weight_gain,
        s.period_adg,
        s.weigh_event_no,
        s.measure_code,
        s.measure_type,
        s.ai_score,
        s.cumulative_gain,
        s.overall_adg,
        s.stage_id,
        s.stage_name,
        s.stage_start_weight,
        s.stage_end_weight,
        s.plan_weight_add,
        s.stage_target_fcr,
        s.stage_days,
        fc.period_feed_consumption,
        fc.period_feed_cost,
        -- 计算区间料肉比 = 饲料消耗量 / 增重
        CASE WHEN s.period_weight_gain > 0 AND fc.period_feed_consumption IS NOT NULL THEN fc.period_feed_consumption / s.period_weight_gain ELSE NULL END AS period_fcr
    FROM join_growth_stage s
    LEFT JOIN calc_feed_consumption fc ON s.cattle_id = fc.cattle_id AND s.stats_date = fc.current_weight_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- ====================
    -- 标识维度
    -- ====================
    stats_date,                              -- 统计日期（称重日期）
    cattle_id,                               -- 牛只ID
    cattle_code,                              -- 牛只编号
    ranch_id,                                -- 牧场ID
    ranch_name,                              -- 牧场名称
    stall_id,                                -- 栏舍ID
    stall_name,                              -- 栏舍名称
    customer_id,                             -- 投资方ID

    -- ====================
    -- 个体特征
    -- ====================
    sku_id,                                  -- SKU ID（品种）
    sku_name,                                -- SKU名称
    brand_name,                              -- 品牌名称
    birth_date,                              -- 出生日期
    in_stall_weight,                         -- 入栏体重
    in_stall_date,                           -- 入栏日期
    age_days,                                -- 日龄
    days_since_entry,                        -- 入栏后天数

    -- ====================
    -- 称重区间信息
    -- ====================
    prev_weight_date,                        -- 上次称重日期
    interval_days,                           -- 称重间隔天数
    prev_weight,                             -- 上次称重体重
    current_weight,                          -- 本次称重体重
    period_weight_gain,                      -- 区间增重
    period_adg,                              -- 区间日均增重（实际ADG）
    weigh_event_no,                          -- 称重事件序号
    measure_code,                            -- 测量代码
    measure_type,                            -- 测量类型
    ai_score,                                -- AI评分

    -- ====================
    -- 饲料消耗与料肉比
    -- ====================
    period_feed_consumption,                 -- 区间饲料消耗量
    period_feed_cost,                        -- 区间饲料成本
    period_fcr,                              -- 区间料肉比（实际FCR = 饲料消耗/增重）

    -- ====================
    -- 历史累计指标
    -- ====================
    cumulative_gain,                         -- 累计增重（从入栏至今）
    overall_adg,                             -- 整体ADG（从入栏至今）

    -- ====================
    -- 生长阶段（按品种 + 体重区间匹配）
    -- ====================
    stage_id,                                -- 生长阶段ID
    stage_name,                              -- 生长阶段名称
    stage_start_weight,                      -- 阶段起始体重
    stage_end_weight,                        -- 阶段目标体重
    plan_weight_add,                         -- 计划增重
    stage_target_fcr,                        -- 阶段目标料肉比
    stage_days,                              -- 阶段天数

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM join_feed
WHERE stats_date IS NOT NULL AND cattle_id IS NOT NULL
ORDER BY stats_date, cattle_id
