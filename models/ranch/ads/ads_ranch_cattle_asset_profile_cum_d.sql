-- =============================================
-- 模型名称：ads_ranch_cattle_asset_profile_cum_d
-- 模型描述：牛只资产画像宽表（至今），每头牛一条记录，汇总基础档案、当前状态、最新生长指标及累计绩效
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：牛只维度表、DWS 最新价格表
--   - 增量策略：全量刷新（table）
--   - 统计指标：market_value（当前市场估值 = 最新体重 × 当前市场单价）
--   - 聚合逻辑：资产域ADS层主宽表，支撑上层的个体查询、群体筛选、出栏追踪
-- =============================================
{{ config(
    materialized='table',
    description='牛只资产画像宽表（至今），汇总每头牛的基础档案、当前状态、最新生长指标及累计绩效',
    tags=['ranch', 'ads', 'asset', 'cattle', 'profile']
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
        recipe_id,
        recipe_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        birth_date,
        in_stall_date,
        in_stall_weight,
        in_stall_price,
        color,
        customer_id,
        purchase_id,
        is_loan,
        loan_count,
        funding_id,
        total_loan_amount,
        in_stall_loan_amount,
        weight_add_loan_amount,
        corn_silage_loan_amount,
        high_moisture_corn_loan_amount,
        repay_amount,
        if_sick,
        cattle_status AS dim_cattle_status,
        out_stall_date AS dim_out_stall_date,
        create_time AS dim_create_time,
        update_time AS dim_update_time
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- 2. 最新称重记录（来自DWS聚合表）
-- ============================================
latest_weight AS (
    SELECT
        cattle_id,
        latest_weight_date,
        latest_weight,
        latest_measure_type,
        latest_weight_stall_id,
        latest_weight_customer_id,
        latest_daily_gain,
        latest_ai_score
    FROM {{ ref('dws_ranch_cattle_weight_state_df') }}
),

-- ============================================
-- 3. 最新ADG区间记录（来自DWS聚合表）
-- ============================================
latest_adg AS (
    SELECT
        cattle_id,
        stats_date AS latest_adg_date,
        current_weight AS adg_current_weight,
        period_adg AS latest_period_adg,
        overall_adg,
        interval_days AS latest_interval_days,
        cumulative_gain,
        days_since_entry,
        stage_name AS latest_stage_name,
        stage_target_fcr,
        period_fcr AS latest_period_fcr,
        period_feed_consumption AS latest_period_feed_consumption,
        period_feed_cost AS latest_period_feed_cost
    FROM (
        SELECT
            cattle_id, stats_date, current_weight, period_adg, overall_adg, interval_days, cumulative_gain, days_since_entry, stage_name, stage_target_fcr, period_fcr, period_feed_consumption, period_feed_cost,
            ROW_NUMBER() OVER (PARTITION BY cattle_id ORDER BY stats_date DESC) AS rn  -- 取每头牛最新ADG记录
        FROM {{ ref('dws_ranch_cattle_adg_fcr_i') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

-- ============================================
-- 4. 出栏信息（来自DWS聚合表）
-- ============================================
sell_info AS (
    SELECT
        cattle_id,
        sell_date,
        sell_weight,
        sell_price,
        sell_total_amount,
        sell_buyer_id,
        sell_ranch_id,
        sell_stall_id
    FROM {{ ref('dws_ranch_cattle_sell_agg_df') }}
),

-- ============================================
-- 5. 退回信息（来自DWS聚合表）
-- ============================================
return_info AS (
    SELECT
        cattle_id,
        return_date,
        return_weight,
        return_price,
        return_reason,
        return_ranch_id
    FROM {{ ref('dws_ranch_cattle_return_agg_df') }}
),

-- ============================================
-- 6. 当前市场估值（最新体重 × 当前市场单价）
-- ============================================
market_price AS (
    SELECT
        ranch_id,
        cattle_sku_id,
        latest_unit_price,
        latest_price_date
    FROM {{ ref('dws_ranch_cattle_price_state_df') }}
),

-- ============================================
-- 7. 数据整合与派生计算
-- ============================================
integrated AS (
    SELECT
        b.cattle_id,
        b.cattle_no,
        b.vice_code,
        b.ranch_id,
        b.ranch_name,
        b.stall_id,
        b.stall_name,
        b.recipe_id,
        b.recipe_name,
        b.cattle_sku_id,
        b.cattle_sku_name,
        b.brand_name,
        b.birth_date,
        b.in_stall_date,
        b.in_stall_weight,
        b.in_stall_price,
        b.color,
        b.customer_id,
        b.purchase_id,
        b.is_loan,
        b.loan_count,
        b.funding_id,
        b.total_loan_amount,
        b.in_stall_loan_amount,
        b.weight_add_loan_amount,
        b.corn_silage_loan_amount,
        b.high_moisture_corn_loan_amount,
        b.repay_amount,
        b.if_sick,

        -- 状态判定：业务事实优先于维度状态
        CASE WHEN s.cattle_id IS NOT NULL THEN '已出栏' WHEN r.cattle_id IS NOT NULL THEN '已退回' WHEN b.dim_cattle_status = '0' THEN '在栏' ELSE '其他' END AS cattle_status,

        -- 最新称重（来自DWS称重聚合表）
        w.latest_weight_date,
        w.latest_weight,
        w.latest_measure_type,
        w.latest_weight_stall_id,
        w.latest_daily_gain,
        w.latest_ai_score,

        -- 最新ADG指标
        a.latest_adg_date,
        a.latest_period_adg,
        a.overall_adg,
        a.latest_interval_days,
        a.cumulative_gain,
        a.days_since_entry,
        a.latest_stage_name,
        a.stage_target_fcr,
        a.latest_period_fcr,
        a.latest_period_feed_consumption,
        a.latest_period_feed_cost,

        -- 出栏详情
        s.sell_date,
        s.sell_weight,
        s.sell_price,
        s.sell_total_amount,
        s.sell_buyer_id,
        s.sell_ranch_id,
        s.sell_stall_id,

        -- 退回详情
        r.return_date,
        r.return_weight,
        r.return_price,
        r.return_reason,
        r.return_ranch_id,

        -- 当前市场单价（用于估值）
        p.latest_unit_price AS current_market_price,
        p.latest_price_date AS market_price_date,

        -- 计算指标：当前市场估值（最新体重 × 当前市场单价）
        CASE WHEN w.latest_weight > 0 AND p.latest_unit_price > 0 THEN w.latest_weight * p.latest_unit_price ELSE NULL END AS market_value,

        -- 计算指标：最终参考日期（用于日龄/在栏天数计算）
        COALESCE(s.sell_date, r.return_date, w.latest_weight_date, CURRENT_DATE) AS reference_date,

        -- 计算指标：日龄
        CASE WHEN b.birth_date IS NOT NULL THEN DATE_DIFF('day', b.birth_date, COALESCE(s.sell_date, r.return_date, w.latest_weight_date, CURRENT_DATE)) ELSE NULL END AS day_age,

        -- 计算指标：在栏天数（优先ADG表，其次自行计算）
        COALESCE(a.days_since_entry, CASE WHEN b.in_stall_date IS NOT NULL THEN DATE_DIFF('day', b.in_stall_date, COALESCE(s.sell_date, r.return_date, w.latest_weight_date, CURRENT_DATE)) ELSE NULL END) AS days_on_stall,

        -- 计算指标：累计增重（优先ADG表，其次基于最新体重计算）
        COALESCE(a.cumulative_gain, CASE WHEN b.in_stall_weight IS NOT NULL AND w.latest_weight IS NOT NULL THEN w.latest_weight - b.in_stall_weight ELSE NULL END) AS cumulative_weight_gain,

        -- 计算指标：整体ADG（优先ADG表，其次自行计算）
        COALESCE(a.overall_adg, CASE WHEN b.in_stall_weight IS NOT NULL AND w.latest_weight IS NOT NULL AND COALESCE(a.days_since_entry, CASE WHEN b.in_stall_date IS NOT NULL THEN DATE_DIFF('day', b.in_stall_date, COALESCE(s.sell_date, r.return_date, w.latest_weight_date, CURRENT_DATE)) END) > 0 THEN (w.latest_weight - b.in_stall_weight) / COALESCE(a.days_since_entry, CASE WHEN b.in_stall_date IS NOT NULL THEN DATE_DIFF('day', b.in_stall_date, COALESCE(s.sell_date, r.return_date, w.latest_weight_date, CURRENT_DATE)) END) ELSE NULL END) AS overall_adg_calc,

        -- 计算指标：贷款覆盖率（贷款金额 / 市场估值）
        CASE WHEN w.latest_weight > 0 AND p.latest_unit_price > 0 AND b.total_loan_amount > 0 THEN b.total_loan_amount / (w.latest_weight * p.latest_unit_price) ELSE NULL END AS loan_coverage_ratio,

        -- 维度元数据
        b.dim_create_time,
        b.dim_update_time

    FROM cattle_base b
    LEFT JOIN latest_weight w ON CAST(b.cattle_id AS VARCHAR) = CAST(w.cattle_id AS VARCHAR)
    LEFT JOIN latest_adg a ON CAST(b.cattle_id AS VARCHAR) = CAST(a.cattle_id AS VARCHAR)
    LEFT JOIN sell_info s ON CAST(b.cattle_id AS VARCHAR) = CAST(s.cattle_id AS VARCHAR)
    LEFT JOIN return_info r ON CAST(b.cattle_id AS VARCHAR) = CAST(r.cattle_id AS VARCHAR)
    LEFT JOIN market_price p ON b.ranch_id::VARCHAR = p.ranch_id::VARCHAR AND b.cattle_sku_id::VARCHAR = p.cattle_sku_id::VARCHAR
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 标识维度
    cattle_id,                               -- 牛只ID
    cattle_no,                               -- 牛只编号
    vice_code,                               -- 副编号

    -- 组织维度
    ranch_id,                                -- 牧场ID
    ranch_name,                              -- 牧场名称
    stall_id,                                -- 栏舍ID
    stall_name,                              -- 栏舍名称
    customer_id,                             -- 客户/投资方ID
    purchase_id,                             -- 采购单ID

    -- 品种维度
    cattle_sku_id,                           -- SKU ID
    cattle_sku_name,                         -- SKU名称
    brand_name,                              -- 品牌名称
    recipe_id,                               -- 当前配方ID
    recipe_name,                             -- 当前配方名称

    -- 基础属性
    birth_date,                              -- 出生日期
    in_stall_date,                           -- 入栏日期
    in_stall_weight,                         -- 入栏体重
    in_stall_price,                          -- 入栏单价
    color,                                   -- 毛色
    day_age,                                 -- 日龄

    -- 状态与融资
    cattle_status,                           -- 牛只状态：在栏/已出栏/已退回/其他
    is_loan,                                 -- 是否融资
    loan_count,                              -- 贷款次数
    funding_id,                              -- 资金方ID
    total_loan_amount,                       -- 总贷款金额
    in_stall_loan_amount,                    -- 入栏贷金额
    weight_add_loan_amount,                  -- 增重贷金额
    corn_silage_loan_amount,                 -- 青贮玉米贷金额
    high_moisture_corn_loan_amount,          -- 高湿玉米贷金额
    repay_amount,                            -- 还款金额
    loan_coverage_ratio,                     -- 贷款覆盖率（基于市场估值）
    if_sick,                                 -- 是否病牛

    -- 最新称重
    latest_weight_date,                      -- 最新称重日期
    latest_weight,                           -- 最新体重
    latest_measure_type,                     -- 最新称重类型
    latest_weight_stall_id,                  -- 最新称重栏舍ID
    latest_daily_gain,                       -- 最新日增重
    latest_ai_score,                         -- 最新AI评分

    -- 生长绩效（ADG）
    latest_adg_date,                         -- 最新ADG统计日期
    latest_period_adg,                       -- 最新区间日均增重
    overall_adg,                             -- 整体ADG（来自ADG表）
    overall_adg_calc,                        -- 整体ADG（自行计算兜底）
    latest_interval_days,                    -- 最新称重间隔天数
    days_on_stall,                           -- 在栏天数
    cumulative_gain,                         -- 累计增重（来自ADG表）
    cumulative_weight_gain,                  -- 累计增重（自行计算兜底）

    -- 当前市场估值
    current_market_price,                    -- 当前市场单价
    market_price_date,                       -- 市场单价生效日期
    market_value,                            -- 当前市场估值

    -- 生长阶段
    latest_stage_name,                       -- 最新生长阶段
    stage_target_fcr,                        -- 阶段目标料肉比
    latest_period_fcr,                       -- 最新区间料肉比
    latest_period_feed_consumption,          -- 最新区间饲料消耗量
    latest_period_feed_cost,                 -- 最新区间饲料成本

    -- 出栏详情（仅已出栏牛只有值）
    sell_date,                               -- 出栏日期
    sell_weight,                             -- 出栏体重
    sell_price,                              -- 销售单价
    sell_total_amount,                       -- 销售总额
    sell_buyer_id,                           -- 买家ID
    sell_ranch_id,                           -- 出栏牧场ID
    sell_stall_id,                           -- 出栏栏舍ID

    -- 退回详情（仅已退回牛只有值）
    return_date,                             -- 退回日期
    return_weight,                           -- 退回体重
    return_price,                            -- 退回单价
    return_reason,                           -- 退回原因
    return_ranch_id,                         -- 退回牧场ID

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM integrated
ORDER BY ranch_id, stall_id, cattle_id
