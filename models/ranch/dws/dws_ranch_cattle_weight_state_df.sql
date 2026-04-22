-- =============================================
-- 模型名称：dws_ranch_cattle_weight_state_df
-- 模型描述：牛只称重当前状态表，记录每头牛的最新一次称重记录
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：dwd_ranch_cattle_weight_fact_i（DWD层称重明细）
--   - 更新策略：每日全量覆盖，计算最新称重状态，不保留历史数据
--   - 统计指标：最新称重日期、最新体重、称重类型、日增重、AI评分等称重指标
--   - 聚合逻辑：按牛只ID取称重日期最新的记录
--   - 命名说明：_state_df 表示当前称重状态快照，日全量覆盖，不保留历史
-- =============================================
{{ config(
    materialized='table',
    description='牛只称重当前状态表，记录每头牛的最新称重日期、体重、测量类型、日增重及AI评分',
    tags=['ranch', 'dws', 'state', 'cattle', 'weight', 'latest']
) }}

WITH weight_ranked AS (
    SELECT
        cattle_id,
        weight_date AS latest_weight_date,
        weight AS latest_weight,
        measure_type AS latest_measure_type,
        stall_id AS latest_weight_stall_id,
        customer_id AS latest_weight_customer_id,
        daily_gain AS latest_daily_gain,
        ai_score AS latest_ai_score,
        ROW_NUMBER() OVER (PARTITION BY cattle_id ORDER BY weight_date DESC) AS rn  -- 取每头牛最新称重
    FROM {{ ref('dwd_ranch_cattle_weight_fact_i') }}
    WHERE weight_date IS NOT NULL
)

SELECT
    cattle_id,                               -- 牛只ID
    latest_weight_date,                      -- 最新称重日期
    latest_weight,                           -- 最新体重
    latest_measure_type,                     -- 最新称重类型
    latest_weight_stall_id,                  -- 最新称重栏舍ID
    latest_weight_customer_id,               -- 最新称重客户ID
    latest_daily_gain,                       -- 最新日增重
    latest_ai_score,                         -- 最新AI评分
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM weight_ranked
WHERE rn = 1
ORDER BY cattle_id
