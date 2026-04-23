-- =============================================
-- 模型名称：ads_fund_customer_metrics_agg_df
-- 模型描述：客户资金每日指标汇总表，按客户+日期粒度整合授信、余额、放还款、逾期、到期、周转率等核心资金指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dws_fund_customer_loan_balance_agg_df、dws_fund_customer_loan_repay_agg_df、
--            dws_fund_customer_credit_agg_df、dws_fund_customer_promissory_note_agg_df
--   - 核心指标：贷款余额、授信额度、放还款、净增额、逾期/到期预警、周转率、日均、累计
--   - 趋势指标：日增长率、周增长率、7日/30日均值
--   - 产品拆分：银承授信/余额独立统计
--   - 本模型不带客户属性维度（场景、机构等），在 ads_rpt 层关联 dim_customer_unify 补充
--   - 命名参考：glossary/术语库.csv
-- =============================================
{{ config(
    materialized='table',
    description='客户资金每日指标汇总表，按客户+日期粒度整合授信、余额、放还款、逾期、到期、周转率等核心资金指标',
    tags=['fund', 'ads', 'customer', 'daily', 'metrics', 'disbursement', 'repay', 'balance']
) }}

WITH base_balance AS (
    -- ============================================
    -- 基础余额与授信指标（来自贷款余额日聚合）
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        total_credit_quota,
        total_remain_quota,
        total_credit_used_quota,
        total_loan_balance,
        online_loan_balance,
        offline_loan_balance,
        online_promissory_note_cnt,
        online_overdue_balance,
        online_overdue_cnt,
        online_due_7d_balance,
        online_due_30d_balance,
        prev_total_loan_balance,
        daily_balance_change,
        total_offline_cumulative_disbursement,
        total_offline_cumulative_repay,
        year_offline_cumulative_disbursement,
        year_offline_cumulative_repay,
        utilization_rate,
        overdue_rate,
        is_loan_customer,
        has_online_loan,
        has_offline_loan
    FROM {{ ref('dws_fund_customer_loan_balance_agg_df') }}
),

daily_repay AS (
    -- ============================================
    -- 每日放还款指标（来自放还款日统计，按客户+日期聚合）
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        SUM(online_loan_amt) AS online_disbursement_amount,
        SUM(online_loan_cnt) AS online_disbursement_count,
        SUM(online_repay_amt) AS online_repay_amount,
        SUM(online_repay_cnt) AS online_repay_count,
        SUM(online_repay_interest_amt) AS online_repay_interest_amount,
        SUM(offline_loan_amt) AS offline_disbursement_amount,
        SUM(offline_loan_cnt) AS offline_disbursement_count,
        SUM(offline_repay_amt) AS offline_repay_amount,
        SUM(offline_repay_cnt) AS offline_repay_count,
        SUM(total_loan_amt) AS total_disbursement_amount,
        SUM(total_loan_cnt) AS total_disbursement_count,
        SUM(total_repay_amt) AS total_repay_amount,
        SUM(total_repay_cnt) AS total_repay_count,
        SUM(total_repay_interest_amt) AS total_repay_interest_amount,
        SUM(net_loan_amt) AS net_increase,
        MAX(has_loan) AS has_daily_loan,
        MAX(has_repay) AS has_daily_repay
    FROM {{ ref('dws_fund_customer_loan_repay_agg_df') }}
    GROUP BY customer_id, stats_date
),

credit_split AS (
    -- ============================================
    -- 授信产品拆分（来自授信明细日统计，按客户+日期聚合）
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        SUM(CASE WHEN is_bank_acceptance = '1' THEN credit_quota ELSE 0 END) AS bank_accept_credit_limit,
        SUM(CASE WHEN is_bank_acceptance = '1' THEN remain_quota ELSE 0 END) AS bank_accept_remain_credit,
        SUM(CASE WHEN is_bank_acceptance = '1' THEN credit_used_quota ELSE 0 END) AS bank_accept_used_credit,
        SUM(CASE WHEN is_steel_trade_acceptance = '1' THEN credit_quota ELSE 0 END) AS steel_trade_accept_credit_limit
    FROM {{ ref('dws_fund_customer_credit_agg_df') }}
    GROUP BY customer_id, stats_date
),

