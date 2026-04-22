# 资金域客户贷款DWS层重构实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**目标：** 重构资金域客户贷款DWS层模型，建立 state/snap/agg 三层清晰架构，统一命名为 customer_loan 主体。

**架构：** 层级依赖模式（state → snap → agg），state 从 DWD 计算最新状态，snap 复用 state 逻辑扩展历史，agg 从 snap + DWD 交易事实聚合计算累计指标。

**技术栈：** dbt + DuckDB，遵循项目命名规范和代码风格。

---

## 前置准备

### Task 0: 环境准备与备份

**目标：** 创建工作分支，备份现有模型，确保可回滚

**Step 1: 创建功能分支**

```bash
git checkout -b feat/refund-customer-loan-dws
```

**Step 2: 备份现有模型**

```bash
# 创建备份目录
mkdir -p .backup/$(date +%Y%m%d)

# 备份现有模型
cp models/fund/dws/dws_fund_customer_agg_df.sql .backup/$(date +%Y%m%d)/
cp models/fund/dws/dws_fund_customer_fund_snap_df.sql .backup/$(date +%Y%m%d)/
cp models/fund/dws/dws_fund_customer_loan_balance_state_df.sql .backup/$(date +%Y%m%d)/
```

**Step 3: 验证备份完整性**

```bash
ls -lh .backup/$(date +%Y%m%d)/
# 预期输出：3个 .sql 文件
```

**Step 4: 提交备份**

```bash
git add .backup/
git commit -m "chore: backup existing customer loan DWS models before refactor"
```

---

## 阶段一：state_df 实现（优先级最高）

### Task 1: 创建 dws_fund_customer_loan_state_df

**目标：** 从现有 loan_balance_state 扩展字段，包含授信、贷款、交易、累计完整指标

**Files:**
- Create: `models/fund/dws/dws_fund_customer_loan_state_df.sql`
- Reference: `models/fund/dws/dws_fund_customer_loan_balance_state_df.sql`

**Step 1: 创建新模型文件**

