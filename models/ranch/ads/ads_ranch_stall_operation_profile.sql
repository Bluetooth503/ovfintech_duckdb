-- =============================================
-- 模型名称：ads_ranch_stall_operation_profile
-- 模型描述：栏舍运营画像，每个栏舍一条记录，汇总容量、绩效、饲料、品种分布等运营全貌
-- Dbt更新方式：全量
-- 粒度：栏舍级（1栏舍1行，最新状态）
-- 说明：
--   - 数据源：dim_ranch_stall（栏舍维度）+ dws_ranch_stall_capacity_agg_di（容量）+ dws_ranch_stall_performance_agg_di（绩效）+ dws_ranch_stall_feed_agg_di（饲料）
--   - 增量策略：全量刷新（table）
--   - 统计指标：设计容量、实际使用、容量利用率、ADG/料肉比、饲料投喂、品种分布、容量状态标签
-- =============================================
{{ config(
    materialized='table',
    description='栏舍运营画像，汇总每个栏舍的容量、绩效、饲料、品种分布等运营全貌',
    tags=['ranch', 'ads', 'operation', 'stall', 'profile']
) }}

WITH
-- ============================================
-- 1. 栏舍基础信息
-- ============================================
stall_base AS (
    SELECT
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        system_cattle_count,
        recipe_id,
        recipe_name,
        is_current
    FROM {{ ref('dim_ranch_stall') }}
    WHERE is_current = '1'
),

