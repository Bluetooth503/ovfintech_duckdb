-- =============================================
-- 模型名称：dws_ranch_stall_feed_agg_di
-- 模型描述：栏舍饲料投喂日汇总表（增量），按日期统计栏舍投喂执行和饲料结构
-- Dbt更新方式：增量（按日期）
-- 粒度：栏舍 × 日期
-- 说明：
--   - 数据源：ods_psi_livestock_consume + ods_psi_commodity + dim_ranch_stall + dwd_ranch_cattle_feed_fact_i
--   - 增量策略：按 feed_date 分区增量追加
--   - 统计指标：计划/实际投喂量、精粗料占比、头均采食量、头均饲料成本、容量利用率、饲料单价
--   - 聚合逻辑：按栏舍+日期聚合投喂消耗明细，关联栏舍维度和牛只快照计算效率指标
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['stats_date'],
    description='栏舍饲料投喂日汇总表，按日期统计栏舍投喂执行和饲料结构（增量更新）',
    tags=['ranch', 'dws', 'feed', 'stall', 'daily', 'agg', 'incremental']
) }}

-- ============================================
-- 栏舍日消耗明细（含饲料分类）
-- ============================================
WITH src_consume AS (
    SELECT
        c.consume_date,
        c.stall_id,
        c.ranch_id,
        c.recipe_id,
        c.commodity_id,
        CAST(c.plan_day_consume AS DOUBLE) AS plan_day_consume,
        CAST(c.act_day_consume AS DOUBLE) AS act_day_consume,
        com.name AS commodity_name,
        -- 饲料类型分类
        CASE WHEN com.type = '2' AND (com.name LIKE '%浓缩料%' OR com.name LIKE '%精料%' OR com.name LIKE '%玉米%' OR com.name LIKE '%豆粕%') THEN 'concentrate' WHEN com.type = '2' AND (com.name LIKE '%稻草%' OR com.name LIKE '%青贮%' OR com.name LIKE '%秸秆%' OR com.name LIKE '%干草%' OR com.name LIKE '%苜蓿%' OR com.name LIKE '%啤酒糟%') THEN 'roughage' WHEN com.type = '2' AND (com.name LIKE '%小苏打%' OR com.name LIKE '%益生菌%' OR com.name LIKE '%舔砖%' OR com.name LIKE '%预混料%') THEN 'additive' WHEN com.type = '3' THEN 'medicine' ELSE 'other' END AS feed_type
    FROM {{ ref('ods_psi_livestock_consume') }} c
    LEFT JOIN {{ ref('ods_psi_commodity') }} com ON c.commodity_id::VARCHAR = com.id::VARCHAR
    WHERE c.consume_date IS NOT NULL
),

-- ============================================
-- 按栏舍+日期聚合
-- ============================================
stall_daily_agg AS (
    SELECT
        consume_date AS stats_date,
        stall_id,
        ranch_id,
        recipe_id,
        SUM(plan_day_consume) AS plan_feed_quantity,
        SUM(act_day_consume) AS act_feed_quantity,
        SUM(CASE WHEN feed_type = 'concentrate' THEN act_day_consume ELSE 0 END) AS concentrate_quantity,
        SUM(CASE WHEN feed_type = 'roughage' THEN act_day_consume ELSE 0 END) AS roughage_quantity,
        SUM(CASE WHEN feed_type = 'additive' THEN act_day_consume ELSE 0 END) AS additive_quantity,
        SUM(CASE WHEN feed_type = 'medicine' THEN act_day_consume ELSE 0 END) AS medicine_quantity,
        SUM(CASE WHEN feed_type = 'other' THEN act_day_consume ELSE 0 END) AS other_quantity
    FROM src_consume
    GROUP BY consume_date, stall_id, ranch_id, recipe_id
),

-- ============================================
-- 栏舍维度信息
-- ============================================
lkp_stall AS (
    SELECT
        stall_id,
        stall_name,
        ranch_name,
        system_cattle_count,
        recipe_name
    FROM {{ ref('dim_ranch_stall') }}
    WHERE is_current = '1'
),

-- ============================================
-- 在栏牛只数（从快照表取）
-- ============================================
lkp_snapshot AS (
    SELECT
        stats_date,
        stall_id,
        COUNT(DISTINCT cattle_id) AS total_cattle_count
    FROM {{ ref('dws_ranch_cattle_weigh_agg_i') }}
    WHERE stats_date IS NOT NULL
    GROUP BY stats_date, stall_id
),

-- ============================================
-- 栏舍日饲料成本（从牛只投喂明细聚合）
-- ============================================
stall_feed_cost AS (
    SELECT
        feed_date AS stats_date,
        stall_id,
        SUM(act_feed_cost) AS total_feed_cost
    FROM {{ ref('dwd_ranch_cattle_feed_fact_i') }}
 WHERE feed_date IS NOT NULL
    GROUP BY feed_date, stall_id
),

