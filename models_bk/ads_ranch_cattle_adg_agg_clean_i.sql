-- =============================================
-- 模型名称：ads_ranch_cattle_adg_agg_clean_i
-- 模型描述：牧场域牛只ADG区间汇总清洗表
-- 作者：dbt
-- 创建时间：2026-04-17
-- 说明：
--   基于 dws_ranch_cattle_adg_agg_i 进行数据清洗，
--   剔除异常称重记录，为生长曲线建模提供干净数据。
--
--   清洗规则：
--   1. 体重范围过滤：30kg ~ 1200kg
--   2. ADG 极端值过滤：-0.5 ~ 3.0 kg/天
--   3. 称重间隔过滤：相邻称重间隔 ≤ 180 天
--   4. 体重单调性约束：相邻称重下降 > 5kg 次数 > 1 的牛只整头排除
--   5. 日龄有效性过滤：age_days 必须存在且 > 0（优先使用 age_days）
--   6. 生长阶段一致性：当前体重偏离阶段目标体重区间 > 20% 的记录剔除
-- =============================================
{{ config(
    materialized='table',
    description='牧场域牛只ADG区间汇总清洗表，剔除异常称重记录',
    tags=['ranch', 'ads', 'adg', 'clean', 'growth_curve']
) }}

WITH src AS (
    SELECT *
    FROM {{ ref('dws_ranch_cattle_adg_agg_i') }}
),

-- ============================================
-- 规则4：体重单调性约束
--   逻辑：对每头牛按时间排序，检查相邻称重是否下降 > 5kg。
--   若单头牛异常下降次数 > 1，则排除整头牛。
--   单条记录的牛只（无 prev_weight）默认视为合法（anomaly_drop_count = 0）。
-- ============================================
all_cattle AS (
    SELECT DISTINCT cattle_id
    FROM src
),

weight_monotonicity AS (
    SELECT
        cattle_id,
        COUNT(CASE WHEN (current_weight - prev_weight) < -5.0 THEN 1 END) AS anomaly_drop_count
    FROM src
    WHERE prev_weight IS NOT NULL
    GROUP BY cattle_id
),

valid_cattle AS (
    SELECT a.cattle_id
    FROM all_cattle a
    LEFT JOIN weight_monotonicity m ON a.cattle_id = m.cattle_id
    WHERE COALESCE(m.anomaly_drop_count, 0) <= 1
),

-- ============================================
-- 应用全部清洗规则
-- ============================================
cleaned AS (
    SELECT s.*
    FROM src s
    INNER JOIN valid_cattle v ON s.cattle_id = v.cattle_id
    WHERE 1 = 1
        -- 规则5：日龄有效性过滤
        -- dws_ranch_cattle_adg_agg_i 中 age_days 基于 birth_date 计算，
        -- 若 birth_date 缺失则为 NULL。生长曲线建模需要有效日龄。
        AND s.age_days IS NOT NULL
        AND s.age_days > 0

        -- 规则1：体重范围过滤 30kg ~ 1200kg
        -- 排除明显超出肉牛生物学合理范围的称重记录（如数据录入错误）
        AND s.current_weight >= 30.0
        AND s.current_weight <= 1200.0

        -- 规则2：ADG 极端值过滤 -0.5 ~ 3.0 kg/天
        -- 肉牛正常日增重一般在 0.5~2.5kg/天，超过此范围的记录视为测量/计算异常
        AND s.period_adg >= -0.5
        AND s.period_adg <= 3.0

        -- 规则3：称重间隔过滤 ≤180 天
        -- dws 层 interval_days 已计算为相邻两次称重的间隔。
        -- 间隔过长（>180天）的 ADG 会被严重平滑化，掩盖真实生长波动。
        AND s.interval_days <= 180

        -- 规则6：生长阶段一致性检查
        -- 若当前体重偏离 stage_start_weight ~ stage_end_weight 区间超过 20%，
        -- 则认为生长阶段匹配有误或称重记录异常。
        AND (
            s.stage_start_weight IS NULL
            OR s.stage_end_weight IS NULL
            OR (
                s.current_weight >= s.stage_start_weight * 0.8
                AND s.current_weight <= s.stage_end_weight * 1.2
            )
        )
)

SELECT *
FROM cleaned
ORDER BY stats_date, cattle_id
