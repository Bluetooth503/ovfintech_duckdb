-- =============================================
-- 测试名称：check_new_old_models_consistency
-- 测试描述：验证新旧模型数据一致性的简化版本
-- 说明：
--   - 这是用于手动执行的独立SQL查询
--   - 对比三对新旧模型的数据一致性
--   - 可以在DuckDB中直接运行，无需dbt
--   - 注意：需要先替换 {{ ref('xxx') }} 为实际的表名
-- =============================================

-- 1. STATE表一致性校验
-- ============================================
-- 说明：对比新旧state表的记录数和核心字段总和
-- ============================================

-- 1.1 记录数对比
SELECT
    'STATE表记录数对比' AS check_type,
    (SELECT COUNT(*) FROM dws_fund_customer_loan_state_df) AS 新表记录数,
    (SELECT COUNT(*) FROM dws_fund_customer_loan_balance_state_df) AS 旧表记录数,
    (SELECT COUNT(*) FROM dws_fund_customer_loan_state_df)
    - (SELECT COUNT(*) FROM dws_fund_customer_loan_balance_state_df) AS 差异,
    CASE
        WHEN (SELECT COUNT(*) FROM dws_fund_customer_loan_state_df)
          = (SELECT COUNT(*) FROM dws_fund_customer_loan_balance_state_df)
        THEN 'PASS'
        ELSE 'FAIL'
    END AS 校验状态;

-- 1.2 核心字段总和对比
SELECT
    'STATE表核心字段对比' AS check_type,
    ROUND(
        (SELECT COALESCE(SUM(total_credit_quota), 0) FROM dws_fund_customer_loan_state_df)
        - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM dws_fund_customer_loan_balance_state_df),
        2
    ) AS 授信额度差异,
    ROUND(
        (SELECT COALESCE(SUM(total_remain_quota), 0) FROM dws_fund_customer_loan_state_df)
        - (SELECT COALESCE(SUM(total_remain_quota), 0) FROM dws_fund_customer_loan_balance_state_df),
        2
    ) AS 剩余额度差异,
    ROUND(
        (SELECT COALESCE(SUM(total_loan_balance), 0) FROM dws_fund_customer_loan_state_df)
        - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM dws_fund_customer_loan_balance_state_df),
        2
    ) AS 贷款余额差异,
    CASE
        WHEN ABS((SELECT COALESCE(SUM(total_credit_quota), 0) FROM dws_fund_customer_loan_state_df)
              - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM dws_fund_customer_loan_balance_state_df)) < 0.01
         AND ABS((SELECT COALESCE(SUM(total_remain_quota), 0) FROM dws_fund_customer_loan_state_df)
              - (SELECT COALESCE(SUM(total_remain_quota), 0) FROM dws_fund_customer_loan_balance_state_df)) < 0.01
         AND ABS((SELECT COALESCE(SUM(total_loan_balance), 0) FROM dws_fund_customer_loan_state_df)
              - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM dws_fund_customer_loan_balance_state_df)) < 0.01
        THEN 'PASS'
        ELSE 'FAIL'
    END AS 校验状态;


-- 2. SNAP表一致性校验
-- ============================================
-- 说明：对比新旧snap表的记录数和最新日期的核心字段总和
-- ============================================

-- 2.1 记录数对比
SELECT
    'SNAP表记录数对比' AS check_type,
    (SELECT COUNT(*) FROM dws_fund_customer_loan_snap_df) AS 新表记录数,
    (SELECT COUNT(*) FROM dws_fund_customer_fund_snap_df) AS 旧表记录数,
    (SELECT COUNT(*) FROM dws_fund_customer_loan_snap_df)
    - (SELECT COUNT(*) FROM dws_fund_customer_fund_snap_df) AS 差异,
    CASE
        WHEN (SELECT COUNT(*) FROM dws_fund_customer_loan_snap_df)
          = (SELECT COUNT(*) FROM dws_fund_customer_fund_snap_df)
        THEN 'PASS'
        ELSE 'FAIL'
    END AS 校验状态;

-- 2.2 最新日期核心字段对比
WITH new_snap_latest AS (
    SELECT * FROM dws_fund_customer_loan_snap_df
    WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_loan_snap_df)
),
old_snap_latest AS (
    SELECT * FROM dws_fund_customer_fund_snap_df
    WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_fund_snap_df)
)
SELECT
    'SNAP表最新日核心字段对比' AS check_type,
    ROUND(
        (SELECT COALESCE(SUM(total_credit_quota), 0) FROM new_snap_latest)
        - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM old_snap_latest),
        2
    ) AS 授信额度差异,
    ROUND(
        (SELECT COALESCE(SUM(total_loan_balance), 0) FROM new_snap_latest)
        - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM old_snap_latest),
        2
    ) AS 贷款余额差异,
    CASE
        WHEN ABS((SELECT COALESCE(SUM(total_credit_quota), 0) FROM new_snap_latest)
              - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM old_snap_latest)) < 0.01
         AND ABS((SELECT COALESCE(SUM(total_loan_balance), 0) FROM new_snap_latest)
              - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM old_snap_latest)) < 0.01
        THEN 'PASS'
        ELSE 'FAIL'
    END AS 校验状态;