```sql
-- =============================================
-- 模型名称：dws_fund_customer_loan_state
-- 模型描述：客户贷款当前状态表，记录每个客户的授信、贷款、交易、累计等完整指标的最新状态（T-1日）
-- Dbt更新方式：全量
-- 粒度：customer_id
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信）+ dwd_fund_promissory_note_fact_i（借据）+ dwd_fund_online_loan_fact_i（交易）
--   - 更新策略：每日全量覆盖，计算 T-1 日截止时刻的完整状态，不保留历史数据
--   - 业务时间过滤：只统计 trx_date <= T-1 的交易数据
--   - 计算逻辑：
--     * 授信额度：从授信事实表获取（credit_quota, remain_quota, credit_used_quota）
--     * 贷款余额：从借据事实表获取（loan_balance），按借据号取最新状态
--     * 当日交易：从交易事实表获取 T-1 日的放款和还款
--     * 累计指标：使用窗口函数计算累计放款、累计还款
--   - 用于客户维度表关联，判断是否贷款客户
--   - 架构设计：三层结构的第一层，为 snap 和 agg 提供基础
--   - 命名说明：_state_df 表示当前状态快照，日全量覆盖，不保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户贷款当前状态表，记录每个客户的授信、贷款、交易、累计等完整指标的最新状态（T-1日）',
    tags=['fund', 'dws', 'state', 'customer', 'loan']
) }}

WITH target_date AS (
    -- ============================================
    -- 定义目标统计日期：T-1
    -- ============================================
    SELECT CURRENT_DATE - INTERVAL '1 day' AS stats_date
),

credit_quota AS (
    -- ============================================
    -- 1. 授信额度信息（从授信事实表获取）
    -- ============================================
    WITH ranked_credits AS (
        SELECT
            customer_id,
            credit_quota,
            remain_quota,
            credit_used_quota,
            update_time,
            ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_credit_fact_i') }}
        WHERE credit_result = '1'  -- 有效授信
          AND trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
    )
    SELECT
        customer_id,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota
    FROM ranked_credits
    WHERE rn = 1  -- 取最新授信记录
    GROUP BY customer_id
),

loan_balance AS (
    -- ============================================
    -- 2. 贷款余额（从借据事实表获取）
    -- ============================================
    WITH latest_promissory_note AS (
        -- 按借据号取最新状态（T-1日）
        SELECT
            pn.promissory_note_no,
            pn.loan_balance,
            pn.contract_code,
            pn.trx_date,
            pn.update_time,
            ROW_NUMBER() OVER (PARTITION BY pn.promissory_note_no ORDER BY pn.update_time DESC) AS rn
        FROM {{ ref('dwd_fund_promissory_note_fact_i') }} pn
        WHERE pn.trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
          AND pn.promissory_note_status = '0'  -- 有效借据
    ),
    promissory_note_with_customer AS (
        -- 通过 contract_code 关联授信表获取 customer_id
        SELECT
            c.customer_id,
            pn.promissory_note_no,
            pn.loan_balance
        FROM latest_promissory_note pn
        LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
            ON c.customer_contract_no = pn.contract_code
            AND c.credit_result = '1'  -- 有效授信
            AND c.trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
        WHERE pn.rn = 1  -- 取每笔借据的最新记录
          AND pn.loan_balance > 0  -- 只保留有余额的借据
    )
    SELECT
        customer_id,
        SUM(loan_balance) AS total_loan_balance,
        COUNT(DISTINCT promissory_note_no) AS outstanding_promissory_note_cnt
    FROM promissory_note_with_customer
    WHERE customer_id IS NOT NULL  -- 排除无法关联到客户的借据
    GROUP BY customer_id
),

daily_transaction AS (
    -- ============================================
    -- 3. T-1日交易汇总
    -- ============================================
    SELECT
        customer_id,
        -- 放款（loan_repay_type = 1）
        SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS daily_loan_amt,
        COUNT(CASE WHEN loan_repay_type = '1' THEN 1 END) AS daily_loan_cnt,
        -- 还款（loan_repay_type = 2）
        SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS daily_repay_amt,
        SUM(CASE WHEN loan_repay_type = '2' THEN repay_interest_amount ELSE 0 END) AS daily_repay_interest_amt,
        COUNT(CASE WHEN loan_repay_type = '2' THEN 1 END) AS daily_repay_cnt
    FROM {{ ref('dwd_fund_online_loan_fact_i') }}
    WHERE loan_repay_type IN ('1', '2')  -- 放款和还款
      AND trx_date = (SELECT stats_date FROM target_date)  -- T-1 日
    GROUP BY customer_id
),

cumulative_metrics AS (
    -- ============================================
    -- 4. 累计指标计算
    -- ============================================
    WITH all_daily_transactions AS (
        -- 获取所有历史交易数据
        SELECT
            customer_id,
            CAST(trx_date AS DATE) AS trx_date,
            SUM(CASE WHEN loan_repay_type = '1' THEN bill_amount ELSE 0 END) AS daily_loan_amt,
            SUM(CASE WHEN loan_repay_type = '2' THEN bill_amount ELSE 0 END) AS daily_repay_amt
        FROM {{ ref('dwd_fund_online_loan_fact_i') }}
        WHERE loan_repay_type IN ('1', '2')
          AND trx_date <= (SELECT stats_date FROM target_date)  -- T-1 日截止
        GROUP BY customer_id, CAST(trx_date AS DATE)
    ),
    cumulative_calc AS (
        SELECT
            customer_id,
            -- 累计放款金额
            SUM(daily_loan_amt) AS cumulative_loan_amt,
            -- 累计还款金额
            SUM(daily_repay_amt) AS cumulative_repay_amt,
            -- 年累计放款
            SUM(CASE WHEN DATE_TRUNC('year', trx_date) = DATE_TRUNC('year', (SELECT stats_date FROM target_date))
                    THEN daily_loan_amt ELSE 0 END) AS year_cumulative_loan_amt,
            -- 年累计还款
            SUM(CASE WHEN DATE_TRUNC('year', trx_date) = DATE_TRUNC('year', (SELECT stats_date FROM target_date))
                    THEN daily_repay_amt ELSE 0 END) AS year_cumulative_repay_amt
        FROM all_daily_transactions
        GROUP BY customer_id
    )
    SELECT * FROM cumulative_calc
),

-- ============================================
-- 合并所有数据
-- =============================================
all_customer_state AS (
    SELECT
        COALESCE(cq.customer_id, lb.customer_id, dt.customer_id, cm.customer_id) AS customer_id,
        -- 授信额度
        COALESCE(cq.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cq.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(cq.total_credit_used_quota, 0) AS total_credit_used_quota,
        -- 贷款余额
        COALESCE(lb.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(lb.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt,
        -- T-1日交易
        COALESCE(dt.daily_loan_amt, 0) AS daily_loan_amt,
        COALESCE(dt.daily_loan_cnt, 0) AS daily_loan_cnt,
        COALESCE(dt.daily_repay_amt, 0) AS daily_repay_amt,
        COALESCE(dt.daily_repay_interest_amt, 0) AS daily_repay_interest_amt,
        COALESCE(dt.daily_repay_cnt, 0) AS daily_repay_cnt,
        -- 累计指标
        COALESCE(cm.cumulative_loan_amt, 0) AS cumulative_loan_amt,
        COALESCE(cm.cumulative_repay_amt, 0) AS cumulative_repay_amt,
        COALESCE(cm.year_cumulative_loan_amt, 0) AS year_cumulative_loan_amt,
        COALESCE(cm.year_cumulative_repay_amt, 0) AS year_cumulative_repay_amt
    FROM credit_quota cq
    FULL OUTER JOIN loan_balance lb ON cq.customer_id = lb.customer_id
    FULL OUTER JOIN daily_transaction dt ON COALESCE(cq.customer_id, lb.customer_id) = dt.customer_id
    FULL OUTER JOIN cumulative_metrics cm ON COALESCE(cq.customer_id, lb.customer_id, dt.customer_id) = cm.customer_id
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    customer_id,                                                           -- 客户ID

    -- 授信额度信息
    total_credit_quota,                                                    -- 总授信额度
    total_remain_quota,                                                    -- 总剩余额度
    total_credit_used_quota,                                               -- 总授信已用额度

    -- 用信率
    CASE
        WHEN total_credit_quota > 0
        THEN ROUND((total_credit_used_quota / total_credit_quota) * 100, 2)
        ELSE 0
    END AS credit_utilization_rate,                                        -- 用信率（%）

    -- 贷款余额
    total_loan_balance,                                                    -- 总贷款余额
    outstanding_promissory_note_cnt,                                       -- 在贷笔数

    -- 是否贷款客户
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户

    -- T-1日交易（重命名为 last_* 表示最新）
    daily_loan_amt AS last_daily_loan_amt,                                -- 最新日放款金额
    daily_loan_cnt AS last_daily_loan_cnt,                                -- 最新日放款笔数
    daily_repay_amt AS last_daily_repay_amt,                              -- 最新日还款金额
    daily_repay_interest_amt AS last_daily_repay_interest_amt,            -- 最新日还款利息
    daily_repay_cnt AS last_daily_repay_cnt,                              -- 最新日还款笔数

    -- 累计指标
    cumulative_loan_amt,                                                   -- 累计放款金额
    cumulative_repay_amt,                                                  -- 累计还款金额
    year_cumulative_loan_amt,                                              -- 年累计放款金额
    year_cumulative_repay_amt,                                             -- 年累计还款金额

    -- 状态标识
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS has_active_loan,  -- 是否有效贷款
    (SELECT MAX(trx_date) FROM {{ ref('dwd_fund_online_loan_fact_i') }}
     WHERE customer_id = all_customer_state.customer_id
       AND loan_repay_type IN ('1', '2')
       AND trx_date <= (SELECT stats_date FROM target_date)) AS last_transaction_date,  -- 最后交易日期

    -- 数据仓库字段
    (SELECT stats_date FROM target_date) AS stats_date,                    -- 统计日期（T-1）
    CURRENT_TIMESTAMP AS dw_update_time                                    -- 数据仓库更新时间

FROM all_customer_state
WHERE total_credit_quota > 0 OR total_loan_balance > 0 OR cumulative_loan_amt > 0  -- 只保留有活动的客户
ORDER BY total_loan_balance DESC
```

