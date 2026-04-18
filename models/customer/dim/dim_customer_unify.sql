-- =============================================
-- 模型名称：dim_customer_unify
-- 模型描述：客户统一维度表，整合个人会员和企业会员的统一客户视图
-- 粒度：customer_id
-- 说明：
--   - 数据源：dim_customer_personal（个人会员维度）、dim_customer_company（企业会员维度）
--   - 聚合逻辑：UNION ALL 合并个人和企业客户，统一字段命名
-- =============================================
{{ config(
    materialized='table',
    description='客户统一维度表，整合个人会员和企业会员的统一客户视图',
    tags=['customer', 'dim', 'unify', 'master']
) }}

WITH personal_customers AS (
    SELECT
        customer_id,
        customer_code,
        customer_name,
        mobile_phone AS contact_mobile,
        email AS contact_email,
        id_card_no AS id_no,
        id_card_type AS id_type,
        residence_address AS register_address,
        customer_status,
        gender,
        birthday,
        nation,
        edu,
        marriage,
        job,
        industry,
        province,
        city,
        area,
        country,
        create_time,
        update_time,
        is_credit_flag,
        scene_id,
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
    FROM {{ ref('dim_customer_personal') }}
    WHERE is_current = '1'
),

company_customers AS (
    SELECT
        customer_id,
        short_name AS customer_code,
        customer_name,
        legal_mobile AS contact_mobile,
        email AS contact_email,
        unified_credit_code AS id_no,
        id_type,
        register_province || register_city || register_area AS register_address,
        company_status AS customer_status,
        CAST(NULL AS VARCHAR) AS gender,
        CAST(NULL AS DATE) AS birthday,
        CAST(NULL AS VARCHAR) AS nation,
        CAST(NULL AS VARCHAR) AS edu,
        CAST(NULL AS VARCHAR) AS marriage,
        CAST(NULL AS VARCHAR) AS job,
        industry,
        register_province AS province,
        register_city AS city,
        register_area AS area,
        CAST(NULL AS VARCHAR) AS country,
        create_time,
        update_time,
        is_credit_flag,
        scene_id,
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
    FROM {{ ref('dim_customer_company') }}
    WHERE is_current = '1'
),

-- 合并个人和企业客户
all_customers AS (
    SELECT
        customer_id,
        customer_code,
        customer_name,
        contact_mobile,
        contact_email,
        id_no,
        id_type,
        register_address,
        customer_status,
        gender,
        birthday,
        nation,
        edu,
        marriage,
        job,
        industry,
        province,
        city,
        area,
        country,
        create_time,
        update_time,
        is_credit_flag,
        scene_id,
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
        sub_branch_org_name,
        'personal' AS customer_type
    FROM personal_customers
    UNION ALL
    SELECT
        customer_id,
        customer_code,
        customer_name,
        contact_mobile,
        contact_email,
        id_no,
        id_type,
        register_address,
        customer_status,
        gender,
        birthday,
        nation,
        edu,
        marriage,
        job,
        industry,
        province,
        city,
        area,
        country,
        create_time,
        update_time,
        is_credit_flag,
        scene_id,
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
        sub_branch_org_name,
        'company' AS customer_type
    FROM company_customers
)

SELECT
    -- 主键
    customer_id,                                                                             -- 客户ID（主键）
    customer_code,                                                                           -- 客户编码
    -- 客户分类
    customer_type,                                                                           -- 客户类型（personal/company）
    -- 基础信息
    customer_name,                                                                           -- 客户名称
    contact_mobile,                                                                         -- 联系手机
    contact_email,                                                                          -- 联系邮箱
    id_no,                                                                                   -- 证件号码
    id_type,                                                                                 -- 证件类型
    register_address,                                                                       -- 注册地址
    -- 个人特有信息
    gender,                                                                                  -- 性别
    birthday,                                                                                -- 出生日期
    nation,                                                                                  -- 国籍
    edu,                                                                                     -- 学历
    marriage,                                                                                -- 婚姻状况
    job,                                                                                     -- 职业
    -- 行业与地区
    industry,                                                                                -- 所属行业
    province,                                                                                -- 省份
    city,                                                                                    -- 城市
    area,                                                                                    -- 区域
    country,                                                                                 -- 国家
    -- 场景信息
    scene_id,                                                                                -- 业务场景ID
    scene_level1_id,                                                                         -- 一级场景ID
    scene_level1_name,                                                                       -- 一级场景名称
    scene_level2_id,                                                                         -- 二级场景ID
    scene_level2_name,                                                                       -- 二级场景名称
    scene_path,                                                                              -- 场景路径
    -- 管理组织信息
    fund_org_id,                                                                             -- 资金方ID
    fund_org_name,                                                                           -- 资金方名称
    branch_org_id,                                                                           -- 经办机构分行ID
    branch_org_name,                                                                         -- 经办机构分行名称
    sub_branch_org_id,                                                                       -- 经办机构支行ID
    sub_branch_org_name,                                                                     -- 经办机构支行名称
    -- 监管机构信息
    regulatory_agency_org_id,                                                                -- 监管机构ID
    regulatory_agency_name,                                                                  -- 监管机构名称
    -- 状态信息
    customer_status,                                                                         -- 客户状态
    is_credit_flag,                                                                          -- 是否开通信用
    create_time,                                                                             -- 创建时间
    update_time,                                                                             -- 更新时间
    -- SCD Type 2 字段
    COALESCE(update_time, create_time) AS dw_effective_date,                                 -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,                              -- 失效日期
    '1' AS is_current                                                                        -- 是否当前记录

FROM all_customers
