-- =============================================
-- 模型名称：dim_ranch_cattle
-- 模型描述：牧场牛只维度表（SCD Type 2）
-- 作者：dbt
-- 创建时间：2026-04-02
-- =============================================
{{ config(
    materialized='table',
    description='牧场牛只维度表，记录牛只的基础属性、入栏信息、贷款信息等相对稳定的维度属性（SCD Type 2）。注意：每日变化的快照数据（如体重、增重、饲养天数等）应使用DWD快照表或DWS汇总表'
) }}

-- 源数据 CTE
WITH src_onstall AS (
    SELECT
        id,
        stall_id,
        code,
        vice_code,
        install_date,
        birth_date,
        CAST(weight AS DOUBLE) AS current_weight,
        CAST(price AS DOUBLE) AS current_price,
        commodity_id AS cattle_sku_id,
        color,
        status,
        investor_id AS customer_id,
        tenant_id AS ranch_id,
        CAST(total_loan_money AS DOUBLE) AS total_loan_amount,
        is_loan,
        out_stall_date,
        last_loan_date,
        is_lock,
        CAST(repay_amount AS DOUBLE) AS repay_amount,
        purchase_id,
        loan_count,
        funding_id,
        if_sick,
        CAST(other1_loan_money AS DOUBLE) AS corn_silage_loan_amount,
        CAST(other2_loan_money AS DOUBLE) AS high_moisture_corn_loan_amount,
        CAST(in_stall_loan_money AS DOUBLE) AS in_stall_loan_amount,
        CAST(weight_add_loan_money AS DOUBLE) AS weight_add_loan_amount,
        create_time,
        update_time,
        create_by,
        update_by
    FROM {{ ref('ods_ranch_onstall') }}
),

-- 获取入栏当天的快照数据（入栏体重、入栏单价）
lkp_install_snapshot AS (
    SELECT
        livestock_id,
        snap_date,
        CAST(estimated_weight AS DOUBLE) AS in_stall_weight,
        CAST(real_price AS DOUBLE) AS in_stall_price
    FROM {{ ref('ods_ranch_onstall_history') }}
    WHERE snap_date IS NOT NULL
),

-- SKU 维度关联
lkp_sku AS (
    SELECT
        sku_id,
        sku_name,
        brand_name
    FROM {{ ref('dim_ranch_sku') }}
    WHERE is_current = '1'
),

-- 栏舍维度关联（包含牧场和配方信息）
lkp_stall AS (
    SELECT
        stall_id,
        stall_name,
        ranch_id,
        ranch_name,
        recipe_id,
        recipe_name,
        recipe_sku_id,
        recipe_sku_name
    FROM {{ ref('dim_ranch_stall') }}
    WHERE is_current = '1'
),

-- 最终整合
cattle_final AS (
    SELECT
        s.id AS cattle_id,
        s.code AS cattle_no,
        s.vice_code,
        s.stall_id,
        st.stall_name,
        st.recipe_id,
        st.recipe_name,
        s.ranch_id,
        st.ranch_name,
        s.install_date AS in_stall_date,
        s.birth_date,
        h.in_stall_weight,                                           -- 来自历史快照的入栏体重
        h.in_stall_price,                                            -- 来自历史快照的入栏单价
        s.cattle_sku_id,
        k.sku_name AS cattle_sku_name,
        k.brand_name,
        s.color,
        s.status AS cattle_status,
        s.customer_id,
        s.total_loan_amount,
        s.is_loan,
        s.out_stall_date,
        s.last_loan_date,
        s.is_lock,
        s.repay_amount,
        s.purchase_id,
        s.loan_count,
        s.funding_id,
        s.if_sick,
        s.corn_silage_loan_amount,                                   -- 青贮玉米贷金额
        s.high_moisture_corn_loan_amount,                            -- 高湿玉米贷金额
        s.in_stall_loan_amount,
        s.weight_add_loan_amount,
        -- 系统字段
        s.create_time,
        s.update_time,
        -- SCD Type 2 字段
        s.update_time AS dw_effective_date,
        CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,
        '1' AS is_current
    FROM src_onstall s
    LEFT JOIN lkp_install_snapshot h ON s.id = h.livestock_id AND DATE(s.install_date) = DATE(h.snap_date)               -- 通过入栏日期关联历史快照
    LEFT JOIN lkp_stall st ON s.stall_id = st.stall_id              -- 通过栏舍维度关联牧场和配方信息
    LEFT JOIN lkp_sku k ON s.cattle_sku_id = k.sku_id
)

-- 最终输出
SELECT
    -- 关键标识
    cattle_id,                          -- 牛只ID
    cattle_no,                          -- 牛只编号
    vice_code,                          -- 副编号
    -- 层级关系：牧场-栏舍-牛只
    ranch_id,                           -- 牧场ID
    ranch_name,                         -- 牧场名称
    stall_id,                           -- 栏舍ID
    stall_name,                         -- 栏舍名称
    -- 配方信息
    recipe_id,                          -- 配方ID
    recipe_name,                        -- 配方名称
    -- 基础属性
    cattle_sku_id,                      -- 牛只SKU ID
    cattle_sku_name,                    -- 牛只SKU 名称
    brand_name,                         -- 品牌名称
    in_stall_date,                      -- 入栏日期
    birth_date,                         -- 出生日期
    in_stall_weight,                    -- 入栏体重（来自历史快照）
    in_stall_price,                     -- 入栏单价（来自历史快照）
    color,                              -- 毛色
    cattle_status,                      -- 牛只状态（0=在栏，其他=出栏）
    out_stall_date,                     -- 出栏日期
    -- 客户信息
    customer_id,                        -- 客户ID
    purchase_id,                        -- 采购ID
    -- 贷款标识
    is_loan,                            -- 是否融资
    loan_count,                         -- 贷款次数
    funding_id,                         -- 资金方ID
    last_loan_date,                     -- 最后贷款日期
    -- 贷款金额
    total_loan_amount,                  -- 总贷款金额
    in_stall_loan_amount,               -- 入栏贷金额
    weight_add_loan_amount,             -- 增重贷金额
    corn_silage_loan_amount,            -- 青贮玉米贷金额
    high_moisture_corn_loan_amount,     -- 高湿玉米贷金额
    repay_amount,                       -- 还款金额
    is_lock,                            -- 是否锁定
    if_sick,                            -- 是否病牛
    -- 系统字段
    create_time,                        -- 创建时间
    update_time,                        -- 更新时间
    -- SCD Type 2 字段
    dw_effective_date,                  -- 生效日期
    dw_expiry_date,                     -- 失效日期
    is_current                          -- 是否当前记录
FROM cattle_final