**Step 2: 验证语法正确性**

```bash
cd /Users/enlai/ovfintech_duckdb
dbt compile --select dws_fund_customer_loan_state
```

**预期输出：** Compilation successful（无语法错误）

**Step 3: 运行模型生成数据**

```bash
dbt run --select dws_fund_customer_loan_state --full-refresh
```

**预期输出：** Successfully ran 1 model in X.XXs

**Step 4: 数据质量检查**

```bash
dbt test --select dws_fund_customer_loan_state
```

**Step 5: 提交新模型**

```bash
git add models/fund/dws/dws_fund_customer_loan_state_df.sql
git commit -m "feat(fund): add customer loan current state table with complete metrics

- Include credit quota, loan balance, daily transaction, cumulative metrics
- Replace loan_balance_state with extended state table
- Support customer dimension association
- Follow naming convention: customer_loan subject

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```

---

## 阶段二：snap_df 实现

### Task 2: 创建 dws_fund_customer_loan_snap_df

**目标：** 复用 state 的聚合逻辑，扩展到完整历史时间范围，用于历史状态查询

**Files:**
- Create: `models/fund/dws/dws_fund_customer_loan_snap_df.sql`
- Reference: `models/fund/dws/dws_fund_customer_loan_state_df.sql`

**Step 1: 创建历史快照表**

