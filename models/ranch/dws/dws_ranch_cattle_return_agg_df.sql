-- =============================================
-- 模型名称：dws_ranch_cattle_return_agg_df
-- 模型描述：牛只退回聚合表（cattle-level），汇总每头已退回牛的退回信息
-- Dbt更新方式：全量
-- 粒度：牛只级（1牛1行）
-- 说明：
--   - 数据源：dwd_ranch_cattle_return_fact_i（DWD层退回明细）
--   - 增量策略：全量刷新
--   - 统计指标：退回日期、退回体重、退回单价、退回原因等退回指标
-- =============================================
{{ config(
    materialized='table',
    description='牛只退回聚合表，按牛只ID汇总退回日期、体重、价格及原因',
    tags=['ranch', 'dws', 'agg', 'cattle', 'return']
) }}

WITH return_detail AS (
    SELECT
        cattle_id,
        return_date,
        return_weight,
        return_price,
        reason AS return_reason,
        ranch_id AS return_ranch_id
    FROM {{ ref('dwd_ranch_cattle_return_fact_i') }}
    WHERE cattle_id IS NOT NULL
)

SELECT
    cattle_id,                               -- 牛只ID
    return_date,                             -- 退回日期
    return_weight,                           -- 退回体重
    return_price,                            -- 退回单价
    return_reason,                           -- 退回原因
    return_ranch_id,                         -- 退回牧场ID
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间
FROM return_detail
ORDER BY cattle_id
