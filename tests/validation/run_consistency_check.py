#!/usr/bin/env python3
"""
数据一致性校验脚本
验证新旧模型的数据一致性
"""

import duckdb
import sys
from datetime import datetime

# 连接到DuckDB数据库
con = duckdb.connect(database='dev.duckdb')

print("=" * 80)
print("数据一致性校验开始")
print(f"时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
print("=" * 80)
print()

all_passed = True

# ============================================
# 1. STATE表一致性校验
# ============================================
print("1. STATE表一致性校验")
print("  新表: dws_fund_customer_loan_state_df")
print("  旧表: dws_fund_customer_loan_balance_state_df")
print("-" * 80)

# 1.1 记录数对比
result = con.execute("""
    SELECT
        (SELECT COUNT(*) FROM dws_fund_customer_loan_state_df) AS new_count,
        (SELECT COUNT(*) FROM dws_fund_customer_loan_balance_state_df) AS old_count
""").fetchone()

new_count, old_count = result
count_diff = new_count - old_count
status = "PASS" if new_count == old_count else "FAIL"

print(f"  记录数对比:")
print(f"    新表记录数: {new_count}")
print(f"    旧表记录数: {old_count}")
print(f"    差异: {count_diff}")
print(f"    校验状态: {status}")

if status != "PASS":
    all_passed = False
print()

# 1.2 核心字段对比
result = con.execute("""
    SELECT
        (SELECT COALESCE(SUM(total_credit_quota), 0) FROM dws_fund_customer_loan_state_df)
        - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM dws_fund_customer_loan_balance_state_df) AS diff_credit,
        (SELECT COALESCE(SUM(total_remain_quota), 0) FROM dws_fund_customer_loan_state_df)
        - (SELECT COALESCE(SUM(total_remain_quota), 0) FROM dws_fund_customer_loan_balance_state_df) AS diff_remain,
        (SELECT COALESCE(SUM(total_loan_balance), 0) FROM dws_fund_customer_loan_state_df)
        - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM dws_fund_customer_loan_balance_state_df) AS diff_loan
""").fetchone()

diff_credit, diff_remain, diff_loan = result
status = "PASS" if abs(diff_credit) < 0.01 and abs(diff_remain) < 0.01 and abs(diff_loan) < 0.01 else "FAIL"

print(f"  核心字段对比:")
print(f"    授信额度差异: {diff_credit:.2f}")
print(f"    剩余额度差异: {diff_remain:.2f}")
print(f"    贷款余额差异: {diff_loan:.2f}")
print(f"    校验状态: {status}")

if status != "PASS":
    all_passed = False
    print()
    print("  检测不匹配记录...")
    mismatch_result = con.execute("""
        WITH new_state AS (
            SELECT customer_id, total_credit_quota, total_remain_quota, total_loan_balance
            FROM dws_fund_customer_loan_state_df
        ),
        old_state AS (
            SELECT customer_id, total_credit_quota, total_remain_quota, total_loan_balance
            FROM dws_fund_customer_loan_balance_state_df
        ),
        state_compare AS (
            SELECT
                COALESCE(new.customer_id, old.customer_id) AS customer_id,
                new.total_credit_quota AS new_credit,
                old.total_credit_quota AS old_credit,
                new.total_remain_quota AS new_remain,
                old.total_remain_quota AS old_remain,
                new.total_loan_balance AS new_loan,
                old.total_loan_balance AS old_loan
            FROM new_state new
            FULL OUTER JOIN old_state old ON new.customer_id = old.customer_id
        )
        SELECT
            customer_id,
            ROUND(new_credit, 2) AS new_credit,
            ROUND(old_credit, 2) AS old_credit,
            ROUND(new_remain, 2) AS new_remain,
            ROUND(old_remain, 2) AS old_remain,
            ROUND(new_loan, 2) AS new_loan,
            ROUND(old_loan, 2) AS old_loan
        FROM state_compare
        WHERE ABS(COALESCE(new_credit, 0) - COALESCE(old_credit, 0)) > 0.01
           OR ABS(COALESCE(new_remain, 0) - COALESCE(old_remain, 0)) > 0.01
           OR ABS(COALESCE(new_loan, 0) - COALESCE(old_loan, 0)) > 0.01
        ORDER BY customer_id
        LIMIT 10
    """).fetchall()

    if mismatch_result:
        print(f"  发现 {len(mismatch_result)} 条不匹配记录（显示前10条）:")
        for row in mismatch_result:
            print(f"    customer_id={row[0]}: 新授信={row[1]}, 旧授信={row[2]}, 新剩余={row[3]}, 旧剩余={row[4]}, 新贷款={row[5]}, 旧贷款={row[6]}")
    else:
        print("  没有找到不匹配的记录")

print()

# ============================================
# 2. SNAP表一致性校验
# ============================================
print("2. SNAP表一致性校验")
print("  新表: dws_fund_customer_loan_snap_df")
print("  旧表: dws_fund_customer_fund_snap_df")
print("-" * 80)

# 2.1 记录数对比
result = con.execute("""
    SELECT
        (SELECT COUNT(*) FROM dws_fund_customer_loan_snap_df) AS new_count,
        (SELECT COUNT(*) FROM dws_fund_customer_fund_snap_df) AS old_count
""").fetchone()

new_count, old_count = result
count_diff = new_count - old_count
status = "PASS" if new_count == old_count else "FAIL"

print(f"  记录数对比:")
print(f"    新表记录数: {new_count}")
print(f"    旧表记录数: {old_count}")
print(f"    差异: {count_diff}")
print(f"    校验状态: {status}")

if status != "PASS":
    all_passed = False
print()

# 2.2 最新日期核心字段对比
result = con.execute("""
    WITH new_snap_latest AS (
        SELECT * FROM dws_fund_customer_loan_snap_df
        WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_loan_snap_df)
    ),
    old_snap_latest AS (
        SELECT * FROM dws_fund_customer_fund_snap_df
        WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_fund_snap_df)
    )
    SELECT
        (SELECT COALESCE(SUM(total_credit_quota), 0) FROM new_snap_latest)
        - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM old_snap_latest) AS diff_credit,
        (SELECT COALESCE(SUM(total_loan_balance), 0) FROM new_snap_latest)
        - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM old_snap_latest) AS diff_loan
""").fetchone()

diff_credit, diff_loan = result
status = "PASS" if abs(diff_credit) < 0.01 and abs(diff_loan) < 0.01 else "FAIL"

print(f"  最新日核心字段对比:")
print(f"    授信额度差异: {diff_credit:.2f}")
print(f"    贷款余额差异: {diff_loan:.2f}")
print(f"    校验状态: {status}")

if status != "PASS":
    all_passed = False
print()

# ============================================
# 3. AGG表一致性校验
# ============================================
print("3. AGG表一致性校验")
print("  新表: dws_fund_customer_loan_agg_df")
print("  旧表: dws_fund_customer_agg_df")
print("-" * 80)

# 3.1 记录数对比
result = con.execute("""
    SELECT
        (SELECT COUNT(*) FROM dws_fund_customer_loan_agg_df) AS new_count,
        (SELECT COUNT(*) FROM dws_fund_customer_agg_df) AS old_count
""").fetchone()

new_count, old_count = result
count_diff = new_count - old_count
status = "PASS" if new_count == old_count else "FAIL"

print(f"  记录数对比:")
print(f"    新表记录数: {new_count}")
print(f"    旧表记录数: {old_count}")
print(f"    差异: {count_diff}")
print(f"    校验状态: {status}")

if status != "PASS":
    all_passed = False
print()

# 3.2 最新日期核心字段对比
result = con.execute("""
    WITH new_agg_latest AS (
        SELECT * FROM dws_fund_customer_loan_agg_df
        WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_loan_agg_df)
    ),
    old_agg_latest AS (
        SELECT * FROM dws_fund_customer_agg_df
        WHERE stats_date = (SELECT MAX(stats_date) FROM dws_fund_customer_agg_df)
    )
    SELECT
        (SELECT COALESCE(SUM(total_credit_quota), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(total_credit_quota), 0) FROM old_agg_latest) AS diff_credit,
        (SELECT COALESCE(SUM(total_loan_balance), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(total_loan_balance), 0) FROM old_agg_latest) AS diff_loan,
        (SELECT COALESCE(SUM(cumulative_loan_amt), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(cumulative_loan_amt), 0) FROM old_agg_latest) AS diff_cumulative_loan,
        (SELECT COALESCE(SUM(cumulative_repay_amt), 0) FROM new_agg_latest)
        - (SELECT COALESCE(SUM(cumulative_repay_amt), 0) FROM old_agg_latest) AS diff_cumulative_repay
""").fetchone()

diff_credit, diff_loan, diff_cumulative_loan, diff_cumulative_repay = result
status = "PASS" if (abs(diff_credit) < 0.01 and abs(diff_loan) < 0.01 and
                   abs(diff_cumulative_loan) < 0.01 and abs(diff_cumulative_repay) < 0.01) else "FAIL"

print(f"  最新日核心字段对比:")
print(f"    授信额度差异: {diff_credit:.2f}")
print(f"    贷款余额差异: {diff_loan:.2f}")
print(f"    累计放款差异: {diff_cumulative_loan:.2f}")
print(f"    累计还款差异: {diff_cumulative_repay:.2f}")
print(f"    校验状态: {status}")

if status != "PASS":
    all_passed = False
print()

# ============================================
# 校验总结
# ============================================
print("=" * 80)
print("数据一致性校验完成")
print("=" * 80)

if all_passed:
    print("状态: ✓ 所有校验通过")
    print()
    print("新旧模型数据完全一致，可以安全迁移。")
    exit_code = 0
else:
    print("状态: ✗ 部分校验失败")
    print()
    print("请检查上述失败项，确认数据差异是否可接受。")
    exit_code = 1

print()
print(f"完成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

con.close()
sys.exit(exit_code)