note_agg AS (
    -- ============================================
    -- 借据级预警汇总（来自借据日明细宽表，按客户+日期聚合）
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        COUNT(CASE WHEN is_overdue = '1' AND has_balance = '1' THEN 1 END) AS overdue_count,
        COUNT(CASE WHEN is_due_within_7d = '1' AND has_balance = '1' THEN 1 END) AS due_in_7_days_count,
        COUNT(CASE WHEN is_due_within_30d = '1' AND has_balance = '1' THEN 1 END) AS due_in_30_days_count,
        COUNT(CASE WHEN promissory_note_end_date >= stats_date AND promissory_note_end_date <= stats_date + INTERVAL '90 days' AND has_balance = '1' THEN 1 END) AS due_in_90_days_count,
        SUM(CASE WHEN is_overdue = '1' AND has_balance = '1' THEN loan_balance ELSE 0 END) AS overdue_balance,
        SUM(CASE WHEN is_due_within_7d = '1' AND has_balance = '1' THEN loan_balance ELSE 0 END) AS due_in_7_days_balance,
        SUM(CASE WHEN is_due_within_30d = '1' AND has_balance = '1' THEN loan_balance ELSE 0 END) AS due_in_30_days_balance,
        SUM(CASE WHEN promissory_note_end_date >= stats_date AND promissory_note_end_date <= stats_date + INTERVAL '90 days' AND has_balance = '1' THEN loan_balance ELSE 0 END) AS due_in_90_days_balance,
        COUNT(CASE WHEN has_balance = '1' THEN 1 END) AS outstanding_promissory_note_count,
        SUM(CASE WHEN financial_product_id = 73 AND has_balance = '1' THEN loan_balance ELSE 0 END) AS bank_accept_loan_balance,
        AVG(CASE WHEN has_balance = '1' THEN interest_rate END) AS avg_interest_rate
    FROM {{ ref('dws_fund_customer_promissory_note_agg_df') }}
    GROUP BY customer_id, stats_date
),

