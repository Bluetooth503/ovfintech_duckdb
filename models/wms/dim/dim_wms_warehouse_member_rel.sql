-- =============================================
-- 模型名称：dim_wms_warehouse_member_rel
-- 模型描述：仓库与成员（货主）关系维度表，记录仓库与成员之间的配置关联关系
-- 粒度：warehouse_id + member_id + org_id
-- 说明：
--   - 数据源：ods_warehouse_member（仓库成员表）
--   - 1个仓库可关联多个成员（货主），1个成员可在多个仓库存储货物
--   - 与 dim_wms_warehouse_goods_owner_rel 的区别：本表来源于系统配置，记录"应该"存在的关系；
--     dim_wms_warehouse_goods_owner_rel 来源于库存事实，记录"实际发生"的业务关系
--   - member_id = 0 表示组织本身（由 org_id 标识）
--   - member_type: 1=客户, 2=管理员
--   - role: 2=管理员, 3=运营, 4=其他
--   - 同一仓库+成员+组织组合可能存在重复或变更记录，取最新有效记录
-- =============================================
{{ config(
    materialized='table',
    description='仓库与成员（货主）关系维度表',
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
        ROW_NUMBER() OVER (
            PARTITION BY warehouse_id, member_id, org_id
            ORDER BY
                CASE WHEN is_deleted = '0' OR is_deleted = 'false' THEN 0 ELSE 1 END,
                CAST(id AS INTEGER) DESC
        ) AS rn
    FROM {{ ref('ods_warehouse_member') }}
)

SELECT
    warehouse_id,                                       -- 仓库ID
    org_id,                                             -- 组织/租户ID
    member_id,                                          -- 成员ID（货主ID）
    member_name,                                        -- 成员名称（货主名称）
    member_phone,                                       -- 联系电话
    member_type,                                        -- 成员类型（1=客户, 2=管理员）
    CASE
        WHEN member_type = '1' THEN '客户'
        WHEN member_type = '2' THEN '管理员'
        ELSE '未知'
    END AS member_type_name,                            -- 成员类型名称
    role,                                               -- 角色编码
    CASE
        WHEN role = '2' THEN '管理员'
        WHEN role = '3' THEN '运营'
        WHEN role = '4' THEN '其他'
        ELSE '未知'
    END AS role_name,                                   -- 角色名称
    CASE
        WHEN member_id = '0' THEN '1'
        ELSE '0'
    END AS is_org_self,                                 -- 是否组织本身
    CURRENT_TIMESTAMP AS dw_effective_date,             -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,  -- 失效日期
    '1' AS is_current,                                  -- 是否当前记录
    CURRENT_TIMESTAMP AS dw_update_time                 -- 数据仓库更新时间

FROM member_dedup
WHERE rn = 1
  AND (is_deleted = '0' OR is_deleted = 'false')
