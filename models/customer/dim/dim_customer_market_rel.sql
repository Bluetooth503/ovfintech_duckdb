-- =============================================
-- 模型名称：dim_customer_market_rel
-- 模型描述：客户市场关系维度表，记录客户与市场的关联关系（桥接表）
-- 粒度：rel_id
-- 说明：
--   - 数据源：ods_market_participant（市场参与方表）
--   - 关联关系：客户与市场多对多桥接
-- =============================================
{{ config(
    materialized='table',
    description='客户市场关系维度表，记录客户与市场的关联关系（桥接表）',
    tags=['customer', 'market', 'relation', 'bridge']
) }}

WITH customer_market_rel AS (
    SELECT
        id AS rel_id,
        member_id AS customer_id,
        member_type,
        market_id,
        market_name
    FROM {{ ref('ods_market_participant') }}
),

-- 客户类型名称映射：1=企业客户，2=个人客户，其他=未知类型
customer_market_with_type AS (
    SELECT
        rel_id,
        customer_id,
        market_id,
        market_name,
        member_type,
        CASE WHEN member_type = 1 THEN '企业客户' WHEN member_type = 2 THEN '个人客户' ELSE '未知类型' END AS member_type_name
    FROM customer_market_rel
)

SELECT
    -- 主键
    cm.rel_id                                                                   -- 关系ID
    -- 客户信息
    , cm.customer_id                                                            -- 客户ID
    , cm.member_type                                                            -- 客户类型（1=企业，2=个人）
    , cm.member_type_name                                                       -- 客户类型名称
    -- 市场信息
    , cm.market_id                                                              -- 市场ID
    , cm.market_name                                                            -- 市场名称
    -- SCD Type 2 字段
    , CAST('1970-01-01 00:00:00' AS TIMESTAMP) AS dw_effective_date             -- 生效日期
    , CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date                -- 失效日期
    , '1' AS is_current                                                         -- 是否当前记录

FROM customer_market_with_type cm
ORDER BY cm.customer_id, cm.market_id
