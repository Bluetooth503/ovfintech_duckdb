-- =============================================
-- 模型名称：dwd_fund_promissory_note_fact_i
-- 模型描述：借据明细事实表，记录每笔借据的详细信息及余额变化
-- Dbt更新方式：增量（事件级）
-- 粒度：promissory_note_id
-- 说明：
--   - 数据源：ods_fund_debt（借据表）+ ods_fund_debt_apply（借据申请表）
--   - 增量策略：按 trx_date 分区，append
--   - 过滤规则：排除测试数据（contract_code='jk00001'、loan_no LIKE 'cs%'）
--   - 字段映射：promissory_note_balance 为核心字段，用于判断客户是否有贷款余额
--   - 术语规范：遵循 glossary/术语库.csv 标准命名
-- =============================================
{{ config(
    materialized='incremental',
    incremental_strategy='append',
    partition_by=['trx_date'],
    description='借据明细事实表，记录每笔借据的详细信息及余额变化',
    tags=['fund', 'dwd', 'fact', 'promissory_note', 'loan']
) }}

WITH promissory_note_with_apply AS (
    -- ============================================
    -- 1. 关联借据表和借据申请表
    -- ============================================
    SELECT
        -- 主键
        d.id AS promissory_note_id,                                            -- 借据ID（主键）

        -- 时间信息
        d.create_time,                                                         -- 创建时间
        d.update_time,                                                         -- 更新时间
        CAST(d.update_time AS DATE) AS trx_date,                               -- 更新日期（分区字段）
        d.loan_no AS promissory_note_no,                                       -- 借据编号

        -- 金额信息
        d.loan_quota AS credit_quota,                                          -- 授信额度
        d.loan_balance,                                                        -- 贷款余额
        d.remain_quota,                                                        -- 剩余额度
        d.interest_rate,                                                       -- 利率

        -- 日期信息（标准化格式）
        CASE
            WHEN REGEXP_MATCHES(d.expire_time, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')
            THEN STRPTIME(d.expire_time, '%Y-%m-%d')
            ELSE STRPTIME(d.expire_time, '%Y%m%d')
        END AS promissory_note_end_date,                                      -- 借据止期（标准化）

        d.loan_begin_date AS promissory_note_start_date,                       -- 借据起期

        -- 申请信息
        a.contract_code,                                                       -- 合同编号
        a.apply_quota,                                                         -- 申请额度
        a.serial_no AS promissory_note_sn,                                     -- 借据流水号
        a.entrust_account,                                                     -- 委托账户
        a.apply_free_time,                                                     -- 申请放款时间
        a.store_id,                                                            -- 门店ID
        a.store_name,                                                          -- 门店名称
        a.status AS apply_status,                                              -- 申请状态
        a.dock_type AS connection_type,                                        -- 对接类型

        -- 借据状态
        d.result AS promissory_note_status,                                    -- 借据状态（0=有效，1=无效）
        d.remark,                                                              -- 备注
        d.creator,                                                             -- 创建人

        -- 数据仓库字段
        CURRENT_TIMESTAMP AS dw_insert_time,                                   -- 数据仓库插入时间
        CURRENT_DATE AS dw_insert_date                                         -- 数据仓库插入日期

    FROM {{ ref('ods_fund_debt') }} d
    LEFT JOIN {{ ref('ods_fund_debt_apply') }} a
        ON d.debt_apply_id = a.id

    -- 过滤条件
    WHERE d.result = '0'                                                       -- 仅有效借据
      AND d.loan_quota > 0                                                     -- 贷款额度>0
      AND a.contract_code != 'jk00001'                                         -- 排除测试合同
      AND d.loan_no NOT LIKE 'cs%'                                             -- 排除测试借据（小写）
      AND d.loan_no NOT LIKE 'CS%'                                             -- 排除测试借据（大写）
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    promissory_note_id,                                                       -- 借据ID

    -- 时间信息
    create_time,                                                              -- 创建时间
    update_time,                                                              -- 更新时间
    trx_date,                                                                 -- 更新日期（分区字段）

    -- 借据编号
    promissory_note_no,                                                       -- 借据编号

    -- 金额信息
    credit_quota,                                                             -- 授信额度
    loan_balance,                                                             -- 贷款余额
    remain_quota,                                                             -- 剩余额度
    interest_rate,                                                            -- 利率

    -- 日期信息
    promissory_note_start_date,                                               -- 借据起期
    promissory_note_end_date,                                                 -- 借据止期

    -- 申请信息
    contract_code,                                                            -- 合同编号
    apply_quota,                                                              -- 申请额度
    promissory_note_sn,                                                       -- 借据流水号
    entrust_account,                                                          -- 委托账户
    apply_free_time,                                                          -- 申请放款时间
    store_id,                                                                 -- 门店ID
    store_name,                                                               -- 门店名称
    apply_status,                                                             -- 申请状态
    connection_type,                                                          -- 对接类型

    -- 借据状态
    promissory_note_status,                                                   -- 借据状态（0=有效，1=无效）
    remark,                                                                   -- 备注
    creator,                                                                  -- 创建人

    -- 数据仓库字段
    dw_insert_time,                                                           -- 数据仓库插入时间
    dw_insert_date                                                            -- 数据仓库插入日期

FROM promissory_note_with_apply

-- {% if is_incremental() %}
-- AND CAST(update_time AS DATE) >= (SELECT COALESCE(MAX(trx_date), DATE '2020-01-01') - INTERVAL '7 days' FROM {{ this }})
-- {% endif %}

ORDER BY trx_date DESC, update_time DESC