merged AS (
    -- ============================================
    -- 合并所有基础指标
    -- ============================================
    SELECT
        COALESCE(bb.customer_id, dr.customer_id, cs.customer_id, na.customer_id) AS customer_id,
        COALESCE(bb.stats_date, dr.stats_date, cs.stats_date, na.stats_date) AS stats_date,

        -- 授信额度
        COALESCE(bb.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(bb.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(bb.total_credit_used_quota, 0) AS total_used_credit,

        -- 贷款余额
        COALESCE(bb.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(bb.online_loan_balance, 0) AS online_loan_balance,
        COALESCE(bb.offline_loan_balance, 0) AS offline_loan_balance,

        -- 线上在贷笔数（来自余额表）
        COALESCE(bb.online_promissory_note_cnt, 0) AS online_promissory_note_cnt,

        -- 逾期（来自余额表）
        COALESCE(bb.online_overdue_balance, 0) AS online_overdue_balance,
        COALESCE(bb.online_overdue_cnt, 0) AS online_overdue_cnt,
        COALESCE(bb.online_due_7d_balance, 0) AS online_due_7d_balance,
        COALESCE(bb.online_due_30d_balance, 0) AS online_due_30d_balance,

        -- 昨日余额与变动
        bb.prev_total_loan_balance,
        COALESCE(bb.daily_balance_change, 0) AS daily_balance_change,

        -- 线下累计
        COALESCE(bb.total_offline_cumulative_disbursement, 0) AS total_offline_cumulative_disbursement,
        COALESCE(bb.total_offline_cumulative_repay, 0) AS total_offline_cumulative_repay,
        COALESCE(bb.year_offline_cumulative_disbursement, 0) AS year_offline_cumulative_disbursement,
        COALESCE(bb.year_offline_cumulative_repay, 0) AS year_offline_cumulative_repay,

        -- 用信率、逾期率
        bb.utilization_rate,
        bb.overdue_rate,

        -- 标识
        bb.is_loan_customer,
        bb.has_online_loan,
        bb.has_offline_loan,

        -- 放款
        COALESCE(dr.online_disbursement_amount, 0) AS online_disbursement_amount,
        COALESCE(dr.online_disbursement_count, 0) AS online_disbursement_count,
        COALESCE(dr.offline_disbursement_amount, 0) AS offline_disbursement_amount,
        COALESCE(dr.offline_disbursement_count, 0) AS offline_disbursement_count,
        COALESCE(dr.total_disbursement_amount, 0) AS total_disbursement_amount,
        COALESCE(dr.total_disbursement_count, 0) AS total_disbursement_count,

        -- 还款
        COALESCE(dr.online_repay_amount, 0) AS online_repay_amount,
        COALESCE(dr.online_repay_count, 0) AS online_repay_count,
        COALESCE(dr.online_repay_interest_amount, 0) AS online_repay_interest_amount,
        COALESCE(dr.offline_repay_amount, 0) AS offline_repay_amount,
        COALESCE(dr.offline_repay_count, 0) AS offline_repay_count,
        COALESCE(dr.total_repay_amount, 0) AS total_repay_amount,
        COALESCE(dr.total_repay_count, 0) AS total_repay_count,
        COALESCE(dr.total_repay_interest_amount, 0) AS total_repay_interest_amount,

        -- 净增额
        COALESCE(dr.net_increase, 0) AS net_increase,

        -- 当日交易标识
        dr.has_daily_loan,
        dr.has_daily_repay,

        -- 授信产品拆分
        COALESCE(cs.bank_accept_credit_limit, 0) AS bank_accept_credit_limit,
        COALESCE(cs.bank_accept_remain_credit, 0) AS bank_accept_remain_credit,
        COALESCE(cs.bank_accept_used_credit, 0) AS bank_accept_used_credit,
        COALESCE(cs.steel_trade_accept_credit_limit, 0) AS steel_trade_accept_credit_limit,

        -- 借据级预警
        COALESCE(na.overdue_count, 0) AS overdue_count,
        COALESCE(na.due_in_7_days_count, 0) AS due_in_7_days_count,
        COALESCE(na.due_in_30_days_count, 0) AS due_in_30_days_count,
        COALESCE(na.due_in_90_days_count, 0) AS due_in_90_days_count,
        COALESCE(na.overdue_balance, 0) AS overdue_balance,
        COALESCE(na.due_in_7_days_balance, 0) AS due_in_7_days_balance,
        COALESCE(na.due_in_30_days_balance, 0) AS due_in_30_days_balance,
        COALESCE(na.due_in_90_days_balance, 0) AS due_in_90_days_balance,
        COALESCE(na.outstanding_promissory_note_count, 0) AS outstanding_promissory_note_count,
        COALESCE(na.bank_accept_loan_balance, 0) AS bank_accept_loan_balance,
        na.avg_interest_rate

    FROM base_balance bb
    FULL OUTER JOIN daily_repay dr ON bb.customer_id = dr.customer_id AND bb.stats_date = dr.stats_date
    FULL OUTER JOIN credit_split cs ON COALESCE(bb.customer_id, dr.customer_id) = cs.customer_id AND COALESCE(bb.stats_date, dr.stats_date) = cs.stats_date
    FULL OUTER JOIN note_agg na ON COALESCE(bb.customer_id, dr.customer_id, cs.customer_id) = na.customer_id AND COALESCE(bb.stats_date, dr.stats_date, cs.stats_date) = na.stats_date
),

window_calc AS (
    -- ============================================
    -- 窗口计算：累计、日均、增长率、周转率
    -- ============================================
    SELECT
        *,

        -- 线上累计放款/还款（全生命周期）
        SUM(online_disbursement_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_cumulative_online_disbursement_amount,
        SUM(online_repay_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_cumulative_online_repay_amount,

        -- 线上累计放款/还款（本年度）
        SUM(online_disbursement_amount) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytd_online_disbursement_amount,
        SUM(online_repay_amount) OVER (PARTITION BY customer_id, DATE_TRUNC('year', stats_date) ORDER BY stats_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS ytd_online_repay_amount,

        -- 7日/30日日均贷款余额
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS avg_daily_loan_balance_7d,
        AVG(online_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS avg_daily_online_loan_balance_7d,
        AVG(offline_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS avg_daily_offline_loan_balance_7d,
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS avg_daily_loan_balance_30d,
        AVG(online_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS avg_daily_online_loan_balance_30d,
        AVG(offline_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS avg_daily_offline_loan_balance_30d,

        -- 周同比贷款余额
        LAG(total_loan_balance, 7) OVER (PARTITION BY customer_id ORDER BY stats_date) AS week_ago_loan_balance,

        -- 30/60/90/120/180/360天周转率计算窗口
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS avg_loan_balance_30d,
        SUM(total_repay_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS sum_repay_30d,
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 59 PRECEDING AND CURRENT ROW) AS avg_loan_balance_60d,
        SUM(total_repay_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 59 PRECEDING AND CURRENT ROW) AS sum_repay_60d,
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) AS avg_loan_balance_90d,
        SUM(total_repay_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 89 PRECEDING AND CURRENT ROW) AS sum_repay_90d,
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 119 PRECEDING AND CURRENT ROW) AS avg_loan_balance_120d,
        SUM(total_repay_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 119 PRECEDING AND CURRENT ROW) AS sum_repay_120d,
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 179 PRECEDING AND CURRENT ROW) AS avg_loan_balance_180d,
        SUM(total_repay_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 179 PRECEDING AND CURRENT ROW) AS sum_repay_180d,
        AVG(total_loan_balance) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 359 PRECEDING AND CURRENT ROW) AS avg_loan_balance_360d,
        SUM(total_repay_amount) OVER (PARTITION BY customer_id ORDER BY stats_date ROWS BETWEEN 359 PRECEDING AND CURRENT ROW) AS sum_repay_360d

    FROM merged
),

turnover_calc AS (
    -- ============================================
    -- 周转率与趋势指标计算
    -- ============================================
    SELECT
        *,

        -- 日增长率
        CASE WHEN prev_total_loan_balance > 0 THEN ROUND((total_loan_balance - prev_total_loan_balance) / prev_total_loan_balance * 100, 2) WHEN prev_total_loan_balance = 0 AND total_loan_balance > 0 THEN 100.00 ELSE 0.00 END AS day_growth_rate,

        -- 周增长率
        CASE WHEN week_ago_loan_balance > 0 THEN ROUND((total_loan_balance - week_ago_loan_balance) / week_ago_loan_balance * 100, 2) WHEN week_ago_loan_balance = 0 AND total_loan_balance > 0 THEN 100.00 ELSE 0.00 END AS week_growth_rate,

        -- 总累计放款/还款（线上+线下）
        total_offline_cumulative_disbursement + total_cumulative_online_disbursement_amount AS total_cumulative_disbursement_amount,
        total_offline_cumulative_repay + total_cumulative_online_repay_amount AS total_cumulative_repay_amount,
        year_offline_cumulative_disbursement + ytd_online_disbursement_amount AS ytd_disbursement_amount,
        year_offline_cumulative_repay + ytd_online_repay_amount AS yearly_cumulative_repay_amount,

        -- 资金周转率（还款金额 / 日均贷款余额）
        CASE WHEN avg_loan_balance_30d > 0 THEN ROUND(sum_repay_30d / avg_loan_balance_30d * 100, 2) ELSE 0 END AS fund_turnover_rate_30d,
        CASE WHEN avg_loan_balance_60d > 0 THEN ROUND(sum_repay_60d / avg_loan_balance_60d * 100, 2) ELSE 0 END AS fund_turnover_rate_60d,
        CASE WHEN avg_loan_balance_90d > 0 THEN ROUND(sum_repay_90d / avg_loan_balance_90d * 100, 2) ELSE 0 END AS fund_turnover_rate_90d,
        CASE WHEN avg_loan_balance_120d > 0 THEN ROUND(sum_repay_120d / avg_loan_balance_120d * 100, 2) ELSE 0 END AS fund_turnover_rate_120d,
        CASE WHEN avg_loan_balance_180d > 0 THEN ROUND(sum_repay_180d / avg_loan_balance_180d * 100, 2) ELSE 0 END AS fund_turnover_rate_180d,
        CASE WHEN avg_loan_balance_360d > 0 THEN ROUND(sum_repay_360d / avg_loan_balance_360d * 100, 2) ELSE 0 END AS fund_turnover_rate_360d

    FROM window_calc
),

turnover_flag AS (
    -- ============================================
    -- 周转率阈值标记（用于计算连续天数）
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        CASE WHEN fund_turnover_rate_30d > 100 THEN '1' ELSE '0' END AS flag_30d,
        CASE WHEN fund_turnover_rate_60d > 100 THEN '1' ELSE '0' END AS flag_60d,
        CASE WHEN fund_turnover_rate_90d > 100 THEN '1' ELSE '0' END AS flag_90d,
        CASE WHEN fund_turnover_rate_120d > 100 THEN '1' ELSE '0' END AS flag_120d,
        CASE WHEN fund_turnover_rate_180d > 100 THEN '1' ELSE '0' END AS flag_180d,
        CASE WHEN fund_turnover_rate_360d > 100 THEN '1' ELSE '0' END AS flag_360d
    FROM turnover_calc
),

turnover_grouped AS (
    SELECT
        customer_id,
        stats_date,
        flag_30d,
        flag_60d,
        flag_90d,
        flag_120d,
        flag_180d,
        flag_360d,
        SUM(CASE WHEN flag_30d = '0' THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id ORDER BY stats_date) AS grp_30d,
        SUM(CASE WHEN flag_60d = '0' THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id ORDER BY stats_date) AS grp_60d,
        SUM(CASE WHEN flag_90d = '0' THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id ORDER BY stats_date) AS grp_90d,
        SUM(CASE WHEN flag_120d = '0' THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id ORDER BY stats_date) AS grp_120d,
        SUM(CASE WHEN flag_180d = '0' THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id ORDER BY stats_date) AS grp_180d,
        SUM(CASE WHEN flag_360d = '0' THEN 1 ELSE 0 END) OVER (PARTITION BY customer_id ORDER BY stats_date) AS grp_360d
    FROM turnover_flag
),

turnover_continuous AS (
    SELECT
        customer_id,
        stats_date,
        CASE WHEN flag_30d = '1' THEN ROW_NUMBER() OVER (PARTITION BY customer_id, grp_30d ORDER BY stats_date) ELSE 0 END AS turnover_ratio_continuous_days_30d,
        CASE WHEN flag_60d = '1' THEN ROW_NUMBER() OVER (PARTITION BY customer_id, grp_60d ORDER BY stats_date) ELSE 0 END AS turnover_ratio_continuous_days_60d,
        CASE WHEN flag_90d = '1' THEN ROW_NUMBER() OVER (PARTITION BY customer_id, grp_90d ORDER BY stats_date) ELSE 0 END AS turnover_ratio_continuous_days_90d,
        CASE WHEN flag_120d = '1' THEN ROW_NUMBER() OVER (PARTITION BY customer_id, grp_120d ORDER BY stats_date) ELSE 0 END AS turnover_ratio_continuous_days_120d,
        CASE WHEN flag_180d = '1' THEN ROW_NUMBER() OVER (PARTITION BY customer_id, grp_180d ORDER BY stats_date) ELSE 0 END AS turnover_ratio_continuous_days_180d,
        CASE WHEN flag_360d = '1' THEN ROW_NUMBER() OVER (PARTITION BY customer_id, grp_360d ORDER BY stats_date) ELSE 0 END AS turnover_ratio_continuous_days_360d
    FROM turnover_grouped
),

final AS (
    -- ============================================
    -- 合并周转率连续天数到主表
    -- ============================================
    SELECT
        tc.*,
        tcd.turnover_ratio_continuous_days_30d,
        tcd.turnover_ratio_continuous_days_60d,
        tcd.turnover_ratio_continuous_days_90d,
        tcd.turnover_ratio_continuous_days_120d,
        tcd.turnover_ratio_continuous_days_180d,
        tcd.turnover_ratio_continuous_days_360d
    FROM turnover_calc tc
    LEFT JOIN turnover_continuous tcd ON tc.customer_id = tcd.customer_id AND tc.stats_date = tcd.stats_date
)

-- =============================================
-- 最终 SELECT
-- =============================================
SELECT
    -- 维度
    customer_id,                                                    -- 客户ID
    stats_date,                                                     -- 统计日期

    -- 授信额度指标
    total_credit_quota,                                             -- 总授信额度
    total_remain_quota,                                             -- 总剩余额度
    total_used_credit,                                              -- 总已用额度

    -- 贷款余额指标
    total_loan_balance,                                             -- 总贷款余额
    online_loan_balance,                                            -- 线上贷款余额
    offline_loan_balance,                                           -- 线下贷款余额
    outstanding_promissory_note_count,                              -- 在贷笔数

    -- 放款指标（当日）
    online_disbursement_amount,                                     -- 线上放款金额
    online_disbursement_count,                                      -- 线上放款笔数
    offline_disbursement_amount,                                    -- 线下放款金额
    offline_disbursement_count,                                     -- 线下放款笔数
    total_disbursement_amount,                                      -- 总放款金额
    total_disbursement_count,                                       -- 总放款笔数

    -- 还款指标（当日）
    online_repay_amount,                                            -- 线上还款金额
    online_repay_count,                                             -- 线上还款笔数
    online_repay_interest_amount,                                   -- 线上还款利息
    offline_repay_amount,                                           -- 线下还款金额
    offline_repay_count,                                            -- 线下还款笔数
    total_repay_amount,                                             -- 总还款金额
    total_repay_count,                                              -- 总还款笔数
    total_repay_interest_amount,                                    -- 总还款利息

    -- 净增额
    net_increase,                                                   -- 净增额

    -- 累计指标
    total_cumulative_disbursement_amount,                           -- 总累计放款金额
    total_cumulative_repay_amount,                                  -- 总累计还款金额
    ytd_disbursement_amount,                                        -- 本年累计放款金额
    yearly_cumulative_repay_amount,                                 -- 本年累计还款金额

    -- 逾期指标
    overdue_balance,                                                -- 逾期金额
    overdue_count,                                                  -- 逾期笔数
    overdue_rate,                                                   -- 逾期率（%）

    -- 到期预警指标
    due_in_7_days_balance,                                          -- 7天内到期余额
    due_in_30_days_balance,                                         -- 30天内到期余额
    due_in_90_days_balance,                                         -- 90天内到期余额
    due_in_7_days_count,                                            -- 7天内到期笔数
    due_in_30_days_count,                                           -- 30天内到期笔数
    due_in_90_days_count,                                           -- 90天内到期笔数

    -- 银承指标
    bank_accept_credit_limit,                                       -- 银承授信额度
    bank_accept_remain_credit,                                      -- 银承可用额度
    bank_accept_used_credit,                                        -- 银承已用额度
    bank_accept_loan_balance,                                       -- 银承贷款余额
    steel_trade_accept_credit_limit,                                -- 钢贸银承授信额度

    -- 用信率
    utilization_rate,                                               -- 用信率（%）

    -- 趋势指标
    prev_total_loan_balance AS prev_loan_balance,                   -- 昨日贷款余额
    daily_balance_change,                                           -- 当日余额变动
    day_growth_rate,                                                -- 日增长率（%）
    week_ago_loan_balance,                                          -- 上周贷款余额
    week_growth_rate,                                               -- 周增长率（%）

    -- 周转率指标
    fund_turnover_rate_30d,                                         -- 30天资金周转率（%）
    fund_turnover_rate_60d,                                         -- 60天资金周转率（%）
    fund_turnover_rate_90d,                                         -- 90天资金周转率（%）
    fund_turnover_rate_120d,                                        -- 120天资金周转率（%）
    fund_turnover_rate_180d,                                        -- 180天资金周转率（%）
    fund_turnover_rate_360d,                                        -- 360天资金周转率（%）

    -- 周转率连续天数
    turnover_ratio_continuous_days_30d,                             -- 30天周转率连续天数
    turnover_ratio_continuous_days_60d,                             -- 60天周转率连续天数
    turnover_ratio_continuous_days_90d,                             -- 90天周转率连续天数
    turnover_ratio_continuous_days_120d,                            -- 120天周转率连续天数
    turnover_ratio_continuous_days_180d,                            -- 180天周转率连续天数
    turnover_ratio_continuous_days_360d,                            -- 360天周转率连续天数

    -- 日均指标
    avg_daily_loan_balance_7d,                                      -- 7日均贷款余额
    avg_daily_online_loan_balance_7d,                               -- 7日均线上贷款余额
    avg_daily_offline_loan_balance_7d,                              -- 7日均线下贷款余额
    avg_daily_loan_balance_30d,                                     -- 30日均贷款余额
    avg_daily_online_loan_balance_30d,                              -- 30日均线上贷款余额
    avg_daily_offline_loan_balance_30d,                             -- 30日均线下贷款余额

    -- 利率
    avg_interest_rate,                                              -- 平均利率

    -- 标识字段
    is_loan_customer,                                               -- 是否贷款客户
    has_online_loan,                                                -- 是否有线上贷款
    has_offline_loan,                                               -- 是否有线下贷款
    CASE WHEN total_disbursement_amount > 0 OR total_repay_amount > 0 THEN '1' ELSE '0' END AS has_daily_transaction,
    CASE WHEN overdue_count > 0 THEN '1' ELSE '0' END AS is_overdue_customer,
    CASE WHEN due_in_7_days_count > 0 OR due_in_30_days_count > 0 THEN '1' ELSE '0' END AS is_due_soon_customer,

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                             -- 数据仓库更新时间

FROM final
WHERE total_credit_quota > 0
   OR total_loan_balance > 0
   OR total_disbursement_amount > 0
   OR total_repay_amount > 0
   OR online_loan_balance > 0
   OR offline_loan_balance > 0
ORDER BY stats_date DESC, customer_id
