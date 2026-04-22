-- =============================================
-- 模型名称：dws_fund_disbursement_agg_df
-- 模型描述：放款日统计表，按日期维度统计放款相关指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date
-- 说明：
--   - 数据源：dwd_fund_online_loan_fact_i（线上放款）+ dwd_fund_offline_loan_fact_i（线下放款）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 统计维度：按统计日期汇总放款指标
--   - 核心指标：放款笔数、放款金额、放款客户数
--   - 整合线上线下放款数据
--   - 用于放款趋势分析、业务监控
--   - 架构设计：替代生产环境多个放款统计任务
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='放款日统计表，按日期维度统计放款相关指标',
    tags=['fund', 'dws', 'agg', 'disbursement', 'daily']
) }}

WITH online_disbursement AS (
    -- ============================================
    -- 线上放款日统计
    -- ============================================
    SELECT
        CAST(trx_date AS DATE) AS stats_date,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS online_loan_cnt,
        SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS online_loan_amt,
        COUNT(DISTINCT CASE WHEN loan_repay_type = '1' THEN customer_id END) AS online_loan_customer_cnt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type = '1'  -- 放款
    GROUP BY CAST(trx_date AS DATE)
),

offline_disbursement AS (
    -- ============================================
    -- 线下放款日统计
    -- ============================================
    SELECT
        CAST(trx_date AS DATE) AS stats_date,
        COUNT(*) AS offline_loan_cnt,
        SUM(loan_amount) AS offline_loan_amt,
        COUNT(DISTINCT customer_id) AS offline_loan_customer_cnt
    FROM {{ ref('dwd_fund_offline_loan_fact_i') }}
    WHERE loan_repay_type = '1'  -- 放款
    GROUP BY CAST(trx_date AS DATE)
),

-- ============================================
-- 合并线上线下放款数据
-- =============================================
all_disbursement AS (
    SELECT
        COALESCE(od.stats_date, offd.stats_date) AS stats_date,
        -- 线上放款
        COALESCE(od.online_loan_cnt, 0) AS online_loan_cnt,
        COALESCE(od.online_loan_amt, 0) AS online_loan_amt,
        COALESCE(od.online_loan_customer_cnt, 0) AS online_loan_customer_cnt,
        -- 线下放款
        COALESCE(offd.offline_loan_cnt, 0) AS offline_loan_cnt,
        COALESCE(offd.offline_loan_amt, 0) AS offline_loan_amt,
        COALESCE(offd.offline_loan_customer_cnt, 0) AS offline_loan_customer_cnt
    FROM online_disbursement od
    FULL OUTER JOIN offline_disbursement offd ON od.stats_date = offd.stats_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 统计维度
    stats_date,                                                             -- 统计日期

    -- 线上放款
    online_loan_cnt,                                                        -- 线上放款笔数
    online_loan_amt,                                                        -- 线上放款金额
    online_loan_customer_cnt,                                               -- 线上放款客户数

    -- 线下放款
    offline_loan_cnt,                                                       -- 线下放款笔数
    offline_loan_amt,                                                       -- 线下放款金额
    offline_loan_customer_cnt,                                              -- 线下放款客户数

    -- 合计放款
    (online_loan_cnt + offline_loan_cnt) AS total_loan_cnt,                 -- 总放款笔数
    (online_loan_amt + offline_loan_amt) AS total_loan_amt,                 -- 总放款金额
    -- 这里需要更复杂的逻辑来计算去重客户数，暂时用总和代替
    (online_loan_customer_cnt + offline_loan_customer_cnt) AS total_loan_customer_cnt,  -- 总放款客户数（未去重）

    -- 平均放款金额
    CASE
        WHEN (online_loan_cnt + offline_loan_cnt) > 0
        THEN ROUND((online_loan_amt + offline_loan_amt) / (online_loan_cnt + offline_loan_cnt), 2)
        ELSE 0
    END AS avg_loan_amt,                                                    -- 平均放款金额

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM all_disbursement
ORDER BY stats_date DESC
