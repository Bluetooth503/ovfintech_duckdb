-- =============================================
-- 模型名称：ads_ranch_cattle_cost_profile_cum_d
-- 模型描述：牛只成本画像宽表（至今），每头牛一条记录，汇总采购成本、饲料成本、附加成本及成本结构
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：dim_ranch_cattle（牛只维度）+ dws_ranch_cattle_feed_breakdown_agg_i（饲料成本）+ dws_ranch_cattle_sell_agg_df（销售数据）
--   - 增量策略：全量刷新（table）
--   - 统计指标：采购成本、累计饲料成本、总成本、成本结构（采购/饲料/附加占比）、头均日成本、盈亏分析
-- =============================================
{{ config(
    materialized='table',
    description='牛只成本画像宽表（至今），汇总每头牛的采购成本、饲料成本、附加成本及成本结构分析',
    tags=['ranch', 'ads', 'cost', 'cattle', 'profile']
) }}

-- ============================================
-- 1. 基础档案（来自牛只维度表）
-- ============================================
WITH cattle_base AS (
    SELECT
        cattle_id,
        cattle_code AS cattle_no,
        ranch_id,
        ranch_name,
        stall_id,
        stall_name,
        cattle_sku_id,
        cattle_sku_name,
        brand_name,
        customer_id,
        purchase_id,
        in_stall_date,
        in_stall_weight,
        in_stall_price,
        cattle_status AS dim_cattle_status,
        out_stall_date AS dim_out_stall_date
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
),

-- ============================================
-- 2. 累计饲料成本（从DWS饲料区间汇总聚合）
-- ============================================
feed_cost AS (
    SELECT
        cattle_id,
        SUM(period_feed_cost) AS cumulative_feed_cost,
        SUM(period_feed_consumption) AS cumulative_feed_consumption,
        SUM(period_concentrate_cost) AS cumulative_concentrate_cost,
        SUM(period_roughage_cost) AS cumulative_roughage_cost,
        SUM(period_additive_cost) AS cumulative_additive_cost,
        SUM(period_medicine_cost) AS cumulative_medicine_cost,
        MAX(stats_date) AS latest_feed_date
    FROM {{ ref('dws_ranch_cattle_feed_breakdown_agg_i') }}
    GROUP BY cattle_id
),

-- ============================================
-- 3. 出栏信息（用于最终状态判定）
-- ============================================
sell_info AS (
    SELECT DISTINCT
        cattle_id,
        sell_date,
        sell_total_amount AS sell_revenue
    FROM {{ ref('dws_ranch_cattle_sell_agg_df') }}
),

-- ============================================
-- 4. 退回信息（用于最终状态判定）
-- ============================================
return_info AS (
    SELECT DISTINCT
        cattle_id,
        return_date
    FROM {{ ref('dws_ranch_cattle_return_agg_df') }}
),