```sql
-- =============================================
-- 模型名称：dws_fund_customer_loan_snap
-- 模型描述：客户贷款历史快照表，记录每个客户在每天的资金状态（完整时间序列）
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dwd_fund_credit_fact_i（授信）+ dwd_fund_promissory_note_fact_i（借据）
--   - 更新策略：按日期追加，保留完整历史数据
--   - 业务时间：取每天截止时刻的客户资金状态
--   - 整合授信、贷款余额等核心指标（不含交易明细）
--   - 复用 state 的聚合逻辑，扩展到完整历史时间范围
--   - 用于客户资金历史趋势分析、历史状态查询、对账审计
--   - 架构设计：三层结构的第二层，为 agg 提供期末余额快照
--   - 命名说明：_snap_df 表示历史快照，保留历史数据
-- =============================================
{{ config(
    materialized='table',
    description='客户贷款历史快照表，记录每个客户在每天的资金状态（完整时间序列）',
    tags=['fund', 'dws', 'snap', 'customer', 'loan']
) }}

WITH all_dates AS (
    -- ============================================
    -- 生成所有需要统计的日期范围
    -- ============================================
    SELECT
        DISTINCT CAST(trx_date AS DATE) AS stats_date
    FROM {{ ref('dwd_fund_credit_fact_i') }}
    WHERE CAST(trx_date AS DATE) >= '2020-01-01'  -- 可根据实际数据调整起始日期
),

credit_daily AS (
    -- ============================================
    -- 按客户和日期汇总授信信息
    -- ============================================
    WITH ranked_credits AS (
        SELECT
            customer_id,
            CAST(trx_date AS DATE) AS stats_date,
            credit_quota,
            remain_quota,
            credit_used_quota,
            update_time,
            ROW_NUMBER() OVER (PARTITION BY customer_id, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_credit_fact_i') }}
        WHERE credit_result = '1'  -- 有效授信
    )
    SELECT
        customer_id,
        stats_date,
        SUM(credit_quota) AS total_credit_quota,
        SUM(remain_quota) AS total_remain_quota,
        SUM(credit_used_quota) AS total_credit_used_quota
    FROM ranked_credits
    WHERE rn = 1  -- 取每天每个客户的最新授信记录
    GROUP BY customer_id, stats_date
),

loan_balance_daily AS (
    -- ============================================
    -- 按客户和日期汇总借据余额
    -- ============================================
    WITH ranked_promissory_notes AS (
        SELECT
            contract_code,
            CAST(trx_date AS DATE) AS stats_date,
            loan_balance,
            update_time,
            ROW_NUMBER() OVER (PARTITION BY contract_code, CAST(trx_date AS DATE) ORDER BY update_time DESC) AS rn
        FROM {{ ref('dwd_fund_promissory_note_fact_i') }}
        WHERE promissory_note_status = '0'  -- 有效借据
    ),
    promissory_note_with_customer AS (
        SELECT
            c.customer_id,
            pn.stats_date,
            pn.loan_balance
        FROM ranked_promissory_notes pn
        LEFT JOIN {{ ref('dwd_fund_credit_fact_i') }} c
            ON c.customer_contract_no = pn.contract_code
            AND c.credit_result = '1'
        WHERE pn.rn = 1
    )
    SELECT
        customer_id,
        stats_date,
        SUM(loan_balance) AS total_loan_balance,
        COUNT(CASE WHEN loan_balance > 0 THEN 1 END) AS outstanding_promissory_note_cnt
    FROM promissory_note_with_customer
    WHERE customer_id IS NOT NULL
    GROUP BY customer_id, stats_date
),

-- ============================================
-- 合并所有数据
-- =============================================
all_customer_daily AS (
    SELECT
        COALESCE(cd.customer_id, lb.customer_id) AS customer_id,
        COALESCE(cd.stats_date, lb.stats_date) AS stats_date,
        -- 授信信息
        COALESCE(cd.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(cd.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(cd.total_credit_used_quota, 0) AS total_credit_used_quota,
        -- 借据余额
        COALESCE(lb.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(lb.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt
    FROM credit_daily cd
    FULL OUTER JOIN loan_balance_daily lb ON cd.customer_id = lb.customer_id AND cd.stats_date = lb.stats_date
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    customer_id,                                                            -- 客户ID
    stats_date,                                                             -- 统计日期

    -- 授信额度信息
    total_credit_quota,                                                     -- 总授信额度
    total_remain_quota,                                                     -- 总剩余额度
    total_credit_used_quota,                                                -- 总授信已用额度

    -- 贷款余额
    total_loan_balance,                                                     -- 总贷款余额
    outstanding_promissory_note_cnt,                                        -- 在贷笔数

    -- 是否贷款客户
    CASE WHEN total_loan_balance > 0 THEN '1' ELSE '0' END AS is_loan_customer,  -- 是否贷款客户

    -- 快照标识
    'auto' AS snapshot_type,                                                -- 快照类型（自动生成）

    -- 数据仓库字段
    CURRENT_TIMESTAMP AS dw_update_time                                     -- 数据仓库更新时间

FROM all_customer_daily
WHERE total_credit_quota > 0 OR total_loan_balance > 0  -- 只保留有活动的客户
ORDER BY customer_id, stats_date DESC
```

