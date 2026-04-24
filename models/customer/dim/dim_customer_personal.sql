-- =============================================
-- 模型名称：dim_customer_personal
-- 模型描述：个人会员维度表，记录个人会员基础信息及历史变更（SCD Type 2）
-- 粒度：customer_id
-- 说明：
--   - 数据源：ods_mem_member（个人会员表）、dim_customer_scene_rel（客户场景关系）
--   - 关联逻辑：LEFT JOIN 场景关系取最新子类ID，直接从客户场景关系获取层级信息
-- =============================================
{{ config(
    materialized='table',
    description='个人会员维度表，记录个人会员基础信息及历史变更（SCD Type 2）',
    tags=['customer', 'dim', 'personal', 'customer']
) }}

WITH customer_base AS (
    SELECT
        id AS customer_id,
        mem_code AS customer_code,
        name AS customer_name,
        mobile AS mobile_phone,
        idNo AS id_card_no,
        idType AS id_card_type,
        is_credit,
        email,
        gender,
        birthday,
        nation,
        edu,
        marriage,
        job,
        industry,
        nature,
        job_no,
        address AS residence_address,
        province,
        city,
        area,
        country,
        sign_status AS customer_status,
        is_deleted,
        create_time,
        update_time
    FROM {{ ref('ods_mem_member') }}
    WHERE is_deleted = '0'
),

-- 客户场景关系：取场景子类ID最大的记录
customer_scene_rel AS (
    SELECT
        customer_id,
        scene_level1_id,
        scene_level1_name,
        scene_level2_id,
        scene_level2_name,
        scene_path,
        regulatory_agency_org_id,
        regulatory_agency_name,
        fund_org_id,
        fund_org_name,
        branch_org_id,
        branch_org_name,
        sub_branch_org_id,
        sub_branch_org_name
    FROM {{ ref('dim_customer_scene_rel') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY scene_level2_id DESC) = 1
)

SELECT
    -- 主键
    mb.customer_id,                                                                            -- 客户ID
    mb.customer_code,                                                                          -- 客户编码
    -- 基础信息
    mb.customer_name,                                                                          -- 客户姓名
    mb.mobile_phone,                                                                           -- 手机号码
    mb.id_card_no,                                                                             -- 身份证号码
    mb.id_card_type,                                                                           -- 证件类型
    mb.email,                                                                                  -- 邮箱地址
    mb.gender,                                                                                 -- 性别
    mb.birthday,                                                                               -- 出生日期
    mb.nation,                                                                                 -- 国籍
    mb.edu,                                                                                    -- 学历
    mb.marriage,                                                                               -- 婚姻状况
    mb.job,                                                                                    -- 职业
    mb.industry,                                                                               -- 行业
    mb.nature,                                                                                 -- 性质
    mb.job_no,                                                                                 -- 工号
    -- 地址信息
    mb.residence_address,                                                                      -- 居住地址
    mb.province,                                                                               -- 省份
    mb.city,                                                                                   -- 城市
    mb.area,                                                                                   -- 区域
    mb.country,                                                                                -- 国家
    -- 信用相关
    CASE WHEN mb.is_credit = '1' THEN '1' ELSE '0' END AS is_credit_flag,                       -- 是否开通信用
    -- 场景信息
    csr.scene_level1_id,                                                                       -- 一级场景ID
    csr.scene_level1_name,                                                                     -- 一级场景名称
    csr.scene_level2_id,                                                                       -- 二级场景ID
    csr.scene_level2_name,                                                                     -- 二级场景名称
    csr.scene_path,                                                                            -- 场景路径
    -- 监管机构信息
    csr.regulatory_agency_org_id,                                                              -- 监管机构ID
    csr.regulatory_agency_name,                                                                -- 监管机构名称
    -- 管理组织信息
    csr.fund_org_id,                                                                           -- 资金方ID
    csr.fund_org_name,                                                                         -- 资金方名称
    csr.branch_org_id,                                                                         -- 经办机构分行ID
    csr.branch_org_name,                                                                       -- 经办机构分行名称
    csr.sub_branch_org_id,                                                                     -- 经办机构支行ID
    csr.sub_branch_org_name,                                                                   -- 经办机构支行名称
    -- 状态信息
    mb.customer_status,                                                                        -- 客户状态
    mb.create_time,                                                                            -- 创建时间
    mb.update_time,                                                                            -- 更新时间
    -- SCD Type 2 字段
    COALESCE(mb.update_time, mb.create_time) AS dw_effective_date,                             -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,                                -- 失效日期
    '1' AS is_current                                                                          -- 是否当前记录

FROM customer_base mb
LEFT JOIN customer_scene_rel csr ON mb.customer_id = csr.customer_id
