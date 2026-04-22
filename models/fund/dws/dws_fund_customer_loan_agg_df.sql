-- =============================================
-- 模型名称：dws_fund_customer_loan_agg_df
-- 模型描述：客户贷款汇总聚合表，从snap+DWD交易事实聚合计算，包含当日汇总、余额变动、累计指标
-- Dbt更新方式：全量（按日期全量刷新，保留历史数据）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dws_fund_customer_loan_snap_df（期末余额快照）+ dwd_fund_online_loan_fact_i（交易事实）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 当日汇总：从DWD交易事实按客户和日期汇总当日放款、还款
--   - 期末余额：从snap表获取每日贷款余额快照
--   - 累计指标：使用窗口函数计算累计放款、累计还款
--   - 变动指标：计算余额变动、环比增长率等
--   - 比率指标：用信率、月度增长率等
--   - 用于客户贷款分析、风险评估、业务报表
--   - 架构设计：三层架构的第三层（agg层），提供聚合分析指标
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户贷款汇总聚合表，从snap+DWD交易事实聚合计算，包含当日汇总、余额变动、累计指标',
    tags=['fund', 'dws', 'agg', 'customer', 'loan']
) }}

WITH daily_transaction AS (
    -- ============================================
    -- 1. 按客户和日期汇总当日交易（从DWD交易事实）
    -- ============================================
    SELECT
        customer_id,
        CAST(trx_date AS DATE) AS stats_date,
        -- 当日放款
        SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS daily_loan_amt,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS daily_loan_cnt,
        -- 当日还款
        SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS daily_repay_amt,
        SUM(CASE WHEN loan_repay_type = '2' THEN repay_interest_amount ELSE 0 END) AS daily_repay_interest_amt,
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS daily_repay_cnt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type IN ('1', '2')  -- 放款和还款
    GROUP BY customer_id, CAST(trx_date AS DATE)
),

snap_data AS (
    -- ============================================
    -- 2. 获取期末余额快照（来自snap表）
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        total_credit_quota,                                                     -- 总授信额度
        total_remain_quota,                                                     -- 总剩余额度
        total_credit_used_quota,                                                -- 总授信已用额度
        total_loan_balance,                                                     -- 总贷款余额
        outstanding_promissory_note_cnt,                                        -- 在贷笔数
        credit_utilization_rate                                                 -- 用信率（%）
    FROM {{ ref('dws_fund_customer_loan_snap_df') }}
),

