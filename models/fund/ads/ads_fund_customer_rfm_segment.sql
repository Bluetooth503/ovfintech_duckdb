-- =============================================
-- 模型名称：ads_fund_customer_rfm_segment
-- 模型描述：RFM客户分群应用表 - 支持Dashboard展示（按场景分组）
-- 作者：dbt
-- 创建时间：2026-04-13
-- =============================================
{{ config(
    materialized='table',
    description='RFM客户分群应用表，提供客户价值分析Dashboard所需数据（支持场景维度）',
    tags=['fund', 'ads', 'rfm', 'segment', 'dashboard', 'scene']
) }}

WITH customer_latest_rfm AS (
    -- 获取每个客户最新的RFM指标（全局）
    SELECT DISTINCT ON (customer_id)
        customer_id,
        trx_date AS latest_trx_date,
        scene_id,
        scene_name,
        trx_count,
        total_trx_amount,
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
        customer_segment_global,
        customer_value_level_global,
        customer_segment_scene,
        customer_value_level_scene
    FROM {{ ref('dws_fund_customer_rfm_1d_d') }}
    ORDER BY customer_id, trx_date DESC
),

customer_lifetime_stats AS (
    -- 计算客户全生命周期统计（全局）
    SELECT
        customer_id,
        COUNT(trx_date) AS lifetime_trx_days,
        SUM(trx_count) AS lifetime_total_trx_count,
        SUM(total_trx_amount) AS lifetime_total_amount,
        MIN(trx_date) AS first_trx_date,
        MAX(trx_date) AS last_trx_date,
        AVG(trx_count) AS avg_daily_trx_count,
        AVG(total_trx_amount) AS avg_daily_amount,
        SUM(CASE WHEN trx_date >= CURRENT_DATE - INTERVAL '30 days' THEN trx_count ELSE 0 END) AS last_30d_trx_count,
        SUM(CASE WHEN trx_date >= CURRENT_DATE - INTERVAL '30 days' THEN total_trx_amount ELSE 0 END) AS last_30d_amount,
        SUM(CASE WHEN trx_date >= CURRENT_DATE - INTERVAL '90 days' THEN trx_count ELSE 0 END) AS last_90d_trx_count,
        SUM(CASE WHEN trx_date >= CURRENT_DATE - INTERVAL '90 days' THEN total_trx_amount ELSE 0 END) AS last_90d_amount
    FROM {{ ref('dws_fund_customer_rfm_1d_d') }}
    GROUP BY customer_id
),

segment_stats AS (
    -- 计算各分群的统计数据（全局）
    SELECT
        customer_segment_global,
        COUNT(DISTINCT customer_id) AS segment_customer_count,
        SUM(lifetime_total_amount) AS segment_total_amount,
        AVG(lifetime_total_amount) AS segment_avg_amount,
        AVG(lifetime_total_trx_count) AS segment_avg_trx_count,
        AVG(lifetime_total_amount / NULLIF(lifetime_total_trx_count, 0)) AS segment_avg_per_trx
    FROM customer_lifetime_stats cls
    JOIN customer_latest_rfm clr ON cls.customer_id = clr.customer_id
    GROUP BY customer_segment_global
),

total_stats AS (
    -- 总体统计
    SELECT
        COUNT(DISTINCT customer_id) AS total_customers,
        SUM(lifetime_total_amount) AS total_amount,
        COUNT(DISTINCT CASE WHEN rfm_total_score_global >= 13 THEN customer_id END) AS core_customer_count,
        SUM(CASE WHEN m_score_global = 5 THEN lifetime_total_amount ELSE 0 END) AS large_amount_total
    FROM customer_lifetime_stats cls
    JOIN customer_latest_rfm clr ON cls.customer_id = clr.customer_id
),

