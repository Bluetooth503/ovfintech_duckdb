-- =============================================
-- 模型名称：dim_wms_warehouse
-- 模型描述：仓库维度表，记录仓库基础信息及历史变更（SCD Type 2）
-- 粒度：warehouse_id
-- 说明：
--   - 数据源：ods_warehouse（仓库表）、ods_warehouse_ext（仓库扩展表）、ods_warehouse_tag_assign（仓库标签分配表）
--   - 关联逻辑：LEFT JOIN 仓库扩展表、LEFT JOIN 仓库标签分配表
--   - 新增：仓库所有者信息（org_id作为仓库所有者）、资金方、分支行、业务场景、业务子类别、业务经理、巡检相关、租户信息、标签仓库类型
-- =============================================
{{ config(
    materialized='table',
    description='仓库维度表，记录仓库基础信息及历史变更（SCD Type 2）',
    tags=['wms', 'dim', 'warehouse']
) }}

WITH warehouse_base AS (
    SELECT
        id AS warehouse_id,
        code AS warehouse_no,
        name AS warehouse_name,
        type AS warehouse_type,
        attribute AS warehouse_attribute,
        use AS warehouse_purpose,
        province AS warehouse_province,
        address AS warehouse_address,
        contact_name,
        contact_phone,
        area AS warehouse_area,
        status AS warehouse_status,
        org_id AS warehouse_owner_id,
        org_name AS warehouse_owner_name,
        manager_member_id AS manager_customer_id,
        manager_org_id,
        supervise_type,
        remarks AS warehouse_remark,
        creator_name AS creator,
        CAST(create_time AS TIMESTAMP) AS create_time,
        is_deleted
    FROM {{ ref('ods_warehouse') }}
),

warehouse_ext AS (
    SELECT
        warehouse_id,
        max_storeage,
        has_insurance AS is_has_insurance,
        finance_type,
        property AS property_type
    FROM {{ ref('ods_warehouse_ext') }}
),

warehouse_tag_assign AS (
    SELECT
        warehouse_id,
        biz_manager_id,
        biz_manager_name,
        fund_org_id,
        fund_org_name,
        branch_org_id,
        branch_org_name,
        biz_scene_id AS scene_level1_id,
        biz_scene_name AS scene_level1_name,
        biz_sub_category_id AS scene_level2_id,
        biz_sub_category_name AS scene_level2_name,
        is_patrol,
        patrol_limit_num AS patrol_limit_count,
        ref_tenant_id AS rel_ranch_id,
        warehouse_type AS warehouse_ranch_type
    FROM {{ ref('ods_warehouse_tag_assign') }}
    WHERE is_deleted = '0' OR is_deleted = 'false'
)

SELECT
    wb.warehouse_id,                                    -- 仓库ID
    wb.warehouse_no,                                    -- 仓库编号
    wb.warehouse_name,                                  -- 仓库名称
    wb.warehouse_type,                                  -- 仓库类型
    wb.warehouse_attribute,                             -- 仓库属性
    wb.warehouse_purpose,                               -- 仓库用途
    wb.warehouse_status,                                -- 仓库状态
    wb.warehouse_province,                              -- 省份
    wb.warehouse_address,                               -- 仓库地址
    wb.contact_name,                                    -- 联系人姓名
    wb.contact_phone,                                   -- 联系人电话
    wb.warehouse_area,                                  -- 仓库面积
    wb.warehouse_owner_id,                              -- 仓库所有者ID
    wb.warehouse_owner_name,                            -- 仓库所有者名称
    wb.manager_customer_id,                             -- 仓库管理员ID
    wb.manager_org_id,                                  -- 仓库管理员所属组织
    wb.supervise_type,                                  -- 监管类型
    we.max_storeage ,                                   -- 最大存储量
    we.is_has_insurance,                                -- 是否有保险
    we.finance_type,                                    -- 金融类型
    we.property_type,                                   -- 产权类型
    wta.fund_org_id,                                    -- 资金方ID
    wta.fund_org_name,                                  -- 资金方名称
    wta.branch_org_id,                                  -- 经办机构分行ID
    wta.branch_org_name,                                -- 经办机构分行名称
    wta.scene_level1_id,                                -- 一级场景ID
    wta.scene_level1_name,                              -- 一级场景名称
    wta.scene_level2_id ,                               -- 二级场景ID
    wta.scene_level2_name,                              -- 二级场景名称
    wta.biz_manager_id,                                 -- 业务经理ID
    wta.biz_manager_name,                               -- 业务经理名称
    wta.is_patrol,                                      -- 是否巡检
    wta.patrol_limit_count,                             -- 巡检限制数量
    wta.rel_ranch_id,                                   -- 关联牧场ID
    wta.warehouse_ranch_type,                           -- 仓库牧场类型
    wb.warehouse_remark,                                -- 仓库备注
    wb.create_time,                                     -- 创建时间
    wb.creator,                                         -- 创建人
    wb.create_time AS dw_effective_date,                -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,  -- 失效日期
    '1' AS is_current                                            -- 是否当前记录

FROM warehouse_base AS wb
LEFT JOIN warehouse_ext AS we ON wb.warehouse_id = we.warehouse_id
LEFT JOIN warehouse_tag_assign AS wta ON wb.warehouse_id = wta.warehouse_id
WHERE wb.is_deleted = '0' OR wb.is_deleted = 'false'
