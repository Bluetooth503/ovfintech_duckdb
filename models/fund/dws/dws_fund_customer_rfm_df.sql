-- =============================================
-- 模型名称：dws_fund_customer_rfm_df
-- 模型描述：客户RFM指标日汇总表，按客户+场景汇总RFM指标，使用分位数评分支持客户价值分析
-- Dbt更新方式：全量
-- 粒度：customer_id + scene_id
-- 说明：
--   - 数据源：dwd_fund_online_loan_fact_i、dwd_fund_offline_loan_fact_i、dim_customer_unify
--   - 统计指标：R（最近交易天数）、F（交易频次）、M（交易金额）、分位数评分、客户分群
--   - 聚合逻辑：NTILE(5) 分位数评分，按全局和场景内分别计算，8种客户分群
-- =============================================
{{ config(
    materialized='table',
    description='客户RFM指标日汇总表，按客户+日期+场景汇总RFM指标，使用分位数评分，支持客户价值分析',
    tags=['fund', 'dws', 'rfm', 'customer', 'daily']
) }}

WITH all_loan_trx AS (
    -- 合并在线和线下放款数据
    SELECT
        customer_id,
        trx_date,
        trx_id,
        loan_repay_type,
        COALESCE(bill_amount, 0) AS loan_amount,
        COALESCE(repay_interest_amount, 0) AS interest_amount,
        promissory_note_balance
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type = '1'
    UNION ALL
    SELECT
        customer_id,
        trx_date,
        trx_id,
        loan_repay_type,
        COALESCE(loan_amount, 0) AS loan_amount,
        0 AS interest_amount,
        promissory_note_balance
    FROM {{ ref('dwd_fund_offline_loan_fact_i') }}
    WHERE loan_repay_type = '1'
),

customer_scene AS (
    -- 从客户统一维度表获取场景信息
    SELECT
        customer_id,
        scene_level1_id AS scene_id,
        scene_level1_name AS scene_name,
        scene_path
    FROM {{ ref('dim_customer_unify') }}
    WHERE scene_level1_id IS NOT NULL
),

customer_trx_lifetime AS (
    -- 按客户+场景汇总全生命周期交易数据
    SELECT
        t.customer_id,
        COALESCE(cs.scene_id, 0) AS scene_id,
        COALESCE(cs.scene_name, '未配置场景') AS scene_name,
        COUNT(t.trx_id) AS trx_count,
        SUM(t.loan_amount) AS total_loan_amount,
        SUM(t.interest_amount) AS total_interest_amount,
        SUM(t.promissory_note_balance) AS total_loan_balance,
        MAX(t.trx_date) AS latest_trx_date
    FROM all_loan_trx t
    LEFT JOIN customer_scene cs ON t.customer_id = cs.customer_id
    GROUP BY t.customer_id, cs.scene_id, cs.scene_name
),

customer_rfm_calculation AS (
    -- 计算RFM指标（全生命周期）
    SELECT
        customer_id,
        scene_id,
        scene_name,
        trx_count,
        total_loan_amount,
        total_interest_amount,
        total_loan_balance,
        latest_trx_date,
        -- R：最近一次交易距今天数（越小越好）
        DATEDIFF('day', latest_trx_date, CURRENT_DATE) AS recency_days,
        -- F：交易频次
        trx_count AS frequency_count,
        -- M：交易金额
        total_loan_amount AS monetary_amount
    FROM customer_trx_lifetime
),

-- 计算全局分位数（用于全部场景）
global_quantiles AS (
    SELECT
        NTILE(5) OVER (ORDER BY recency_days ASC) AS r_quantile_global,
        NTILE(5) OVER (ORDER BY frequency_count DESC) AS f_quantile_global,
        NTILE(5) OVER (ORDER BY monetary_amount DESC) AS m_quantile_global,
        customer_id,
        scene_id
    FROM customer_rfm_calculation
),

-- 计算场景内分位数
scene_quantiles AS (
    SELECT
        NTILE(5) OVER (PARTITION BY scene_id ORDER BY recency_days ASC) AS r_quantile_scene,
        NTILE(5) OVER (PARTITION BY scene_id ORDER BY frequency_count DESC) AS f_quantile_scene,
        NTILE(5) OVER (PARTITION BY scene_id ORDER BY monetary_amount DESC) AS m_quantile_scene,
        customer_id,
        scene_id
    FROM customer_rfm_calculation
),

-- 合并分位数和RFM指标
rfm_with_quantiles AS (
    SELECT
        c.customer_id,
        c.scene_id,
        c.scene_name,
        c.trx_count,
        c.total_loan_amount,
        c.total_interest_amount,
        c.total_loan_balance,
        c.latest_trx_date,
        c.recency_days,
        c.frequency_count,
        c.monetary_amount,
        -- 全局分位数评分（1-5分，5分最好）
        g.r_quantile_global AS r_score_global,
        g.f_quantile_global AS f_score_global,
        g.m_quantile_global AS m_score_global,
        -- 场景内分位数评分（1-5分，5分最好）
        s.r_quantile_scene AS r_score_scene,
        s.f_quantile_scene AS f_score_scene,
        s.m_quantile_scene AS m_score_scene
    FROM customer_rfm_calculation c
    LEFT JOIN global_quantiles g ON c.customer_id = g.customer_id AND c.scene_id = g.scene_id
    LEFT JOIN scene_quantiles s ON c.customer_id = s.customer_id AND c.scene_id = s.scene_id
),