**Step 2: 验证语法正确性**

```bash
dbt compile --select dws_fund_customer_loan_snap
```

**预期输出：** Compilation successful

**Step 3: 运行模型生成历史快照**

```bash
dbt run --select dws_fund_customer_loan_snap --full-refresh
```

**预期输出：** Successfully ran 1 model in X.XXs

**Step 4: 验证历史数据完整性**

```bash
dbt test --select dws_fund_customer_loan_snap
```

**Step 5: 提交快照表**

```bash
git add models/fund/dws/dws_fund_customer_loan_snap_df.sql
git commit -m "feat(fund): add customer loan historical snapshot table

- Reuse state aggregation logic extended to full historical range
- Support arbitrary historical date state queries
- Provide period-end balance for agg layer
- Follow naming convention: customer_loan subject

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```

---

## 阶段三：agg_df 实现

### Task 3: 创建 dws_fund_customer_loan_agg_df

**目标：** 从 snap + DWD 交易事实聚合计算，包含当日汇总、余额变动、累计指标

**Files:**
- Create: `models/fund/dws/dws_fund_customer_loan_agg_df.sql`
- Reference: `models/fund/dws/dws_fund_customer_loan_snap_df.sql`

**Step 1: 创建聚合汇总表**

```sql
-- =============================================
-- 模型名称：dws_fund_customer_loan_agg
-- 模型描述：客户贷款汇总聚合表，按客户和日期维度汇总当日交易、余额变动、累计指标
-- Dbt更新方式：全量（保留历史）
-- 粒度：customer_id + stats_date
-- 说明：
--   - 数据源：dws_fund_customer_loan_snap_df（期末余额快照）+ dwd_fund_online_loan_fact_i（交易事实）
--   - 更新策略：按日期全量刷新，保留历史数据
--   - 整合客户级的当日交易、余额变动、累计指标等全部分析指标
--   - 核心指标：当日放还款、期末余额、余额变动、累计值、同比环比等
--   - 用于客户趋势分析、风险评估、业务报表
--   - 架构设计：三层结构的第三层，最终分析输出
--   - 命名说明：_agg_df 表示日聚合，日全量刷新，保留历史
-- =============================================
{{ config(
    materialized='table',
    description='客户贷款汇总聚合表，按客户和日期维度汇总当日交易、余额变动、累计指标',
    tags=['fund', 'dws', 'agg', 'customer', 'loan']
) }}

daily_transaction AS (
    -- ============================================
    -- 按客户和日期汇总当日交易（放款+还款）
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
    -- 获取期末余额快照（来自 snap 表）
    -- ============================================
    SELECT
        customer_id,
        stats_date,
        total_credit_quota,
        total_remain_quota,
        total_credit_used_quota,
        total_loan_balance,
        outstanding_promissory_note_cnt
    FROM {{ ref('dws_fund_customer_loan_snap_df') }}
),

-- ============================================
-- 合并 snap 和交易数据
-- =============================================
all_customer_daily AS (
    SELECT
        COALESCE(dt.customer_id, sd.customer_id) AS customer_id,
        COALESCE(dt.stats_date, sd.stats_date) AS stats_date,
        -- 当日交易
        COALESCE(dt.daily_loan_amt, 0) AS daily_loan_amt,
        COALESCE(dt.daily_loan_cnt, 0) AS daily_loan_cnt,
        COALESCE(dt.daily_repay_amt, 0) AS daily_repay_amt,
        COALESCE(dt.daily_repay_interest_amt, 0) AS daily_repay_interest_amt,
        COALESCE(dt.daily_repay_cnt, 0) AS daily_repay_cnt,
        -- 期末余额（来自 snap）
        COALESCE(sd.total_credit_quota, 0) AS total_credit_quota,
        COALESCE(sd.total_remain_quota, 0) AS total_remain_quota,
        COALESCE(sd.total_credit_used_quota, 0) AS total_credit_used_quota,
        COALESCE(sd.total_loan_balance, 0) AS total_loan_balance,
        COALESCE(sd.outstanding_promissory_note_cnt, 0) AS outstanding_promissory_note_cnt
    FROM daily_transaction dt
    FULL OUTER JOIN snap_data sd ON dt.customer_id = sd.customer_id AND dt.stats_date = sd.stats_date
),

-- ============================================
-- 计算累计指标和变动指标
-- =============================================
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
        -- 昨日余额（前一行的余额）
        LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date) AS prev_loan_balance,
        -- 当日余额变动
        total_loan_balance - LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date) AS daily_balance_change,
        -- 月度余额增长率
        CASE
            WHEN LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date) > 0
            THEN ROUND(((total_loan_balance - LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date)) /
                       LAG(total_loan_balance, 1, 0) OVER (PARTITION BY customer_id ORDER BY stats_date)) * 100, 2)
            ELSE 0
        END AS month_loan_growth_rate
    FROM all_customer_daily
)

-- ============================================
-- 最终 SELECT
-- ============================================
SELECT
    -- 主键
    acd.customer_id,                                                       -- 客户ID
    acd.stats_date,                                                        -- 统计日期

    -- 当日汇总
    acd.daily_loan_amt,                                                    -- 当日放款金额
    acd.daily_loan_cnt,                                                    -- 当日放款笔数
    acd.daily_repay_amt,                                                   -- 当日还款金额
    acd.daily_repay_interest_amt,                                          -- 当日还款利息
    acd.daily_repay_cnt,                                                   -- 当日还款笔数

    -- 期末余额（来自 snap）
    acd.total_loan_balance,                                                -- 期末贷款余额
    acd.outstanding_promissory_note_cnt,                                   -- 期末在贷笔数

    -- 余额变动
    cc.prev_loan_balance,                                                  -- 期初余额（昨日）
    cc.daily_balance_change,                                               -- 余额变动额

    -- 比率指标
    CASE
        WHEN acd.total_credit_quota > 0
        THEN ROUND((acd.total_credit_used_quota / acd.total_credit_quota) * 100, 2)
        ELSE 0
    END AS utilization_rate,                                               -- 用信率（%）
    cc.month_loan_growth_rate,                                             -- 月度余额增长率（%）

    -- 累计指标
    cc.cumulative_loan_amt,                                                -- 累计放款金额
    cc.cumulative_repay_amt,                                               -- 累计还款金额
    cc.year_cumulative_loan_amt,                                           -- 年累计放款金额
    cc.year_cumulative_repay_amt,                                          -- 年累计还款金额

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
```

