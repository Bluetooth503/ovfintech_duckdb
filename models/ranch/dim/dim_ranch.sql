-- =============================================
-- 模型名称：dim_ranch
-- 模型描述：牧场维度表，记录牧场基本信息及历史变更（SCD Type 2）
-- 粒度：ranch_id
-- 说明：
--   - 数据源：ods_sys_tenant（租户主表）、ods_ranch（牧场信息表）
--   - 关联逻辑：LEFT JOIN 租户主表与牧场信息表
-- =============================================
{{ config(
    materialized='table',
    description='牧场维度表，记录牧场的基本信息和历史变更（SCD Type 2）。合并 sys_tenant（主表）和 ranch（信息表）',
    tags=['ranch', 'dim']
) }}

WITH
-- 租户主表
sys_tenant AS (
    SELECT
        id,
        name,
        CAST(create_time AS TIMESTAMP) AS create_time,
        create_by,
        CAST(begin_date AS TIMESTAMP) AS start_date,
        CAST(end_date AS TIMESTAMP) AS end_date,
        status,
        pre_code,
        kpt_url,
        kpt_cookie_key
    FROM {{ ref('ods_sys_tenant') }}
),

-- 牧场信息表
ranch_info AS (
    SELECT
        id,
        tenant_id,
        name AS ranch_name,
        name_abbr,
        code AS ranch_code,
        address,
        owner,
        phone,
        status AS ranch_status,
        remark,
        employees_num,
        adcode,
        map_position,
        CAST(update_time AS TIMESTAMP) AS update_time
    FROM {{ ref('ods_ranch') }}
)

-- 合并两个表
SELECT
    t.id AS ranch_id,                                        -- 牧场ID
    t.name AS ranch_name,                                    -- 牧场名称
    r.name_abbr AS ranch_abbr_desc,                          -- 牧场简要描述
    r.ranch_code,                                            -- 牧场编码
    r.address AS ranch_address,                              -- 牧场地址
    r.owner AS ranch_owner,                                  -- 负责人
    r.phone AS ranch_contact_phone_no,                       -- 联系电话
    CAST(t.status AS VARCHAR) AS ranch_status,               -- 牧场状态
    r.remark AS ranch_remark,                                -- 备注
    r.employees_num AS employees_count,                      -- 员工数量
    r.adcode,                                                -- 行政区划代码
    r.map_position,                                          -- 地图位置坐标
    t.start_date,                                            -- 开始日期
    t.end_date,                                              -- 结束日期
    t.create_time,                                           -- 创建时间
    r.update_time,                                           -- 更新时间
    -- SCD Type 2 字段
    t.create_time AS dw_effective_date,                           -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,   -- 失效日期
    '1' AS is_current                                        -- 是否当前记录
FROM sys_tenant AS t
LEFT JOIN ranch_info AS r ON CAST(t.id AS VARCHAR) = r.tenant_id