scene_stats AS (
    -- 场景维度统计
    SELECT
        scene_id,
        scene_name,
        COUNT(DISTINCT customer_id) AS scene_customer_count,
        SUM(lifetime_total_amount) AS scene_total_amount,
        AVG(rfm_total_score_global) AS scene_avg_rfm_score
    FROM customer_lifetime_stats cls
    JOIN customer_latest_rfm clr ON cls.customer_id = clr.customer_id
    GROUP BY scene_id, scene_name
)

SELECT
    -- 客户基本信息
    clr.customer_id,                                                   -- 客户ID
    clr.scene_id,                                                      -- 场景ID
    clr.scene_name,                                                    -- 场景名称

    -- RFM原始指标
    clr.recency_days,                                                 -- 最近活跃天数
    clr.frequency_count,                                              -- 购买次数
    clr.monetary_amount,                                              -- 购买金额

    -- 全局RFM评分
    clr.r_score_global,                                              -- R评分（全局）
    clr.f_score_global,                                              -- F评分（全局）
    clr.m_score_global,                                              -- M评分（全局）
    clr.rfm_total_score_global,                                      -- RFM总分（全局）

    -- 场景内RFM评分
    clr.r_score_scene,                                               -- R评分（场景内）
    clr.f_score_scene,                                               -- F评分（场景内）
    clr.m_score_scene,                                               -- M评分（场景内）
    clr.rfm_total_score_scene,                                       -- RFM总分（场景内）

    -- 客户分群（全局）
    clr.customer_segment_global,                                     -- 客户分群（全局）
    clr.customer_value_level_global,                                 -- 客户价值等级（全局）

    -- 客户分群（场景内）
    clr.customer_segment_scene,                                      -- 客户分群（场景内）
    clr.customer_value_level_scene,                                  -- 客户价值等级（场景内）

    -- 客户全生命周期指标
    cls.lifetime_trx_days,                                           -- 交易天数
    cls.lifetime_total_trx_count,                                    -- 总交易次数
    cls.lifetime_total_amount,                                       -- 总交易金额
    cls.first_trx_date,                                              -- 首次交易日期
    cls.last_trx_date,                                               -- 最后交易日期
    cls.avg_daily_trx_count,                                         -- 日均交易次数
    cls.avg_daily_amount,                                            -- 日均交易金额

    -- 最近30天指标
    cls.last_30d_trx_count,                                          -- 最近30天交易次数
    cls.last_30d_amount,                                             -- 最近30天交易金额

    -- 最近90天指标
    cls.last_90d_trx_count,                                          -- 最近90天交易次数
    cls.last_90d_amount,                                             -- 最近90天交易金额

    -- 分群统计信息（全局）
    ss.segment_customer_count,                                       -- 分群客户数
    ss.segment_total_amount,                                         -- 分群总金额
    ss.segment_avg_amount,                                           -- 分群平均金额
    ss.segment_avg_trx_count,                                        -- 分群平均交易次数
    ss.segment_avg_per_trx,                                          -- 分群平均单笔金额

    -- 占比信息
    ROUND(cls.lifetime_total_amount / NULLIF(ts.total_amount, 0) * 100, 2) AS amount_contribution_ratio,  -- 金额贡献占比
    ROUND(ss.segment_customer_count::FLOAT / NULLIF(ts.total_customers, 0) * 100, 2) AS segment_customer_ratio,  -- 分群客户占比

    -- 场景统计信息
    sstats.scene_customer_count,                                     -- 场景客户数
    sstats.scene_total_amount,                                       -- 场景总金额
    sstats.scene_avg_rfm_score,                                      -- 场景平均RFM分数

    -- 总体统计
    ts.total_customers,                                              -- 总客户数
    ts.total_amount,                                                 -- 总金额
    ts.core_customer_count,                                          -- 核心客户数
    ts.large_amount_total,                                           -- 大额客户总金额

    -- 分群描述和策略（全局）
    CASE clr.customer_segment_global
        WHEN '核心价值客户' THEN '高频|高额|近期活跃，是公司的高价值客户，需要重点维护和营销'
        WHEN '高频低贡献客户' THEN '高频|低额|近期活跃，频繁借款但单笔金额较低，贡献有限'
        WHEN '大额低频客户' THEN '低频|高额|近期活跃，单笔金额大但借款频率低，需关注其业务模式和需求'
        WHEN '新增客户' THEN '低频|低额|近期活跃，近期开始借款，处于观察期，需评估其长期价值潜力'
        WHEN '流失预警客户' THEN '高额|高频|不活跃，历史价值高但近期不活跃，存在流失风险'
        WHEN '沉睡大户' THEN '低频|高额|不活跃，历史贡献高但长期未活跃，属于重点唤醒对象'
        WHEN '潜力唤回客户' THEN '高频|低额|不活跃，活跃度高但贡献有限，通过适当引导可能成为优质客户'
        WHEN '无价值客户' THEN '低频|低额|不活跃，各项指标均偏低，属于低价值客户群'
        ELSE '未知分群'
    END AS segment_description,                                        -- 分群描述

    CASE clr.customer_segment_global
        WHEN '核心价值客户' THEN '重点维护和营销，提供VIP服务，主动提供一体化融资方案'
        WHEN '高频低贡献客户' THEN '推荐存货质押融资等适合小额高频的产品，引导提升单笔金额'
        WHEN '大额低频客户' THEN '关注业务模式和需求周期，避免流失，提供灵活融资方案'
        WHEN '新增客户' THEN '流程简化，费率优惠，业务培训，快速完成首次融资体验'
        WHEN '流失预警客户' THEN '主动挽回，风险排查，资产保全，实地调研了解不活跃原因'
        WHEN '沉睡大户' THEN '重点唤醒，资产盘点，担保强化，专项优惠'
        WHEN '潜力唤回客户' THEN '业务回访，产品推荐，增信措施，激励政策'
        WHEN '无价值客户' THEN '维持基础服务，降低运营成本'
        ELSE '未知策略'
    END AS segment_strategy,                                           -- 营销策略

    -- 客户价值等级颜色标识（全局）
    CASE clr.customer_value_level_global
        WHEN 'S级' THEN '#FF0000'
        WHEN 'A级' THEN '#FF9900'
        WHEN 'B级' THEN '#FFFF00'
        WHEN 'C级' THEN '#808080'
        ELSE '#CCCCCC'
    END AS value_level_color_global,                                   -- 价值等级颜色（全局）

    -- 客户价值等级颜色标识（场景内）
    CASE clr.customer_value_level_scene
        WHEN 'S级' THEN '#FF0000'
        WHEN 'A级' THEN '#FF9900'
        WHEN 'B级' THEN '#FFFF00'
        WHEN 'C级' THEN '#808080'
        ELSE '#CCCCCC'
    END AS value_level_color_scene,                                    -- 价值等级颜色（场景内）

    -- 更新时间
    CURRENT_TIMESTAMP AS data_update_time,                              -- 数据更新时间
    CURRENT_DATE AS data_update_date                                    -- 数据更新日期

FROM customer_latest_rfm clr
JOIN customer_lifetime_stats cls ON clr.customer_id = cls.customer_id
JOIN segment_stats ss ON clr.customer_segment_global = ss.customer_segment_global
CROSS JOIN total_stats ts
LEFT JOIN scene_stats sstats ON clr.scene_id = sstats.scene_id

ORDER BY
    CASE clr.customer_segment_global
        WHEN '核心价值客户' THEN 1
        WHEN '高频低贡献客户' THEN 2
        WHEN '大额低频客户' THEN 3
        WHEN '新增客户' THEN 4
        WHEN '流失预警客户' THEN 5
        WHEN '沉睡大户' THEN 6
        WHEN '潜力唤回客户' THEN 7
        WHEN '无价值客户' THEN 8
        ELSE 9
    END,
    clr.rfm_total_score_global DESC,
    clr.monetary_amount DESC
