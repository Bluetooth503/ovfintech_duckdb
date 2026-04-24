-- =============================================
-- 模型名称：dim_wms_warehouse_member_rel
-- 模型描述：仓库与成员关系维度表，记录仓库与成员之间的配置关联关系
-- 粒度：warehouse_id + member_id + org_id
-- 说明：
--   - 数据源：ods_warehouse_member（仓库成员表）
--   - 1个仓库可关联多个不同角色成员
--   - member_id = 0 表示组织本身（由 org_id 标识）
--   - member_type: 1=客户, 2=管理员
--   - role: 0=未知, 2=管理员, 3=运营, 4=其他
--   - role只是后来加的一个角色，用来区分是我们的运营还是在仓库的人
--   - 同一仓库+成员+组织组合可能存在重复或变更记录，取最新有效记录
-- =============================================
{{ config(
    materialized='table',
    description='仓库与成员关系维度表',
    tags=['wms', 'dim', 'rel', 'warehouse', 'member']
) }}

WITH member_dedup AS (
    SELECT
        warehouse_id,
        org_id,
        member_id,
        member_name,
        member_phone,
        member_type,
        role,
        is_deleted,
        -- 同一组合取未删除且ID最大的记录
        ROW_NUMBER() OVER (PARTITION BY warehouse_id, member_id, org_id ORDER BY CASE WHEN is_deleted = 0 THEN 0 ELSE 1 END, CAST(id AS INTEGER) DESC) AS rn
    FROM {{ ref('ods_warehouse_member') }}
)

SELECT
    m.warehouse_id,                                      -- 仓库ID
    w.warehouse_name,                                    -- 仓库名称
    m.org_id,                                            -- 机构ID
    m.member_id,                                         -- 成员ID
    m.member_name,                                       -- 成员名称
    m.member_phone,                                      -- 联系电话
    m.member_type,                                       -- 成员类型
    -- 成员类型名称
    CASE WHEN m.member_type = '1' THEN '客户' WHEN m.member_type = '2' THEN '管理员' ELSE '未知' END AS member_type_name,
    m.role,                                              -- 角色编码
    -- 角色名称
    CASE WHEN m.role = '2' THEN '管理员' WHEN m.role = '3' THEN '运营' WHEN m.role = '4' THEN '其他' ELSE '未知' END AS role_name,
    -- 是否组织本身
    CASE WHEN m.member_id = '0' THEN '1' ELSE '0' END AS is_org_self,
    CURRENT_TIMESTAMP AS dw_effective_date,              -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,  -- 失效日期
    '1' AS is_current,                                   -- 是否当前记录
    CURRENT_TIMESTAMP AS dw_update_time                  -- 数据仓库更新时间

FROM member_dedup AS m
LEFT JOIN {{ ref('dim_wms_warehouse') }} AS w ON m.warehouse_id = w.warehouse_id AND w.is_current = '1'
WHERE m.rn = 1
  AND m.is_deleted = 0