-- 客户分群（使用全局分位数）
rfm_scoring AS (
    SELECT
        customer_id,
        scene_id,
        scene_name,
        trx_count,
        total_loan_amount,
        total_interest_amount,
        total_loan_balance,
        latest_trx_date,
        recency_days,
        frequency_count,
        monetary_amount,
        -- 全局RFM评分
        r_score_global,
        f_score_global,
        m_score_global,
        r_score_global + f_score_global + m_score_global AS rfm_total_score_global,
        -- 场景内RFM评分
        r_score_scene,
        f_score_scene,
        m_score_scene,
        r_score_scene + f_score_scene + m_score_scene AS rfm_total_score_scene
    FROM rfm_with_quantiles
),

customer_segmentation AS (
    SELECT
        customer_id,
        CURRENT_DATE AS stat_date,
        latest_trx_date,
        scene_id,
        scene_name,
        trx_count,
        total_loan_amount,
        total_interest_amount,
        total_loan_balance,
        recency_days,
        frequency_count,
        monetary_amount,
        r_score_global,
        f_score_global,
        m_score_global,
        rfm_total_score_global,
        r_score_scene,
        f_score_scene,
        m_score_scene,
        rfm_total_score_scene,
        -- 时间维度信息（基于统计日期）
        EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER AS stat_year,
        EXTRACT(MONTH FROM CURRENT_DATE)::INTEGER AS stat_month,
        EXTRACT(DAY FROM CURRENT_DATE)::INTEGER AS stat_day,
        EXTRACT(QUARTER FROM CURRENT_DATE)::INTEGER AS stat_quarter,
        EXTRACT(WEEK FROM CURRENT_DATE)::INTEGER AS stat_week,
        -- 客户分群逻辑（基于全局评分）
        CASE
            WHEN r_score_global >= 4 AND f_score_global >= 4 AND m_score_global >= 4 THEN '核心价值客户'
            WHEN r_score_global >= 4 AND f_score_global >= 4 AND m_score_global < 4  THEN '高频低贡献客户'
            WHEN r_score_global >= 4 AND f_score_global < 4  AND m_score_global >= 4 THEN '大额低频客户'
            WHEN r_score_global >= 4 AND f_score_global < 4  AND m_score_global < 4  THEN '新增客户'
            WHEN r_score_global < 4  AND f_score_global >= 4 AND m_score_global >= 4 THEN '流失预警客户'
            WHEN r_score_global < 4  AND f_score_global < 4  AND m_score_global >= 4 THEN '沉睡大户'
            WHEN r_score_global < 4  AND f_score_global >= 4 AND m_score_global < 4  THEN '潜力唤回客户'
            ELSE '无价值客户'
        END AS customer_segment_global,
        -- 客户分群逻辑（基于场景内评分）
        CASE
            WHEN r_score_scene >= 4 AND f_score_scene >= 4 AND m_score_scene >= 4 THEN '核心价值客户'
            WHEN r_score_scene >= 4 AND f_score_scene >= 4 AND m_score_scene < 4  THEN '高频低贡献客户'
            WHEN r_score_scene >= 4 AND f_score_scene < 4  AND m_score_scene >= 4 THEN '大额低频客户'
            WHEN r_score_scene >= 4 AND f_score_scene < 4  AND m_score_scene < 4  THEN '新增客户'
            WHEN r_score_scene < 4  AND f_score_scene >= 4 AND m_score_scene >= 4 THEN '流失预警客户'
            WHEN r_score_scene < 4  AND f_score_scene < 4  AND m_score_scene >= 4 THEN '沉睡大户'
            WHEN r_score_scene < 4  AND f_score_scene >= 4 AND m_score_scene < 4  THEN '潜力唤回客户'
            ELSE '无价值客户'
        END AS customer_segment_scene
    FROM rfm_scoring
)

SELECT
    -- 主键和时间维度
    customer_id,                                                      -- 客户ID
    stat_date,                                                        -- 统计日期（RFM计算执行日期）
    latest_trx_date,                                                  -- 最新业务日期
    scene_id,                                                         -- 场景ID
    scene_name,                                                       -- 场景名称

    -- 基础交易指标
    trx_count,                                                        -- 交易次数
    total_loan_amount,                                                -- 交易总金额
    total_interest_amount,                                            -- 利息总额
    total_loan_balance,                                               -- 借据余额总额

    -- RFM原始指标
    recency_days,                                                     -- 最近活跃天数（R）
    frequency_count,                                                  -- 交易频次（F）
    monetary_amount,                                                  -- 交易金额（M）

    -- 全局RFM评分（基于全部客户的分位数）
    r_score_global,                                                   -- R评分（全局）
    f_score_global,                                                   -- F评分（全局）
    m_score_global,                                                   -- M评分（全局）
    rfm_total_score_global,                                           -- RFM总分（全局）

    -- 场景内RFM评分（基于场景内客户的分位数）
    r_score_scene,                                                    -- R评分（场景内）
    f_score_scene,                                                    -- F评分（场景内）
    m_score_scene,                                                    -- M评分（场景内）
    rfm_total_score_scene,                                            -- RFM总分（场景内）

    -- 客户分群（全局）
    customer_segment_global,                                          -- 客户分群（全局）

    -- 客户分群（场景内）
    customer_segment_scene,                                           -- 客户分群（场景内）

    -- 时间维度信息
    stat_year,                                                        -- 统计年份
    stat_month,                                                       -- 统计月份
    stat_day,                                                         -- 统计日
    stat_quarter,                                                     -- 统计季度
    stat_week,                                                        -- 统计周

    -- 数据仓库字段
    CURRENT_DATE AS dw_update_date                                    -- 数据更新日期

FROM customer_segmentation
ORDER BY customer_id, latest_trx_date DESC