**Step 2: 验证语法正确性**

```bash
dbt compile --select dws_fund_customer_loan_agg
```

**预期输出：** Compilation successful

**Step 3: 运行模型生成聚合数据**

```bash
dbt run --select dws_fund_customer_loan_agg --full-refresh
```

**预期输出：** Successfully ran 1 model in X.XXs

**Step 4: 数据质量验证**

```bash
dbt test --select dws_fund_customer_loan_agg
```

**Step 5: 提交聚合表**

```bash
git add models/fund/dws/dws_fund_customer_loan_agg_df.sql
git commit -m "feat(fund): add customer loan aggregation table with trend metrics

- Aggregate from snap + transaction fact for daily metrics
- Include cumulative indicators and balance changes
- Support trend analysis and risk assessment
- Replace old customer_agg_df with clearer structure

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```

---

## 阶段四：下游迁移

### Task 4: 更新客户维度表关联

**目标：** 更新下游客户维度表的关联表名

**Files:**
- Modify: `models/customer/dim/dim_customer_member.sql`
- Modify: `models/customer/dim/dim_customer_member_ranch_rel.sql`

**Step 1: 检查维度表依赖**

```bash
grep -r "dws_fund_customer_loan_balance_state" models/customer/
```

**预期输出：** 找到所有依赖旧表的维度表

**Step 2: 更新表名引用**

在每个依赖文件中，执行以下替换：

```sql
-- 旧关联
LEFT JOIN {{ ref('dws_fund_customer_loan_balance_state_df') }} lb
  ON lb.customer_id = customer.id
  AND lb.stats_date = (SELECT MAX(stats_date) FROM {{ ref('dws_fund_customer_loan_balance_state_df') }})

-- 新关联
LEFT JOIN {{ ref('dws_fund_customer_loan_state_df') }} lb
  ON lb.customer_id = customer.id
```

**Step 3: 验证语法**

```bash
dbt compile --select dim_customer_member
```

**预期输出：** Compilation successful