-- ============================================
-- 5. 数据整合与成本计算
-- ============================================
integrated AS (
    SELECT
        b.cattle_id,
        b.cattle_no,
        b.ranch_id,
        b.ranch_name,
        b.stall_id,
        b.stall_name,
        b.cattle_sku_id,
        b.cattle_sku_name,
        b.brand_name,
        b.customer_id,
        b.purchase_id,
        b.in_stall_date,
        b.in_stall_weight,
        b.in_stall_price,

        -- 预计算采购成本
        CASE WHEN b.in_stall_weight IS NOT NULL AND b.in_stall_price IS NOT NULL
             THEN b.in_stall_weight * b.in_stall_price
             ELSE 0 END AS calc_purchase_cost,

        -- 预计算总成本
        CASE WHEN b.in_stall_weight IS NOT NULL AND b.in_stall_price IS NOT NULL
             THEN (b.in_stall_weight * b.in_stall_price) + COALESCE(fc.cumulative_feed_cost, 0)
             ELSE COALESCE(fc.cumulative_feed_cost, 0) END AS calc_total_cost,

        -- 状态判定
        CASE WHEN s.cattle_id IS NOT NULL THEN '已出栏'
             WHEN r.cattle_id IS NOT NULL THEN '已退回'
             WHEN b.dim_cattle_status = '0' THEN '在栏'
             ELSE '其他' END AS cattle_status,

        -- 采购成本（直接从基础档案计算，避免 JOIN 导致重复）
        calc_purchase_cost AS purchase_cost,
        b.in_stall_weight AS purchase_weight,
        b.in_stall_price AS avg_purchase_unit_price,

        -- 累计饲料成本
        COALESCE(fc.cumulative_feed_cost, 0) AS cumulative_feed_cost,
        COALESCE(fc.cumulative_feed_consumption, 0) AS cumulative_feed_consumption,
        COALESCE(fc.cumulative_concentrate_cost, 0) AS cumulative_concentrate_cost,
        COALESCE(fc.cumulative_roughage_cost, 0) AS cumulative_roughage_cost,
        COALESCE(fc.cumulative_additive_cost, 0) AS cumulative_additive_cost,
        COALESCE(fc.cumulative_medicine_cost, 0) AS cumulative_medicine_cost,

        -- 附加成本（医疗、运输等其他费用，维度表中暂无字段，预留）
        0 AS additional_cost,

        -- 计算指标：总成本
        calc_total_cost AS total_cost,

        -- 计算指标：在栏天数
        DATE_DIFF('day', b.in_stall_date, COALESCE(s.sell_date, r.return_date, CURRENT_DATE)) AS days_on_stall,

        -- 计算指标：头均日成本
        CASE WHEN b.in_stall_date IS NOT NULL
             THEN calc_total_cost / NULLIF(DATE_DIFF('day', b.in_stall_date, COALESCE(s.sell_date, r.return_date, CURRENT_DATE)), 0)
             ELSE NULL END AS avg_daily_cost_per_cattle,

        -- 成本结构占比
        CASE WHEN calc_total_cost > 0
             THEN calc_purchase_cost / calc_total_cost
             ELSE NULL END AS purchase_cost_ratio,
        CASE WHEN calc_total_cost > 0
             THEN COALESCE(fc.cumulative_feed_cost, 0) / calc_total_cost
             ELSE NULL END AS feed_cost_ratio,

        -- 饲料成本内部结构
        CASE WHEN fc.cumulative_feed_cost > 0
             THEN fc.cumulative_concentrate_cost / NULLIF(fc.cumulative_feed_cost, 0)
             ELSE NULL END AS concentrate_cost_ratio,
        CASE WHEN fc.cumulative_feed_cost > 0
             THEN fc.cumulative_roughage_cost / NULLIF(fc.cumulative_feed_cost, 0)
             ELSE NULL END AS roughage_cost_ratio,

        -- 出栏信息
        s.sell_date,
        s.sell_revenue,

        -- 计算指标：盈亏分析
        CASE WHEN s.sell_revenue IS NOT NULL
             THEN s.sell_revenue - calc_total_cost
             ELSE NULL END AS profit_loss_amount,
        CASE WHEN s.sell_revenue IS NOT NULL AND calc_total_cost > 0
             THEN (s.sell_revenue - calc_total_cost) / calc_total_cost * 100
             ELSE NULL END AS profit_loss_rate,

        fc.latest_feed_date

    FROM cattle_base b
    LEFT JOIN feed_cost fc ON b.cattle_id::VARCHAR = fc.cattle_id::VARCHAR
    LEFT JOIN sell_info s ON b.cattle_id::VARCHAR = s.cattle_id::VARCHAR
    LEFT JOIN return_info r ON b.cattle_id::VARCHAR = r.cattle_id::VARCHAR
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 标识维度
    cattle_id,                               -- 牛只ID
    cattle_no,                               -- 牛只编号

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

    -- 基础属性
    in_stall_date,                           -- 入栏日期
    in_stall_weight,                         -- 入栏体重
    in_stall_price,                          -- 入栏单价

    -- 状态
    cattle_status,                           -- 牛只状态

    -- 采购成本
    purchase_cost,                           -- 采购成本
    purchase_weight,                         -- 采购重量
    avg_purchase_unit_price,                 -- 平均采购单价

    -- 累计饲料成本
    cumulative_feed_cost,                    -- 累计饲料总成本
    cumulative_feed_consumption,             -- 累计饲料消耗量
    cumulative_concentrate_cost,             -- 累计精料成本
    cumulative_roughage_cost,                -- 累计粗料成本
    cumulative_additive_cost,                -- 累计添加剂成本
    cumulative_medicine_cost,                -- 累计药品成本

    -- 附加成本
    additional_cost,                         -- 附加成本（预留）

    -- 总成本与效率
    total_cost,                              -- 总成本（采购+饲料+附加）
    days_on_stall,                           -- 在栏天数
    avg_daily_cost_per_cattle,               -- 头均日成本

    -- 成本结构占比
    purchase_cost_ratio,                     -- 采购成本占比
    feed_cost_ratio,                         -- 饲料成本占比
    concentrate_cost_ratio,                  -- 精料成本占比
    roughage_cost_ratio,                     -- 粗料成本占比

    -- 出栏盈亏
    sell_date,                               -- 出栏日期
    sell_revenue,                            -- 出栏收入
    profit_loss_amount,                      -- 盈亏金额
    profit_loss_rate,                        -- 盈亏率（%）

    -- 元数据
    latest_feed_date AS last_cost_update,    -- 最后成本更新日期
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM integrated
ORDER BY ranch_id, stall_id, cattle_id
