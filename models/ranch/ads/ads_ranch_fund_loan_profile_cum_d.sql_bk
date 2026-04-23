-- =============================================
-- 模型名称：ads_ranch_fund_loan_profile_cum_d
-- 模型描述：牧场资金域贷款画像宽表（至今），按客户聚合贷款余额、用信率、到期分布及逾期指标，增加风险等级
-- Dbt更新方式：全量
-- 粒度：牧场 + 客户（1 牧场 1 企业 1 行）
-- 说明：
--   - 数据源：DWS聚合表、dim_customer_ranch_rel
--   - 增量策略：全量刷新（table），通过 dim_customer_ranch_rel 精确关联，严禁使用 LIKE 模糊匹配
--   - 统计指标：贷款余额、用信率、到期分布、逾期指标、risk_level（风险等级红/黄/绿）
--   - 聚合逻辑：基于逾期率+到期金额+质押率综合判定风险等级
-- =============================================
{{ config(
    materialized='table',
    description='牧场资金域贷款画像宽表（至今），聚合客户的贷款余额、用信率、到期分布及逾期指标，含风险等级标签',
    tags=['ranch', 'ads', 'fund', 'loan', 'profile', 'risk']
) }}

-- ============================================
-- 1. 企业贷款聚合（来自DWS聚合表）
-- ============================================
WITH loan_agg AS (
    SELECT
        customer_id,
        MAX(customer_name) AS customer_name,
        SUM(end_balance) AS outstanding_balance,
        MAX(loan_quota) AS loan_quota,
        AVG(avg_tenor_days) AS avg_tenor_days,
        SUM(overdue_amount) AS overdue_amount,
        SUM(due_7d_amount) AS due_7d_amount,
        SUM(due_30d_amount) AS due_30d_amount,
        MAX(month_end_date) AS latest_statistics_date,
        -- 计算综合用信率和逾期率（跨所有月份取最新）
        CASE WHEN MAX(loan_quota) > 0 THEN SUM(end_balance) / MAX(loan_quota) ELSE NULL END AS utilization_rate,
        CASE WHEN SUM(end_balance) > 0 THEN SUM(overdue_amount) / SUM(end_balance) ELSE NULL END AS overdue_rate
    FROM {{ ref('dws_fund_loan_customer_monthly_agg_mi') }}
    WHERE natural_month = (SELECT MAX(natural_month) FROM {{ ref('dws_fund_loan_customer_monthly_agg_mi') }})  -- 取最新月份
    GROUP BY customer_id
),

-- ============================================
-- 2. 牧场映射（通过客户-牧场映射关系表关联）
-- ============================================
ranch_mapping AS (
    SELECT
        customer_id,
        ranch_id
    FROM {{ ref('dim_customer_ranch_rel') }}
),

-- ============================================
-- 3. 牧场级质押信息（来自资产域DWS）
-- ============================================
cattle_loan_agg AS (
    SELECT
        ranch_id,
        COUNT(DISTINCT cattle_id) AS pledge_cattle_count,
        SUM(CASE WHEN is_loan = '1' THEN 1 ELSE 0 END) AS loan_cattle_count,
        SUM(COALESCE(total_loan_amount, 0)) AS cattle_total_loan,
        SUM(COALESCE(repay_amount, 0)) AS cattle_total_repay,
        CASE WHEN COUNT(*) > 0 THEN SUM(CASE WHEN is_loan = '1' THEN 1 ELSE 0 END) * 1.0 / COUNT(*) ELSE NULL END AS loan_coverage_ratio
    FROM {{ ref('dim_ranch_cattle') }}
    WHERE is_current = '1'
    GROUP BY ranch_id
),

-- ============================================
-- 4. 牧场质押率（来自资产域DWS）
-- ============================================
latest_pledge AS (
    SELECT
        ranch_id,
        pledge_ratio AS latest_pledge_ratio,
        total_estimated_value,
        total_loan_money
    FROM {{ ref('dws_ranch_cattle_balance_agg_di') }}
    WHERE stat_date = (SELECT MAX(stat_date) FROM {{ ref('dws_ranch_cattle_balance_agg_di') }})
),

