-- =============================================
-- 模型名称：ads_ranch_cattle_fatten_cycle_hist
-- 模型描述：牛只育肥周期绩效宽表（历史），仅包含已完结牛只（已出栏或已退回）
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：牛只维度表
--   - 增量策略：全量刷新（table）
--   - 统计指标：育肥天数、总增重、平均ADG、总饲料消耗、料肉比、出栏/退回信息
--   - 聚合逻辑：_hist 后缀表示仅包含历史完结周期数据（区别于 _td 至今快照）
-- =============================================
{{ config(
    materialized='table',
    description='牛只育肥周期绩效宽表（历史），汇总已完结牛只的入栏、出栏/退回、生长及饲料效率指标',
    tags=['ranch', 'ads', 'fatten', 'cycle', 'performance', 'hist']
) }}

-- ============================================
-- 1. 基础档案（来自牛只维度表）
-- ============================================
WITH cattle_base AS (
    SELECT
        cattle_id,
        cattle_code AS cattle_no,
        vice_code,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        birth_date,
        in_stall_date,
        in_stall_weight,
        in_stall_price,
        customer_id,
        purchase_id,
        is_loan,
        total_loan_amount,
        repay_amount,
        if_sick
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- 2. 出栏记录（来自DWS聚合表）
-- ============================================
sell_info AS (
    SELECT
        cattle_id,
        sell_date AS end_date,
        sell_weight AS end_weight,
        sell_price AS end_price,
        sell_total_amount AS end_total_amount,
        sell_buyer_id AS buyer_id,
        sell_ranch_id AS end_ranch_id,
        sell_stall_id AS end_stall_id,
        '已出栏' AS finish_type
    FROM {{ ref('dws_ranch_cattle_sell_agg_df') }}
),

-- ============================================
-- 3. 退回记录（来自DWS聚合表）
-- ============================================
return_info AS (
    SELECT
        cattle_id,
        return_date AS end_date,
        return_weight AS end_weight,
        return_price AS end_price,
        NULL::DOUBLE AS end_total_amount,
        NULL::BIGINT AS buyer_id,
        return_ranch_id AS end_ranch_id,
        NULL::BIGINT AS end_stall_id,
        '已退回' AS finish_type
    FROM {{ ref('dws_ranch_cattle_return_agg_df') }}
),

-- ============================================
-- 4. 已完结牛只终点（出栏优先于退回，若同时存在取出栏）
-- ============================================
finish_info AS (
    SELECT
        cattle_id, end_date, end_weight, end_price, end_total_amount, buyer_id, end_ranch_id, end_stall_id, finish_type
    FROM (
        SELECT
            cattle_id, end_date, end_weight, end_price, end_total_amount, buyer_id, end_ranch_id, end_stall_id, finish_type,
            ROW_NUMBER() OVER (PARTITION BY cattle_id ORDER BY CASE WHEN finish_type = '已出栏' THEN 1 ELSE 2 END, end_date DESC) AS rn  -- 出栏优先，同类型取最新日期
        FROM (SELECT * FROM sell_info UNION ALL SELECT * FROM return_info) t
    ) t
    WHERE rn = 1
),

-- ============================================
-- 5. 育肥周期内饲料消耗汇总（来自ADG区间表）
-- ============================================
fatten_feed AS (
    SELECT
        cattle_id,
        SUM(period_feed_consumption) AS total_feed_consumption,
        SUM(period_feed_cost) AS total_feed_cost,
        SUM(period_weight_gain) AS sum_period_weight_gain,
        COUNT(*) AS weigh_event_count,
        AVG(period_adg) AS avg_period_adg,
        MIN(period_adg) AS min_period_adg,
        MAX(period_adg) AS max_period_adg,
        AVG(period_fcr) AS avg_period_fcr
    FROM {{ ref('dws_ranch_cattle_adg_fcr_i') }}
    WHERE stats_date IS NOT NULL
    GROUP BY cattle_id
),

-- ============================================
-- 6. 整合计算
-- ============================================
integrated AS (
    SELECT
        b.cattle_id, b.cattle_no, b.vice_code, b.ranch_id, b.ranch_name, b.stall_id, b.stall_name, b.cattle_sku_id, b.cattle_sku_name, b.brand_name,
        b.birth_date, b.in_stall_date, b.in_stall_weight, b.in_stall_price, b.customer_id, b.purchase_id, b.is_loan, b.total_loan_amount, b.repay_amount, b.if_sick,
        f.finish_type, f.end_date, f.end_weight, f.end_price, f.end_total_amount, f.buyer_id, f.end_ranch_id, f.end_stall_id,

        -- 育肥天数
        CASE WHEN b.in_stall_date IS NOT NULL AND f.end_date IS NOT NULL THEN DATE_DIFF('day', b.in_stall_date, f.end_date) ELSE NULL END AS fatten_days,

        -- 总增重
        CASE WHEN b.in_stall_weight IS NOT NULL AND f.end_weight IS NOT NULL THEN f.end_weight - b.in_stall_weight ELSE NULL END AS total_weight_gain,

        -- 平均ADG（基于入栏到出栏/退回）
        CASE WHEN b.in_stall_weight IS NOT NULL AND f.end_weight IS NOT NULL AND b.in_stall_date IS NOT NULL AND f.end_date IS NOT NULL AND DATE_DIFF('day', b.in_stall_date, f.end_date) > 0 THEN (f.end_weight - b.in_stall_weight) / DATE_DIFF('day', b.in_stall_date, f.end_date) ELSE NULL END AS avg_fatten_adg,

        -- 饲料消耗汇总
        ff.total_feed_consumption, ff.total_feed_cost, ff.sum_period_weight_gain, ff.weigh_event_count, ff.avg_period_adg, ff.min_period_adg, ff.max_period_adg, ff.avg_period_fcr AS avg_period_feed_meat_ratio,

        -- 料肉比（基于总增重）
        CASE WHEN (f.end_weight - b.in_stall_weight) > 0 AND ff.total_feed_consumption IS NOT NULL THEN ff.total_feed_consumption / (f.end_weight - b.in_stall_weight) ELSE NULL END AS feed_meat_ratio,

        -- 单位增重饲料成本
        CASE WHEN (f.end_weight - b.in_stall_weight) > 0 AND ff.total_feed_cost IS NOT NULL THEN ff.total_feed_cost / (f.end_weight - b.in_stall_weight) ELSE NULL END AS feed_cost_per_kg_gain,

        -- 日龄相关
        CASE WHEN b.birth_date IS NOT NULL AND f.end_date IS NOT NULL THEN DATE_DIFF('day', b.birth_date, f.end_date) ELSE NULL END AS end_age_days,

        -- 入栏日龄
        CASE WHEN b.birth_date IS NOT NULL AND b.in_stall_date IS NOT NULL THEN DATE_DIFF('day', b.birth_date, b.in_stall_date) ELSE NULL END AS age_at_install

    FROM cattle_base b
    INNER JOIN finish_info f ON CAST(b.cattle_id AS VARCHAR) = CAST(f.cattle_id AS VARCHAR)
    LEFT JOIN fatten_feed ff ON CAST(b.cattle_id AS VARCHAR) = CAST(ff.cattle_id AS VARCHAR)
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 牛只标识
    cattle_id,                               -- 牛只ID
    cattle_no,                               -- 牛只编号
    vice_code,                               -- 副编号

    -- 组织维度
    ranch_id,                                -- 入栏牧场ID
    ranch_name,                              -- 入栏牧场名称
    stall_id,                                -- 入栏栏舍ID
    stall_name,                              -- 入栏栏舍名称
    customer_id,                             -- 客户ID
    purchase_id,                             -- 采购单ID

    -- 品种维度
    cattle_sku_id,                           -- SKU ID
    cattle_sku_name,                         -- SKU名称
    brand_name,                              -- 品牌名称

    -- 基础属性
    birth_date,                              -- 出生日期
    age_at_install,                          -- 入栏日龄
    end_age_days,                            -- 完结时日龄
    in_stall_date,                           -- 入栏日期
    in_stall_weight,                         -- 入栏体重
    in_stall_price,                          -- 入栏单价

    -- 融资标识
    is_loan,                                 -- 是否融资
    total_loan_amount,                       -- 总贷款金额
    repay_amount,                            -- 还款金额
    if_sick,                                 -- 是否病牛

    -- 完结信息
    finish_type,                             -- 完结类型
    end_date,                                -- 完结日期
    end_weight,                              -- 完结体重
    end_price,                               -- 完结单价
    end_total_amount,                        -- 销售总额
    buyer_id,                                -- 买家ID
    end_ranch_id,                            -- 完结牧场ID
    end_stall_id,                            -- 完结栏舍ID

    -- 育肥绩效
    fatten_days,                             -- 育肥天数
    total_weight_gain,                       -- 总增重
    avg_fatten_adg,                          -- 育肥期平均ADG
    weigh_event_count,                       -- 称重次数
    avg_period_adg,                          -- 平均区间ADG
    min_period_adg,                          -- 最小区间ADG
    max_period_adg,                          -- 最大区间ADG

    -- 饲料效率
    total_feed_consumption,                  -- 总饲料消耗量
    total_feed_cost,                         -- 总饲料成本
    feed_meat_ratio,                         -- 料肉比
    feed_cost_per_kg_gain,                   -- 单位增重饲料成本
    avg_period_feed_meat_ratio,              -- 平均区间料肉比

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM integrated
ORDER BY end_date DESC, ranch_id, stall_id, cattle_id