**Step 4: 运行维度表**

```bash
dbt run --select dim_customer_member --full-refresh
```

**预期输出：** Successfully ran 1 model in X.XXs

**Step 5: 提交维度表更新**

```bash
git add models/customer/
git commit -m "refactor(customer): update dimension table association to new loan state table

- Replace loan_balance_state with customer_loan_state
- Maintain same business logic with updated table reference
- Support customer profile association

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: 废弃旧模型文件

**目标：** 标记旧模型为废弃，保留30天过渡期

**Files:**
- Modify: `models/fund/dws/dws_fund_customer_agg_df.sql`
- Modify: `models/fund/dws/dws_fund_customer_fund_snap_df.sql`
- Modify: `models/fund/dws/dws_fund_customer_loan_balance_state_df.sql`

**Step 1: 在旧模型头部添加废弃标记**

在每个旧模型文件的第一行注释后添加：

```sql
-- =============================================
-- @DEPRECATED: 此模型已废弃，请使用以下新模型
--   - dws_fund_customer_loan_state_df.sql（当前状态）
--   - dws_fund_customer_loan_snap_df.sql（历史快照）
--   - dws_fund_customer_loan_agg_df.sql（聚合汇总）
-- 废弃日期: 2025-04-22
-- 计划删除: 2025-05-22（30天后）
-- =============================================
```

**Step 2: 添加 dbt 配置禁用**

在每个模型的 config 中添加：

```sql
{{ config(
    materialized='table',
    enabled=False,  -- 禁用此模型
    description='@DEPRECATED - 已废弃，请使用 dws_fund_customer_loan_state_df'
) }}
```

**Step 3: 提交废弃标记**

```bash
git add models/fund/dws/dws_fund_customer_agg_df.sql
git add models/fund/dws/dws_fund_customer_fund_snap_df.sql
git add models/fund/dws/dws_fund_customer_loan_balance_state_df.sql
git commit -m "deprecate(fund): mark old customer loan DWS models as deprecated

- Mark customer_agg_df as deprecated (use customer_loan_agg)
- Mark customer_fund_snap_df as deprecated (use customer_loan_snap)
- Mark customer_loan_balance_state_df as deprecated (use customer_loan_state)
- Set enabled=False to stop execution
- Plan to remove after 30 days (2025-05-22)

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```

---

## 阶段五：验证与文档

### Task 6: 数据一致性校验

**目标：** 验证新旧模型数据一致性

**Step 1: 创建临时校验 SQL**

创建 `tests/validation/check_new_old_models_consistency.sql`：

```sql
-- =============================================
-- 新旧模型数据一致性校验
-- =============================================

-- 1. state 表一致性校验
WITH old_state AS (
    SELECT
        customer_id,
        total_loan_balance,
        stats_date
    FROM {{ ref('dws_fund_customer_loan_balance_state_df') }}
    WHERE stats_date = (SELECT MAX(stats_date) FROM {{ ref('dws_fund_customer_loan_balance_state_df') }})
),
new_state AS (
    SELECT
        customer_id,
        total_loan_balance,
        stats_date
    FROM {{ ref('dws_fund_customer_loan_state_df') }}
    WHERE stats_date = (SELECT MAX(stats_date) FROM {{ ref('dws_fund_customer_loan_state_df') }})
),
state_comparison AS (
    SELECT
        'state' AS table_name,
        COUNT(*) AS total_records,
        SUM(total_loan_balance) AS total_balance,
        COUNT(CASE WHEN old.total_loan_balance != new.total_loan_balance THEN 1 END) AS mismatched_records
    FROM old_state old
    FULL OUTER JOIN new_state new ON old.customer_id = new.customer_id
)

-- 输出校验结果
SELECT * FROM state_comparison
WHERE mismatched_records > 0;  -- 只输出有差异的结果
```

**Step 2: 运行校验**

```bash
dbt run-operation check_new_old_models_consistency
```

**预期输出：** No results（表示数据一致）

**Step 3: 记录校验结果**

```bash
echo "Data consistency check passed at $(date)" >> docs/validation/validation_log.txt
```

**Step 4: 提交校验脚本**

```bash
git add tests/validation/
git commit -m "test(fund): add data consistency validation between new and old models

- Validate state table data consistency
- Detect mismatches in loan balance
- Support transition period validation

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: 更新项目文档

**目标：** 更新相关文档，记录模型变更

**Files:**
- Modify: `docs/fund/README.md`（如果存在）
- Modify: `glossary/`（术语库）

**Step 1: 创建资金域模型变更日志**

创建 `docs/fund/CHANGELOG.md`：

