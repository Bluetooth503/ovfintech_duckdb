-- =============================================
-- 模型名称：dim_customer_ranch_rel
-- 模型描述：客户与牧场映射关系表，从牛只维度表直接提取
-- Dbt更新方式：全量
-- 粒度：customer_id + ranch_id
-- 说明：
--   - 数据源：dim_ranch_cattle（牛只维度表），investor_id → customer_id 天然关联 ranch_id
--   - 1个客户可映射多个牧场（投资多牧场牛只）
--   - 关联逻辑：资金域 customer_id = 牧场域 customer_id（投资人/借款人是同一实体）
-- =============================================
{{ config(
    materialized='table',
    description='客户与牧场映射关系表，提供 customer_id 到 ranch_id 的精确映射',
    tags=['customer', 'dim', 'mapping', 'ranch', 'fund']
) }}

SELECT DISTINCT
    customer_id,                               -- 客户ID（投资人/借款人）
    ranch_id,                                  -- 牧场ID
    CURRENT_TIMESTAMP AS dw_update_time        -- 数据仓库更新时间
FROM {{ ref('dim_ranch_cattle') }}
WHERE is_current = '1'
