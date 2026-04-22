-- =============================================
-- 模型名称：dws_fund_loan_balance_agg_df
-- 模型描述：贷款余额日统计表，按日期维度统计贷款余额相关指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：stats_date
-- 说明：
--   - 数据源：dwd_fund_promissory_note_fact_i（借据事实表）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 统计维度：按统计日期汇总余额指标
--   - 核心指标：总余额、在贷笔数、逾期金额、逾期笔数、到期预警
--   - 统一"贷款余额"口径，替代生产环境混淆的计算方式
--   - 用于风险监控、资金计划、业务分析
--   - 架构设计：核心余额统计表，唯一可信数据源
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='贷款余额日统计表，按日期维度统计贷款余额相关指标',
    tags=['fund', 'dws', 'agg', 'loan_balance', 'daily']
) }}

WITH daily_promissory_note_records AS (
    -- ============================================
    -- 按日期获取借据记录（取每天最新状态）并关联客户信息
    -- ============================================
    WITH ranked_promissory_notes AS (
        SELECT
            pn.promissory_note_no,
            pn.contract_code,
            pn.loan_balance,
            pn.credit_quota,
            pn.promissory_note_end_date,
            CAST(pn.trx_date AS DATE) AS stats_date,
            pn.update_time,
            ROW_NUMBER() OVER (PARTITION BY pn.promissory_note_no, CAST(pn.trx_date AS DATE) ORDER BY pn.update_time DESC) AS rn
        FROM {{ ref('dwd_fund_promissory_note_fact_i') }} pn
        WHERE pn.promissory_note_status = '0'  -- 仅有效借据
    ),
    promissory_note_with_customer AS (
        SELECT
            pn.promissory_note_no,
            pn.contract_code,
            pn.loan_balance,
            pn.credit_quota,
            CAST(pn.promissory_note_end_date AS DATE) AS promissory_note_end_date,
            pn.stats_date,
            c.customer_id
        FROM ranked_promissory_notes pn
        LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
            ON c.customer_contract_no = pn.contract_code
            AND c.credit_result = '1'  -- 有效授信
        WHERE pn.rn = 1  -- 取每天每笔借据的最新记录
    )
    SELECT
        promissory_note_no,
        customer_id,
        loan_balance,
        credit_quota,
        promissory_note_end_date,
        stats_date
    FROM promissory_note_with_customer
    WHERE customer_id IS NOT NULL  -- 只保留能关联到客户的借据
),

loan_balance_stats AS (
    -- ============================================
    -- 按日期统计余额指标
    -- ============================================
    SELECT
        stats_date,
        -- 贷款余额总量
        SUM(loan_balance) AS total_loan_balance,
        COUNT(DISTINCT promissory_note_no) AS outstanding_promissory_note_cnt,
        COUNT(DISTINCT customer_id) AS loan_customer_cnt,

        -- 有余额的借据和客户
        COUNT(CASE WHEN loan_balance > 0 THEN 1 END) AS promissory_note_with_balance_cnt,
        COUNT(DISTINCT CASE WHEN loan_balance > 0 THEN customer_id END) AS customer_with_balance_cnt,

        -- 逾期统计（到期日 < 统计日期）
        SUM(CASE WHEN promissory_note_end_date < stats_date THEN loan_balance ELSE 0 END) AS overdue_loan_balance,
        COUNT(CASE WHEN promissory_note_end_date < stats_date AND loan_balance > 0 THEN 1 END) AS overdue_promissory_note_cnt,
        COUNT(DISTINCT CASE WHEN promissory_note_end_date < stats_date AND loan_balance > 0 THEN customer_id END) AS overdue_customer_cnt,

        -- 到期预警（7天内到期）
        SUM(CASE
            WHEN promissory_note_end_date >= stats_date
                 AND promissory_note_end_date <= stats_date + INTERVAL '7 days'
                 AND loan_balance > 0
            THEN loan_balance ELSE 0
        END) AS due_7d_loan_balance,
        COUNT(CASE
            WHEN promissory_note_end_date >= stats_date
                 AND promissory_note_end_date <= stats_date + INTERVAL '7 days'
                 AND loan_balance > 0
            THEN 1 END
        ) AS due_7d_promissory_note_cnt,

        -- 到期预警（30天内到期）
        SUM(CASE
            WHEN promissory_note_end_date >= stats_date
                 AND promissory_note_end_date <= stats_date + INTERVAL '30 days'
                 AND loan_balance > 0
            THEN loan_balance ELSE 0
        END) AS due_30d_loan_balance,
        COUNT(CASE
            WHEN promissory_note_end_date >= stats_date
                 AND promissory_note_end_date <= stats_date + INTERVAL '30 days'
                 AND loan_balance > 0
            THEN 1 END
        ) AS due_30d_promissory_note_cnt

    FROM daily_promissory_note_records
    GROUP BY stats_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 统计维度
    stats_date,                                                             -- 统计日期

    -- 贷款余额总量
    total_loan_balance,                                                     -- 总贷款余额
    outstanding_promissory_note_cnt,                                        -- 在贷笔数（所有有效借据）
    loan_customer_cnt,                                                      -- 在贷客户数

    -- 有余额的借据和客户
    promissory_note_with_balance_cnt,                                       -- 有余额借据笔数
    customer_with_balance_cnt,                                              -- 有余额客户数

    -- 逾期统计
    overdue_loan_balance,                                                   -- 逾期贷款余额
    overdue_promissory_note_cnt,                                           -- 逾期借据笔数
    overdue_customer_cnt,                                                   -- 逾期客户数

    -- 到期预警（7天内）
    due_7d_loan_balance,                                                    -- 7天内到期余额
    due_7d_promissory_note_cnt,                                             -- 7天内到期笔数

    -- 到期预警（30天内）
    due_30d_loan_balance,                                                   -- 30天内到期余额
    due_30d_promissory_note_cnt,                                            -- 30天内到期笔数

    -- 比率指标
    CASE
        WHEN total_loan_balance > 0
        THEN ROUND((overdue_loan_balance / total_loan_balance) * 100, 2)
        ELSE 0
    END AS overdue_rate_pct,                                                -- 逾期率（%）

    -- 平均余额
    CASE
        WHEN promissory_note_with_balance_cnt > 0
        THEN ROUND(total_loan_balance / promissory_note_with_balance_cnt, 2)
        ELSE 0
    END AS avg_loan_balance_per_promissory_note,                            -- 平均每笔借据余额

    CASE
        WHEN customer_with_balance_cnt > 0
        THEN ROUND(total_loan_balance / customer_with_balance_cnt, 2)
        ELSE 0
    END AS avg_loan_balance_per_customer,                                   -- 平均每个客户余额

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM loan_balance_stats
ORDER BY stats_date DESC
