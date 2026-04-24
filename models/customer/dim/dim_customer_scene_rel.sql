-- =============================================
-- 模型名称：dim_customer_scene_rel
-- 模型描述：客户场景关系维度表，记录客户与业务场景的关联关系（桥接表）
-- 粒度：rel_id
-- 说明：
--   - 数据源：ods_customer_tag_assign（客户标签分配表）
--   - 关联关系：客户与场景多对多桥接
--   - 关联dim_scene获取场景层级名称及路径
-- =============================================
{{ config(
    materialized='table',
    description='客户场景关系维度表，记录客户与业务场景的关联关系（桥接表）',
    tags=['customer', 'scene', 'relation', 'bridge']
) }}

WITH customer_scene_rel AS (
    SELECT
        id AS rel_id,
        member_id AS customer_id,
        member_type,
        CASE WHEN member_type = 1 THEN '企业客户' WHEN member_type = 2 THEN '个人客户' ELSE '未知类型' END AS member_type_name,
        biz_scene_id AS scene_level1_id,
        biz_sub_category_id AS scene_level2_id,
        biz_manager_id,
        biz_manager_name,
        fund_org_id,
        fund_org_name,
        branch_org_id,
        branch_org_name,
        CAST(NULL AS INT) AS sub_branch_org_id,
        CAST(NULL AS VARCHAR) AS sub_branch_org_name,
        regulatory_agency_id AS regulatory_agency_org_id,
        regulatory_agency AS regulatory_agency_name,
        is_deleted,
        creator_id,
        creator_name,
        create_time,
        updator_id,
        updator_name,
        update_time
    FROM {{ ref('ods_customer_tag_assign') }}
    WHERE is_deleted = '0'
),

-- 关联场景维度表获取场景层级名称及路径
customer_scene_with_dim AS (
    SELECT
        cs.*,
        ds.level1_name AS scene_level1_name,
        ds.level2_name AS scene_level2_name,
        ds.scene_path
    FROM customer_scene_rel cs
    LEFT JOIN {{ ref('dim_scene') }} ds
        ON cs.scene_level2_id = ds.scene_id
)

SELECT
    -- 主键
    cs.rel_id                                                                   -- 关系ID
    -- 客户信息
    , cs.customer_id                                                            -- 客户ID
    , cs.member_type                                                            -- 客户类型（1=企业，2=个人）
    , cs.member_type_name                                                       -- 客户类型名称
    -- 场景信息
    , cs.scene_level1_id                                                        -- 一级业务场景ID
    , cs.scene_level1_name                                                      -- 一级业务场景名称
    , cs.scene_level2_id                                                        -- 二级业务子类ID
    , cs.scene_level2_name                                                      -- 二级业务子类名称
    , cs.scene_path                                                             -- 场景完整路径
    -- 管理组织信息
    , cs.biz_manager_id                                                         -- 业务经理ID
    , cs.biz_manager_name                                                       -- 业务经理名称
    , cs.fund_org_id                                                            -- 资金方ID
    , cs.fund_org_name                                                          -- 资金方名称
    , cs.branch_org_id                                                          -- 经办机构分行ID
    , cs.branch_org_name                                                        -- 经办机构分行名称
    , cs.sub_branch_org_id                                                      -- 经办机构支行ID
    , cs.sub_branch_org_name                                                    -- 经办机构支行名称
    , cs.regulatory_agency_org_id                                               -- 监管公司ID
    , cs.regulatory_agency_name                                                 -- 监管公司名称
    -- 审计信息
    , cs.creator_id                                                             -- 创建人ID
    , cs.creator_name                                                           -- 创建人名称
    , cs.create_time                                                            -- 创建时间
    , cs.updator_id                                                             -- 更新人ID
    , cs.updator_name                                                           -- 更新人名称
    , cs.update_time                                                            -- 更新时间
    -- SCD Type 2 字段
    , COALESCE(cs.update_time, cs.create_time) AS dw_effective_date             -- 生效日期
    , CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date                -- 失效日期
    , '1' AS is_current                                                         -- 是否当前记录

FROM customer_scene_with_dim cs
ORDER BY cs.customer_id, cs.scene_level1_id