-- ============================================
-- 5. 映射整合与风险等级计算
-- ============================================
mapped AS (
    SELECT
        a.customer_id,
        a.customer_name,
        rm.ranch_id,
        dr.ranch_name,
        a.outstanding_balance,
        a.loan_quota,
        a.utilization_rate,
        a.avg_tenor_days,
        a.due_7d_amount,
        a.due_30d_amount,
        a.overdue_amount,
        a.overdue_rate,
        a.latest_statistics_date,
        cl.pledge_cattle_count,
        cl.loan_cattle_count,
        cl.loan_coverage_ratio,
        lp.latest_pledge_ratio,
        -- 风险等级判定：红（逾期率>5% OR 质押率>85% OR 7天到期占比>30%）/ 黄（逾期率>0 OR 30天到期占比>50% OR 质押率>75%）/ 绿（其他）
        CASE
            WHEN a.overdue_rate > 0.05 OR COALESCE(lp.latest_pledge_ratio, 0) > 85 OR (CASE WHEN a.outstanding_balance > 0 THEN a.due_7d_amount / a.outstanding_balance ELSE 0 END) > 0.3 THEN 'red'
            WHEN a.overdue_rate > 0 OR COALESCE(lp.latest_pledge_ratio, 0) > 75 OR (CASE WHEN a.outstanding_balance > 0 THEN a.due_30d_amount / a.outstanding_balance ELSE 0 END) > 0.5 THEN 'yellow'
            ELSE 'green'
        END AS risk_level
    FROM loan_agg a
    LEFT JOIN ranch_mapping rm ON a.customer_id = rm.customer_id
    LEFT JOIN {{ ref('dim_ranch') }} dr ON rm.ranch_id = dr.ranch_id
    LEFT JOIN cattle_loan_agg cl ON rm.ranch_id = cl.ranch_id
    LEFT JOIN latest_pledge lp ON rm.ranch_id = lp.ranch_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    customer_id,                                              -- 客户ID
    customer_name,                                            -- 客户名称
    ranch_id,                                                 -- 映射牧场ID（可能为NULL）
    ranch_name,                                               -- 映射牧场名称

    -- 贷款规模
    ROUND(outstanding_balance, 2) AS outstanding_balance,      -- 当前贷款余额
    ROUND(loan_quota, 2) AS loan_quota,                        -- 授信额度
    ROUND(utilization_rate * 100, 2) AS utilization_rate,      -- 用信率(%)
    ROUND(avg_tenor_days, 1) AS avg_tenor_days,                -- 平均周转天数

    -- 到期分布
    ROUND(due_7d_amount, 2) AS due_7d_amount,                  -- 7天内到期金额
    ROUND(due_30d_amount, 2) AS due_30d_amount,                -- 30天内到期金额

    -- 逾期风险
    ROUND(overdue_amount, 2) AS overdue_amount,                -- 逾期金额
    ROUND(overdue_rate * 100, 2) AS overdue_rate,              -- 逾期率(%)
    risk_level,                              -- 风险等级（red/yellow/green）

    -- 牧场质押（仅映射成功时有值）
    pledge_cattle_count,                     -- 在栏牛只总数
    loan_cattle_count,                       -- 有贷款牛只数
    ROUND(loan_coverage_ratio * 100, 2) AS loan_coverage_ratio, -- 融资覆盖率(%)
    latest_pledge_ratio,                     -- 牧场质押率(%)

    -- 元数据
    latest_statistics_date,                  -- 最新统计日期
    CURRENT_TIMESTAMP AS dw_update_time      -- 数据仓库更新时间

FROM mapped
ORDER BY
    CASE risk_level WHEN 'red' THEN 1 WHEN 'yellow' THEN 2 ELSE 3 END,
    outstanding_balance DESC,
    customer_id