-- ============================================
-- 合并所有信息
-- ============================================
final_join AS (
    SELECT
        d.stats_date,
        d.stall_id,
        d.ranch_id,
        d.recipe_id,
        d.plan_feed_quantity,
        d.act_feed_quantity,
        d.concentrate_quantity,
        d.roughage_quantity,
        d.additive_quantity,
        d.medicine_quantity,
        d.other_quantity,
        s.stall_name,
        s.ranch_name,
        s.system_cattle_count,
        s.recipe_name AS stall_recipe_name,
        COALESCE(sn.total_cattle_count, 0) AS total_cattle_count,
        fc.total_feed_cost
    FROM stall_daily_agg d
    LEFT JOIN lkp_stall s ON d.stall_id::VARCHAR = s.stall_id::VARCHAR
    LEFT JOIN lkp_snapshot sn ON d.stats_date = sn.stats_date AND d.stall_id::VARCHAR = sn.stall_id::VARCHAR
    LEFT JOIN stall_feed_cost fc ON d.stats_date = fc.stats_date AND d.stall_id::VARCHAR = fc.stall_id::VARCHAR
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- ====================
    -- 标识维度
    -- ====================
    stats_date,                               -- 统计日期
    ranch_id,                                 -- 牧场ID
    ranch_name,                               -- 牧场名称
    stall_id,                                 -- 栏舍ID
    stall_name,                               -- 栏舍名称
    recipe_id,                                -- 配方ID
    stall_recipe_name,                        -- 配方名称

    -- ====================
    -- 在栏规模
    -- ====================
    total_cattle_count,                       -- 当日在栏牛只数
    system_cattle_count,                      -- 栏舍设计容量
    -- 容量利用率
    CASE WHEN system_cattle_count > 0 THEN total_cattle_count / system_cattle_count ELSE NULL END AS capacity_utilization_rate,

    -- ====================
    -- 投喂执行指标
    -- ====================
    plan_feed_quantity,                       -- 日计划投喂总量
    act_feed_quantity,                        -- 日实际投喂总量
    -- 投喂计划完成率
    CASE WHEN plan_feed_quantity > 0 THEN act_feed_quantity / plan_feed_quantity ELSE NULL END AS feed_plan_completion_rate,
    -- 剩料量
    CASE WHEN plan_feed_quantity > act_feed_quantity THEN plan_feed_quantity - act_feed_quantity ELSE 0 END AS leftover_quantity,
    -- 剩料率
    CASE WHEN plan_feed_quantity > 0 THEN CASE WHEN plan_feed_quantity > act_feed_quantity THEN (plan_feed_quantity - act_feed_quantity) / plan_feed_quantity ELSE 0 END ELSE NULL END AS leftover_rate,

    -- ====================
    -- 饲料消耗结构
    -- ====================
    concentrate_quantity,                     -- 日精料消耗量
    roughage_quantity,                        -- 日粗料消耗量
    additive_quantity,                        -- 日添加剂消耗量
    medicine_quantity,                        -- 日药品消耗量
    other_quantity,                           -- 日其他饲料消耗量
    -- 精料占比
    CASE WHEN act_feed_quantity > 0 THEN concentrate_quantity / act_feed_quantity ELSE NULL END AS concentrate_ratio,
    -- 粗料占比
    CASE WHEN act_feed_quantity > 0 THEN roughage_quantity / act_feed_quantity ELSE NULL END AS roughage_ratio,
    -- 添加剂占比
    CASE WHEN act_feed_quantity > 0 THEN additive_quantity / act_feed_quantity ELSE NULL END AS additive_ratio,
    -- 药品占比
    CASE WHEN act_feed_quantity > 0 THEN medicine_quantity / act_feed_quantity ELSE NULL END AS medicine_ratio,
    -- 头均日采食量
    CASE WHEN total_cattle_count > 0 THEN act_feed_quantity / total_cattle_count ELSE NULL END AS avg_feed_intake_per_cattle,
    -- 头均日饲料成本
    CASE WHEN total_cattle_count > 0 THEN total_feed_cost / total_cattle_count ELSE NULL END AS avg_feed_cost_per_cattle,

    -- ====================
    -- 效率指标
    -- ====================
    -- 饲料平均单价
    CASE WHEN act_feed_quantity > 0 THEN total_feed_cost / act_feed_quantity ELSE NULL END AS feed_unit_price,
    total_feed_cost,                          -- 日饲料总成本

    -- 元数据
    CURRENT_TIMESTAMP AS dw_update_time       -- 数据仓库更新时间
FROM final_join
WHERE stats_date IS NOT NULL AND stall_id IS NOT NULL

-- {% if is_incremental() %}
-- AND stats_date > (SELECT COALESCE(MAX(stats_date), '1900-01-01'::DATE) FROM {{ this }})
-- {% endif %}

ORDER BY stats_date DESC, ranch_id, stall_id
