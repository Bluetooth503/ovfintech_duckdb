-- =============================================
-- 模型名称：dim_customer_company
-- 模型描述：企业会员维度表，记录企业会员基础信息及历史变更（SCD Type 2）
-- 粒度：customer_id
-- 说明：
--   - 数据源：ods_mem_company（企业会员表）、dim_customer_scene_rel（客户场景关系）、dim_scene（场景维度）
--   - 关联逻辑：LEFT JOIN 场景关系取最新子类ID，LEFT JOIN 场景维度获取层级信息
-- =============================================
{{ config(
    materialized='table',
    description='企业会员维度表，记录企业会员基础信息及历史变更（SCD Type 2）',
    tags=['customer', 'dim', 'company', 'enterprise']
) }}

WITH company_base AS (
    SELECT
        id AS customer_id,
        comp_name AS customer_name,
        short_name,
        idNo AS unified_credit_code,
        idType AS id_type,
        corporation AS legal_person,
        corp_mobile AS legal_mobile,
        corporation_idCard AS legal_id_no,
        capital AS register_capital,
        capital AS paid_capital,
        capital,
        currency_type AS currency,
        industry,
        type AS company_type,
        nature,
        business_scope,
        business_term,
        province AS register_province,
        city AS register_city,
        area AS register_area,
        found_date AS register_date,
        found_date AS start_date,
        sign_status AS company_status,
        is_credit,
        is_signed,
        seal_status,
        bus_seal_status,
        telephone,
        mailbox AS email,
        linkman,
        finance_mobile,
        is_org,
        is_enabled,
        is_deleted,
        create_time,
        update_time
    FROM {{ ref('ods_mem_company') }}
    WHERE is_deleted = '0'
),

-- 客户场景关系：取场景子类ID最大的记录
customer_scene_rel AS (
    SELECT
        customer_id,
        scene_id,
        scene_sub_category_id,
        regulatory_agency_org_id,
        regulatory_agency_name,
        fund_org_id,
        fund_org_name,
        branch_org_id,
        branch_org_name,
        sub_branch_org_id,
        sub_branch_org_name
    FROM {{ ref('dim_customer_scene_rel') }}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY scene_sub_category_id DESC) = 1
),

-- 场景维度信息
scene_info AS (
    SELECT
        scene_id,
        scene_level,
        scene_path,
        level1_id AS scene_level1_id,
        level1_name AS scene_level1_name,
        level2_id AS scene_level2_id,
        level2_name AS scene_level2_name
    FROM {{ ref('dim_scene') }}
)

SELECT
    -- 主键
    cb.customer_id,                                                                            -- 客户ID
    -- 基础信息
    cb.customer_name,                                                                          -- 企业名称
    cb.short_name,                                                                             -- 企业简称
    cb.unified_credit_code,                                                                    -- 统一社会信用代码
    cb.id_type,                                                                                -- 证件类型
    cb.legal_person,                                                                           -- 法定代表人
    cb.legal_mobile,                                                                           -- 法人手机号
    cb.legal_id_no,                                                                            -- 法人身份证号
    cb.linkman,                                                                                -- 联系人
    cb.telephone,                                                                              -- 联系电话
    cb.email,                                                                                  -- 邮箱
    -- 资本信息
    cb.register_capital,                                                                       -- 注册资本
    cb.paid_capital,                                                                           -- 实缴资本
    cb.capital,                                                                                -- 资本金额
    cb.currency,                                                                               -- 币种
    -- 行业与类型
    cb.industry,                                                                               -- 所属行业
    cb.company_type,                                                                           -- 企业类型
    cb.nature,                                                                                 -- 企业性质
    cb.business_scope,                                                                         -- 经营范围
    cb.business_term,                                                                          -- 经营期限
    -- 地址信息
    cb.register_province,                                                                      -- 注册省份
    cb.register_city,                                                                          -- 注册城市
    cb.register_area,                                                                          -- 注册区域
    -- 时间信息
    cb.register_date,                                                                          -- 注册日期
    cb.start_date,                                                                             -- 开始日期
    -- 信用与签约信息
    CASE WHEN cb.is_credit = '1' THEN '1' ELSE '0' END AS is_credit_flag,                      -- 是否开通信用
    CASE WHEN cb.is_signed = '1' THEN '1' ELSE '0' END AS is_signed_flag,                      -- 是否已签约
    cb.seal_status,                                                                            -- 印章状态
    cb.bus_seal_status,                                                                        -- 公章状态
    cb.finance_mobile,                                                                         -- 财务电话
    -- 组织信息
    CASE WHEN cb.is_org = '1' THEN '1' ELSE '0' END AS is_org_flag,                            -- 是否组织
    CASE WHEN cb.is_enabled = '1' THEN '1' ELSE '0' END AS is_enabled_flag,                    -- 是否启用
    -- 场景信息
    csr.scene_id,                                                                              -- 业务场景ID
    si.scene_level1_id,                                                                        -- 一级场景ID
    si.scene_level1_name,                                                                      -- 一级场景名称
    si.scene_level2_id,                                                                        -- 二级场景ID
    si.scene_level2_name,                                                                      -- 二级场景名称
    si.scene_path,                                                                             -- 场景路径
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
    cb.company_status,                                                                         -- 企业状态
    cb.create_time,                                                                            -- 创建时间
    cb.update_time,                                                                            -- 更新时间
    -- SCD Type 2 字段
    COALESCE(cb.update_time, cb.create_time) AS dw_effective_date,                             -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,                                -- 失效日期
    '1' AS is_current                                                                          -- 是否当前记录

FROM company_base cb
LEFT JOIN customer_scene_rel csr ON cb.customer_id = csr.customer_id
LEFT JOIN scene_info si ON csr.scene_id = si.scene_id