-- ============================================
-- 2. 最新容量统计
-- ============================================
latest_capacity AS (
    SELECT
        stall_id,
        stats_date AS latest_capacity_date,
        actual_cattle_count,
        actual_total_weight,
        cattle_capacity_utilization,
        capacity_status
    FROM (
        SELECT
            stall_id, stats_date, actual_cattle_count, actual_total_weight,
            cattle_capacity_utilization, capacity_status,
            ROW_NUMBER() OVER (PARTITION BY stall_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_capacity_agg_di') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

-- ============================================
-- 3. 最新绩效统计
-- ============================================
latest_performance AS (
    SELECT
        stall_id,
        stats_date AS latest_performance_date,
        total_cattle_count,
        weighed_cattle_count,
        avg_current_weight,
        avg_period_adg,
        avg_period_fcr,
        weight_add_ratio,
        herd_fcr,
        feed_cost_per_kg
    FROM (
        SELECT
            stall_id, stats_date, total_cattle_count, weighed_cattle_count,
            avg_current_weight, avg_period_adg, avg_period_fcr,
            weight_add_ratio, herd_fcr, feed_cost_per_kg,
            ROW_NUMBER() OVER (PARTITION BY stall_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_performance_agg_di') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

-- ============================================
-- 4. 最新饲料投喂统计（最近7天平均）
-- ============================================
latest_feed AS (
    SELECT
        stall_id,
        AVG(act_feed_quantity) AS avg_daily_feed_quantity,
        AVG(total_feed_cost) AS avg_daily_feed_cost,
        AVG(feed_plan_completion_rate) AS avg_feed_completion_rate,
        AVG(leftover_rate) AS avg_leftover_rate,
        AVG(concentrate_ratio) AS avg_concentrate_ratio,
        AVG(roughage_ratio) AS avg_roughage_ratio,
        AVG(avg_feed_intake_per_cattle) AS avg_feed_intake_per_cattle,
        AVG(avg_feed_cost_per_cattle) AS avg_feed_cost_per_cattle
    FROM (
        SELECT
            stall_id, stats_date, act_feed_quantity, total_feed_cost,
            feed_plan_completion_rate, leftover_rate, concentrate_ratio,
            roughage_ratio, avg_feed_intake_per_cattle, avg_feed_cost_per_cattle,
            ROW_NUMBER() OVER (PARTITION BY stall_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_feed_agg_di') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn <= 7
    GROUP BY stall_id
),

-- ============================================
-- 5. 品种分布（从最新容量记录获取）
-- ============================================
brand_distribution AS (
    SELECT
        stall_id,
        count_simmental,
        count_angus,
        count_charolais,
        count_limousin,
        actual_cattle_count AS total_count
    FROM (
        SELECT
            stall_id, count_simmental, count_angus, count_charolais, count_limousin, actual_cattle_count,
            ROW_NUMBER() OVER (PARTITION BY stall_id ORDER BY stats_date DESC) AS rn
        FROM {{ ref('dws_ranch_stall_capacity_agg_di') }}
        WHERE stats_date IS NOT NULL
    ) t
    WHERE rn = 1
),

-- ============================================
-- 6. 数据整合
-- ============================================
integrated AS (
    SELECT
        b.stall_id,
        b.stall_name,
        b.ranch_id,
        b.ranch_name,
        b.system_cattle_count,
        b.recipe_id,
        b.recipe_name,

        -- 最新容量
        lc.latest_capacity_date,
        lc.actual_cattle_count,
        lc.actual_total_weight,
        lc.cattle_capacity_utilization,
        lc.capacity_status,

        -- 容量利用率
        CASE WHEN b.system_cattle_count > 0
             THEN CAST(lc.actual_cattle_count AS DOUBLE) / b.system_cattle_count * 100
             ELSE NULL END AS capacity_utilization_pct,

        -- 最新绩效
        lp.latest_performance_date,
        lp.total_cattle_count,
        lp.weighed_cattle_count,
        lp.avg_current_weight,
        lp.avg_period_adg,
        lp.avg_period_fcr,
        lp.weight_add_ratio,
        lp.herd_fcr,
        lp.feed_cost_per_kg,

        -- 绩效覆盖率
        CASE WHEN lp.total_cattle_count > 0
             THEN CAST(lp.weighed_cattle_count AS DOUBLE) / lp.total_cattle_count * 100
             ELSE NULL END AS weigh_coverage_rate,

        -- 最新饲料投喂
        lf.avg_daily_feed_quantity,
        lf.avg_daily_feed_cost,
        lf.avg_feed_completion_rate,
        lf.avg_leftover_rate,
        lf.avg_concentrate_ratio,
        lf.avg_roughage_ratio,
        lf.avg_feed_intake_per_cattle,
        lf.avg_feed_cost_per_cattle,

        -- 品种分布
        bd.count_simmental,
        bd.count_angus,
        bd.count_charolais,
        bd.count_limousin,
        bd.total_count,

        -- 品种占比
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_simmental AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_simmental,
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_angus AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_angus,
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_charolais AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_charolais,
        CASE WHEN bd.total_count > 0
             THEN CAST(bd.count_limousin AS DOUBLE) / bd.total_count * 100
             ELSE NULL END AS pct_limousin

    FROM stall_base b
    LEFT JOIN latest_capacity lc ON CAST(b.stall_id AS VARCHAR) = CAST(lc.stall_id AS VARCHAR)
    LEFT JOIN latest_performance lp ON CAST(b.stall_id AS VARCHAR) = CAST(lp.stall_id AS VARCHAR)
    LEFT JOIN latest_feed lf ON CAST(b.stall_id AS VARCHAR) = CAST(lf.stall_id AS VARCHAR)
    LEFT JOIN brand_distribution bd ON CAST(b.stall_id AS VARCHAR) = CAST(bd.stall_id AS VARCHAR)
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 标识维度
    stall_id,                                -- 栏舍ID
    stall_name,                              -- 栏舍名称
    ranch_id,                                -- 牧场ID
    ranch_name,                              -- 牧场名称

    -- 配方信息
    recipe_id,                               -- 当前配方ID
    recipe_name,                             -- 当前配方名称

    -- 设计容量
    system_cattle_count,                     -- 设计容量（牛只数）

    -- 最新容量
    latest_capacity_date,                    -- 最新容量统计日期
    actual_cattle_count,                     -- 实际在栏数
    actual_total_weight,                     -- 实际总重量
    cattle_capacity_utilization,             -- 容量利用率
    capacity_status,                         -- 容量状态标签
    capacity_utilization_pct,                -- 容量利用率百分比

    -- 最新绩效
    latest_performance_date,                 -- 最新绩效统计日期
    total_cattle_count,                      -- 总牛只数
    weighed_cattle_count,                    -- 已称重牛只数
    weigh_coverage_rate,                     -- 称重覆盖率
    avg_current_weight,                      -- 平均体重
    avg_period_adg,                          -- 平均ADG
    avg_period_fcr,                          -- 平均料肉比
    weight_add_ratio,                        -- 增重率
    herd_fcr,                                -- 群体料肉比
    feed_cost_per_kg,                        -- 单位增重饲料成本

    -- 最新饲料投喂（最近7天平均）
    avg_daily_feed_quantity,                 -- 平均日投喂量
    avg_daily_feed_cost,                     -- 平均日饲料成本
    avg_feed_completion_rate,                -- 平均投喂完成率
    avg_leftover_rate,                       -- 平均剩料率
    avg_concentrate_ratio,                   -- 平均精料占比
    avg_roughage_ratio,                      -- 平均粗料占比
    avg_feed_intake_per_cattle,              -- 头均采食量
    avg_feed_cost_per_cattle,                -- 头均饲料成本

    -- 品种分布
    count_simmental,                         -- 西门塔尔数量
    count_angus,                             -- 安格斯数量
    count_charolais,                         -- 夏洛莱数量
    count_limousin,                          -- 利木赞数量
    total_count,                             -- 总数

    -- 品种占比
    pct_simmental,                           -- 西门塔尔占比
    pct_angus,                               -- 安格斯占比
    pct_charolais,                           -- 夏洛莱占比
    pct_limousin,                            -- 利木赞占比

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM integrated
ORDER BY ranch_id, stall_id