-- 3. AGG表一致性校验
-- ============================================
-- 说明：对比新旧agg表的记录数和最新日期的核心字段总和
-- ============================================

-- 3.1 记录数对比
SELECT
    'AGG表记录数对比' AS check_type,
    (SELECT COUNT(*) FROM dws_fund_customer_loan_agg_df) AS 新表记录数,
    (SELECT COUNT(*) FROM dws_fund_customer_agg_df) AS 旧表记录数,
    (SELECT COUNT(*) FROM dws_fund_customer_loan_agg_df)
    - (SELECT COUNT(*) FROM dws_fund_customer_agg_df) AS 差异,
    CASE
        WHEN (SELECT COUNT(*) FROM dws_fund_customer_loan_agg_df)
          = (SELECT COUNT(*) FROM dws_fund_customer_agg_df)
        THEN 'PASS'
        ELSE 'FAIL'
    END AS 校验状态;

-- 3.2 最新日期核心字段对比
WITH new_agg_latest AS (
    SELECT * FROM dws_fund_customer_loan_agg_df
    WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_loan_agg_df)
),
old_agg_latest AS (
    SELECT * FROM dws_fund_customer_agg_df
    WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_agg_df)
)
SELECT
    'AGG表最新日核心字段对比' AS check_type,
    ROUND(
        (SELECT COALESCE(SUM(total_credit_quota), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM old_agg_latest),
        2
    ) AS 授信额度差异,
    ROUND(
        (SELECT COALESCE(SUM(total_loan_balance), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM old_agg_latest),
        2
    ) AS 贷款余额差异,
    ROUND(
        (SELECT COALESCE(SUM(cumulative_loan_amt), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(cumulative_loan_amt), 0) FROM old_agg_latest),
        2
    ) AS 累计放款差异,
    ROUND(
        (SELECT COALESCE(SUM(cumulative_repay_amt), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(cumulative_repay_amt), 0) FROM old_agg_latest),
        2
    ) AS 累计还款差异,
    CASE
        WHEN ABS((SELECT COALESCE(SUM(total_credit_quota), 0) FROM new_agg_latest)
              - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM old_agg_latest)) < 0.01
         AND ABS((SELECT COALESCE(SUM(total_loan_balance), 0) FROM new_agg_latest)
              - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM old_agg_latest)) < 0.01
         AND ABS((SELECT COALESCE(SUM(cumulative_loan_amt), 0) FROM new_agg_latest)
              - (SELECT COALESCE(SUM(cumulative_loan_amt), 0) FROM old_agg_latest)) < 0.01
         AND ABS((SELECT COALESCE(SUM(cumulative_repay_amt), 0) FROM new_agg_latest)
              - (SELECT COALESCE(SUM(cumulative_repay_amt), 0) FROM old_agg_latest)) < 0.01
        THEN 'PASS'
        ELSE 'FAIL'
    END AS 校验状态;


-- 4. 不匹配记录明细查询（可选）
-- ============================================
-- 说明：如果上述校验失败，运行此查询查看不匹配的记录
-- ============================================

-- 4.1 STATE表不匹配记录
WITH new_state AS (
    SELECT
        customer_id,
        total_credit_quota,
        total_remain_quota,
        total_loan_balance
    FROM dws_fund_customer_loan_state_df
),
old_state AS (
    SELECT
        customer_id,
        total_credit_quota,
        total_remain_quota,
        total_loan_balance
    FROM dws_fund_customer_loan_balance_state_df
),
state_compare AS (
    SELECT
        COALESCE(new.customer_id, old.customer_id) AS customer_id,
        new.total_credit_quota AS new_credit_quota,
        old.total_credit_quota AS old_credit_quota,
        new.total_remain_quota AS new_remain_quota,
        old.total_remain_quota AS old_remain_quota,
        new.total_loan_balance AS new_loan_balance,
        old.total_loan_balance AS old_loan_balance
    FROM new_state new
    FULL OUTER JOIN old_state old ON new.customer_id = old.customer_id
)
SELECT
    'STATE表不匹配记录' AS check_type,
    customer_id,
    ROUND(new_credit_quota, 2) AS 新授信额度,
    ROUND(old_credit_quota, 2) AS 旧授信额度,
    ROUND(new_remain_quota, 2) AS 新剩余额度,
    ROUND(old_remain_quota, 2) AS 旧剩余额度,
    ROUND(new_loan_balance, 2) AS 新贷款余额,
    ROUND(old_loan_balance, 2) AS 旧贷款余额
FROM state_compare
WHERE ABS(COALESCE(new_credit_quota, 0) - COALESCE(old_credit_quota, 0)) > 0.01
   OR ABS(COALESCE(new_remain_quota, 0) - COALESCE(old_remain_quota, 0)) > 0.01
   OR ABS(COALESCE(new_loan_balance, 0) - COALESCE(old_loan_balance, 0)) > 0.01
ORDER BY customer_id
LIMIT 100;