-- ============================================
-- 3. 合并 snap 和交易数据
-- ============================================
all_customer_daily AS (
    SELECT
        COALESCE(sd.customer_id, dt.customer_id) AS customer_id,
        COALESCE(sd.stats_date, dt.stats_date) AS stats_date,

        -- 期末余额（来自snap）
        COALESCE(sd.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(sd.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(sd.total_credit_used_quota, 0) AS total_credit_used_quota,
        COALESCE(sd.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(sd.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt,
        COALESCE(sd.credit_utilization_rate, 0) AS credit_utilization_rate,

        -- 当日交易（来自DWD）
        COALESCE(dt.daily_loan_amt, 0) AS daily_loan_amt,
        COALESCE(dt.daily_loan_cnt, 0) AS daily_loan_cnt,
        COALESCE(dt.daily_repay_amt, 0) AS daily_repay_amt,
        COALESCE(dt.daily_repay_interest_amt, 0) AS daily_repay_interest_amt,
        COALESCE(dt.daily_repay_cnt, 0) AS daily_repay_cnt

    FROM snap_data sd
    FULL OUTER JOIN daily_transaction dt
        ON sd.customer_id = dt.customer_id AND sd.stats_date = dt.stats_date
),

-- ============================================
-- 4. 计算累计指标和变动指标（使用窗口函数）
-- ============================================
customer_cumulative AS (
    SELECT
        customer_id,
        stats_date,
        -- 累计放款金额（从第一天开始累计）
        SUM(daily_loan_amt) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_loan_amt,
        -- 累计还款金额（从第一天开始累计）
        SUM(daily_repay_amt) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_repay_amt,
        -- 年累计放款
        SUM(daily_loan_amt) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS year_cumulative_loan_amt,
        -- 年累计还款
        SUM(daily_repay_amt) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS year_cumulative_repay_amt,
        -- 月累计放款
        SUM(daily_loan_amt) OVER (PARTITION BY customer_id, DATE_TRUNC('month', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS month_cumulative_loan_amt,
        -- 月累计还款
        SUM(daily_repay_amt) OVER (PARTITION BY customer_id, DATE_TRUNC('month', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS month_cumulative_repay_amt,
        -- 昨日余额（前一行的余额）
        LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date) AS prev_loan_balance,
        -- 当日余额变动
        total_loan_balance - LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date) AS daily_balance_change,
        -- 月初余额（当月第一天的余额）
        FIRST_VALUE(total_loan_balance) OVER (PARTITION BY customer_id, DATE_TRUNC('month', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS month_start_loan_balance,
        -- 上月末余额（前一个月最后一天的余额）
        LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY DATE_TRUNC('month', stats_date), stats_date) AS month_end_loan_balance
    FROM all_customer_daily
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    acd.customer_id,                                                       -- 客户ID
    acd.stats_date,                                                        -- 统计日期

    -- 授信额度信息
    acd.total_credit_quota,                                                -- 总授信额度
    acd.total_remain_quota,                                                -- 总剩余额度
    acd.total_credit_used_quota,                                           -- 总授信已用额度

    -- 贷款余额
    acd.total_loan_balance,                                                -- 总贷款余额
    acd.outstanding_promissory_note_cnt,                                   -- 在贷笔数

    -- 当日放款
    acd.daily_loan_amt,                                                    -- 当日放款金额
    acd.daily_loan_cnt,                                                    -- 当日放款笔数

    -- 当日还款
    acd.daily_repay_amt,                                                   -- 当日还款金额
    acd.daily_repay_interest_amt,                                          -- 当日还款利息
    acd.daily_repay_cnt,                                                   -- 当日还款笔数

    -- 比率指标
    acd.credit_utilization_rate,                                           -- 用信率（%）

    -- 累计指标
    cc.cumulative_loan_amt,                                                -- 累计放款金额
    cc.cumulative_repay_amt,                                               -- 累计还款金额
    cc.year_cumulative_loan_amt,                                           -- 年累计放款金额
    cc.year_cumulative_repay_amt,                                          -- 年累计还款金额
    cc.month_cumulative_loan_amt,                                          -- 月累计放款金额
    cc.month_cumulative_repay_amt,                                         -- 月累计还款金额

    -- 余额变动指标
    cc.prev_loan_balance,                                                  -- 昨日贷款余额
    cc.daily_balance_change,                                               -- 当日余额变动
    cc.month_start_loan_balance,                                           -- 月初贷款余额
    cc.month_end_loan_balance,                                             -- 上月末贷款余额

    -- 月度增长率
    CASE
        WHEN cc.month_end_loan_balance > 0
        THEN ROUND(((acd.total_loan_balance - cc.month_end_loan_balance) / cc.month_end_loan_balance) * 100, 2)
        WHEN acd.total_loan_balance > 0 AND cc.month_end_loan_balance = 0
        THEN 100  -- 从0到有余额，视为100%增长
        ELSE 0
    END AS month_loan_growth_rate,                                         -- 月度贷款增长率（%）

    -- 标识字段
    CASE WHEN acd.total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户
    CASE WHEN acd.daily_loan_amt > 0 OR acd.daily_repay_amt > 0 THEN '1' ELSE '0' END AS has_daily_transaction,  -- 是否有当日交易

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM all_customer_daily acd
LEFT JOIN customer_cumulative cc
    ON acd.customer_id = cc.customer_id AND acd.stats_date = cc.stats_date

WHERE acd.total_credit_quota > 0 OR acd.total_loan_balance > 0 OR acd.daily_loan_amt > 0 OR acd.daily_repay_amt > 0  -- 只保留有活动的客户
ORDER BY acd.customer_id, acd.stats_date DESC
