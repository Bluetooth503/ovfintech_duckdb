-- =============================================
-- 模型名称：dim_scene
-- 模型描述：场景维度表 - 层级打平
-- 作者：dbt
-- 创建时间：2026-04-10
-- =============================================
{{ config(
    materialized='table',
    description='场景维度表，记录业务场景配置及层级关系（层级打平）',
    tags=['scene', 'dim', 'cfg']
) }}

WITH scene_hierarchy AS (
    -- 基础场景数据
    SELECT
        id AS scene_id,
        scene_name,
        pid AS parent_id,
        p_name AS parent_name,
        is_deleted,
        creator_id,
        creator_name,
        updator_id,
        updator_name,
        create_time,
        updated_time,
        business_id,
        scene_max_stock_day
    FROM {{ ref('ods_scene_cfg') }}
),

scene_with_level AS (
    -- 计算层级和路径
    SELECT
        scene_id,
        scene_name,
        parent_id,
        parent_name,
        is_deleted,
        creator_id,
        creator_name,
        updator_id,
        updator_name,
        create_time,
        updated_time,
        business_id,
        scene_max_stock_day,
        -- 层级信息
        -- 一级分类为1，二级场景为2
        CASE WHEN parent_id = 0 THEN 1 ELSE 2 END AS scene_level,
        -- 一级分类ID：一级取自身，二级取父节点
        CASE WHEN parent_id = 0 THEN scene_id ELSE parent_id END AS level1_id,
        -- 一级分类名称：一级取自身，二级取父节点
        CASE WHEN parent_id = 0 THEN scene_name ELSE parent_name END AS level1_name,
        -- 二级场景ID：二级取自身，一级为NULL
        CASE WHEN parent_id != 0 THEN scene_id ELSE NULL END AS level2_id,
        -- 二级场景名称：二级取自身，一级为NULL
        CASE WHEN parent_id != 0 THEN scene_name ELSE NULL END AS level2_name,
        -- 完整路径：一级为自身，二级为父节点>自身
        CASE WHEN parent_id = 0 THEN scene_name ELSE parent_name || '>' || scene_name END AS scene_path
    FROM scene_hierarchy
    WHERE is_deleted = '0'
)

SELECT
    -- 主键
    swl.scene_id,                                                      -- 场景ID

    -- 场景基础信息
    swl.scene_name,                                                    -- 场景名称
    swl.scene_level,                                                   -- 层级（1一级分类，2二级场景）
    swl.scene_path,                                                    -- 完整路径

    -- 层级结构信息
    swl.level1_id,                                                     -- 一级分类ID
    swl.level1_name,                                                   -- 一级分类名称
    swl.level2_id,                                                     -- 二级场景ID
    swl.level2_name,                                                   -- 二级场景名称
    swl.parent_id,                                                     -- 父节点ID
    swl.parent_name,                                                   -- 父节点名称

    -- 业务配置信息
    swl.business_id,                                                   -- 业务ID
    swl.scene_max_stock_day,                                           -- 子类最大在库天数配置

    -- 审计信息
    swl.creator_id,                                                    -- 创建人ID
    swl.creator_name,                                                  -- 创建人姓名
    swl.updator_id,                                                    -- 更新人ID
    swl.updator_name,                                                  -- 更新人姓名
    swl.create_time,                                                   -- 创建时间
    swl.updated_time,                                                  -- 更新时间

    -- SCD Type 2 字段
    COALESCE(swl.updated_time, swl.create_time) AS dw_effective_date,  -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,        -- 失效日期
    '1' AS is_current                                                  -- 是否当前记录

FROM scene_with_level swl
ORDER BY swl.level1_id, swl.level2_id