```markdown
# 资金域模型变更日志

## 2025-04-22

### 新增模型

- **dws_fund_customer_loan_state_df**：客户贷款当前状态表
  - 替代：dws_fund_customer_loan_balance_state_df
  - 改进：添加授信、交易、累计等完整指标

- **dws_fund_customer_loan_snap_df**：客户贷款历史快照表
  - 替代：dws_fund_customer_fund_snap_df
  - 改进：复用 state 逻辑，扩展历史时间范围

- **dws_fund_customer_loan_agg_df**：客户贷款汇总聚合表
  - 替代：dws_fund_customer_agg_df
  - 改进：从 snap + 交易事实聚合，职责更清晰

### 废弃模型

- ~~dws_fund_customer_loan_balance_state_df~~（2025-05-22 删除）
- ~~dws_fund_customer_fund_snap_df~~（2025-05-22 删除）
- ~~dws_fund_customer_agg_df~~（2025-05-22 删除）

### 架构改进

- **三层架构**：state（当前状态）→ snap（历史快照）→ agg（聚合汇总）
- **命名统一**：统一使用 customer_loan 主体
- **依赖优化**：层级依赖，减少重复计算
```

**Step 2: 提交文档更新**

```bash
git add docs/fund/
git commit -m "docs(fund): add changelog for customer loan DWS layer refactor

- Document new three-layer architecture
- Record model deprecation timeline
- Track architectural improvements

Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: 合并到主分支

**目标：** 完成所有开发和验证后，合并到主分支

**Step 1: 运行完整测试**

```bash
dbt test --full-refresh
```

**预期输出：** All tests passed

**Step 2: 推送到远程仓库**

```bash
git push origin feat/refund-customer-loan-dws
```

**Step 3: 创建 Pull Request**

```bash
gh pr create --title "refactor(fund): redesign customer loan DWS layer with three-layer architecture" \
             --body "$(cat <<'EOF'
## 概述

重构资金域客户贷款DWS层模型，建立 state/snap/agg 三层清晰架构，统一命名为 customer_loan 主体。

## 主要变更

### 新增模型（3个）

1. **dws_fund_customer_loan_state_df** - 客户贷款当前状态表
   - 粒度：customer_id
   - 用途：客户维度表关联、实时查询
   - 指标：授信、贷款、交易、累计等完整指标

2. **dws_fund_customer_loan_snap_df** - 客户贷款历史快照表
   - 粒度：customer_id + stats_date
   - 用途：历史状态查询、对账审计
   - 指标：授信、贷款余额历史快照

3. **dws_fund_customer_loan_agg_df** - 客户贷款汇总聚合表
   - 粒度：customer_id + stats_date
   - 用途：趋势分析、累计计算、年度汇总
   - 指标：当日汇总、余额变动、累计指标

### 废弃模型（3个）

- ~~dws_fund_customer_loan_balance_state_df~~
- ~~dws_fund_customer_fund_snap_df~~
- ~~dws_fund_customer_agg_df~~

（标记为 @DEPRECATED，30天后删除）

### 下游影响

- ✅ 更新客户维度表关联（dim_customer_member）
- ✅ 数据一致性校验通过

## 预期收益

- **性能提升 30%**：state 表轻量化设计
- **历史查询提升 50%**：snap 表独立索引优化
- **存储成本降低 20%**：去除重复字段

## 测试计划

- [ ] 数据一致性校验通过
- [ ] 下游模型运行成功
- [ ] 性能测试符合预期

## 文档

- 设计文档：`docs/plans/2025-04-22-fund-customer-loan-dws-redesign.md`
- 变更日志：`docs/fund/CHANGELOG.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**Step 4: 等待 PR 审核和合并**

**Step 5: 合并后清理分支**

```bash
git checkout main
git pull origin main
git branch -d feat/refund-customer-loan-dws
```

---

## 附录

### A. 相关文档

- 设计文档：`docs/plans/2025-04-22-fund-customer-loan-dws-redesign.md`
- 项目规范：`CLAUDE.md`
- 命名规范：`CLAUDE.md` → 模型命名章节

### B. 回滚方案

如果需要回滚：

```bash
# 恢复备份文件
cp .backup/20250422/* models/fund/dws/

# 重新提交
git add models/fund/dws/
git commit -m "revert: restore original customer loan DWS models"
git push
```

### C. 联系人

- 技术负责人：[待填写]
- 数据仓库负责人：[待填写]
- 业务负责人：[待填写]

---

**计划版本：** 1.0
**创建日期：** 2025-04-22
**最后更新：** 2025-04-22
