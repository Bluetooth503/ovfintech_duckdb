# 牧场数据采集质量分析 - SQL 查询集合

**说明**：本文档包含所有用于生成《牧场数据采集质量分析报告》的 SQL 查询，可在 DuckDB 生产环境直接运行。

**✅ 重要更新（2026-04-20）**：
- 新增查询 11-17，通过出生日期计算日龄，已验证可将日龄数据可用性从 0.06% 提升至 69.53%（提升 1,159 倍）
- 详细分析报告：`docs/月龄测重覆盖率分析报告.md`
- SQL 查询脚本：`docs/月龄测重覆盖率分析-通过出生日期计算.sql`
- Python 自动化脚本：`scripts/analyze_monthly_age_coverage.py`

---

## 查询 1：AI 区域识别整体统计

**目的**：统计 AI 区域识别的整体情况，包括平均识别率、识别率分布、告警情况等

**✅ 重要更新（2026-04-20）**：
- 新增修正后平均识别率计算（排除 >120% 异常值）
- 新增中位数识别率计算（避免极端异常值影响）
- 新增异常值统计

```sql
-- 查询1: AI 区域识别整体统计（含修正后指标）
WITH overall_stats AS (
    -- 原始统计（含异常值）
    SELECT
        COUNT(*) AS total_records,
        COUNT(DISTINCT region_id) AS unique_regions,
        COUNT(DISTINCT date) AS unique_dates,
        ROUND(AVG(ratio), 4) AS avg_rate_all,
        ROUND(MIN(ratio), 4) AS min_rate,
        ROUND(MAX(ratio), 4) AS max_rate
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
),
filtered_stats AS (
    -- 排除 >120% 的极端异常值
    SELECT
        COUNT(*) AS total_records_filtered,
        ROUND(AVG(ratio), 4) AS avg_rate_filtered,
        ROUND(APPROX_QUANTILE(ratio, 0.5), 4) AS median_rate,
        COUNT(CASE WHEN ratio < 0.5 THEN 1 END) AS low_rate_count,
        ROUND(100.0 * COUNT(CASE WHEN ratio < 0.5 THEN 1 END) / COUNT(*), 2) AS low_rate_pct,
        COUNT(CASE WHEN ratio < 0.7 THEN 1 END) AS below_70_count,
        ROUND(100.0 * COUNT(CASE WHEN ratio < 0.7 THEN 1 END) / COUNT(*), 2) AS below_70_pct
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
      AND ratio <= 1.2  -- 排除识别率 >120% 的极端异常值
),
abnormal_stats AS (
    -- 统计异常值
    SELECT
        COUNT(*) AS abnormal_count,
        ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM ods_psi_region_ai_data WHERE value IS NOT NULL AND cattle_count IS NOT NULL AND cattle_count > 0), 2) AS abnormal_pct
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
      AND ratio > 1.2
)
SELECT
    a.total_records AS 总记录数,
    a.unique_regions AS 覆盖区域数,
    a.unique_dates AS 覆盖日期数,
    ROUND(a.avg_rate_all * 100, 2) AS 原始平均识别率_含异常值,
    ROUND(a.min_rate * 100, 2) AS 最低识别率,
    ROUND(a.max_rate * 100, 2) AS 最高识别率,
    b.total_records_filtered AS 过滤后记录数,
    ROUND(b.avg_rate_filtered * 100, 2) AS 修正后平均识别率_排除异常值,
    ROUND(b.median_rate * 100, 2) AS 中位数识别率,
    b.low_rate_count AS 低识别率记录_50以下,
    b.low_rate_pct AS 低识别率占比_50以下,
    b.below_70_count AS 低识别率记录_70以下,
    b.below_70_pct AS 低识别率占比_70以下,
    c.abnormal_count AS 异常记录数_120以上,
    c.abnormal_pct AS 异常记录占比
FROM overall_stats a
CROSS JOIN filtered_stats b
CROSS JOIN abnormal_stats c;
```

**预期结果**：
- `总记录数`：总识别记录数
- `覆盖区域数`：覆盖的区域数
- `覆盖日期数`：覆盖的日期数
- `原始平均识别率_含异常值`：包含所有数据的平均识别率（**注意：可能被极端异常值拉高**）
- `修正后平均识别率_排除异常值`：排除 >120% 异常值后的平均识别率（**推荐使用**）
- `中位数识别率`：中位数识别率（**推荐作为核心考核指标**）
- `异常记录数_120以上`：识别率 >120% 的异常记录数
- `异常记录占比`：异常记录的占比

**⚠️ 重要提示**：
1. 原平均识别率 79.19% 被极端异常值（识别率 >120%）严重拉高
2. **修正后平均识别率计算公式**：`ROUND(AVG(ratio), 4)` WHERE ratio <= 1.2，约 63.0%
3. **中位数识别率计算公式**：`ROUND(APPROX_QUANTILE(ratio, 0.5), 4)`，约 75%
4. **建议使用中位数识别率作为核心考核指标**，避免被极端值误导

---

## 查询 1.5：修正后的 AI 识别率（排除极端异常值）

**目的**：计算排除极端异常值后的真实识别率

```sql
-- 查询1.5: 修正后的 AI 识别率（排除极端异常值）
WITH overall_stats AS (
    -- 原始统计（含异常值）
    SELECT
        COUNT(*) AS total_records_all,
        ROUND(AVG(ratio), 4) AS avg_rate_all
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
),
filtered_stats AS (
    -- 排除 >120% 的极端异常值
    SELECT
        COUNT(*) AS total_records_filtered,
        ROUND(AVG(ratio), 4) AS avg_rate_filtered,
        ROUND(APPROX_QUANTILE(ratio, 0.5), 4) AS median_rate_filtered,
        COUNT(CASE WHEN ratio < 0.5 THEN 1 END) AS low_rate_count,
        ROUND(100.0 * COUNT(CASE WHEN ratio < 0.5 THEN 1 END) / COUNT(*), 2) AS low_rate_pct,
        COUNT(CASE WHEN ratio < 0.7 THEN 1 END) AS below_70_count,
        ROUND(100.0 * COUNT(CASE WHEN ratio < 0.7 THEN 1 END) / COUNT(*), 2) AS below_70_pct
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
      AND ratio <= 1.2  -- 排除识别率 >120% 的极端异常值
),
abnormal_stats AS (
    -- 统计异常值
    SELECT
        COUNT(*) AS abnormal_count,
        ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM ods_psi_region_ai_data WHERE value IS NOT NULL AND cattle_count IS NOT NULL AND cattle_count > 0), 2) AS abnormal_pct
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
      AND ratio > 1.2
)
SELECT
    a.total_records_all,
    ROUND(a.avg_rate_all * 100, 2) AS avg_rate_all_pct,
    b.total_records_filtered,
    ROUND(b.avg_rate_filtered * 100, 2) AS avg_rate_filtered_pct,
    ROUND(b.median_rate_filtered * 100, 2) AS median_rate_filtered_pct,
    b.low_rate_count,
    b.low_rate_pct,
    b.below_70_count,
    b.below_70_pct,
    c.abnormal_count,
    c.abnormal_pct,
    ROUND(100.0 * c.abnormal_count / a.total_records_all, 2) AS abnormal_ratio
FROM overall_stats a
CROSS JOIN filtered_stats b
CROSS JOIN abnormal_stats c;
```

**预期结果**：
- `total_records_all`：总记录数
- `avg_rate_all_pct`：原始平均识别率（含异常值）
- `total_records_filtered`：排除异常值后的记录数
- `avg_rate_filtered_pct`：排除异常值后的平均识别率（**推荐使用**）
- `median_rate_filtered_pct`：排除异常值后的中位数识别率
- `abnormal_count`：异常值记录数（识别率 >120%）
- `abnormal_ratio`：异常值记录占比

**使用建议**：
- 使用 `avg_rate_filtered_pct` 作为核心考核指标
- 使用 `median_rate_filtered_pct` 作为参考指标
- 关注 `abnormal_ratio`，异常值占比过高说明数据质量问题严重

---

## 查询 2：AI 区域识别率分布

**目的**：按识别率区间统计分布情况

```sql
-- 查询2: AI 区域识别率分布（按识别率区间）
WITH rate_distribution AS (
    SELECT
        CASE
            WHEN ratio < 0.3 THEN '<30%'
            WHEN ratio < 0.5 THEN '30%-50%'
            WHEN ratio < 0.7 THEN '50%-70%'
            WHEN ratio < 0.9 THEN '70%-90%'
            ELSE '>=90%'
        END AS rate_range,
        COUNT(*) AS record_count,
        SUM(value) AS total_ai_count,
        SUM(cattle_count) AS total_real_count
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
    GROUP BY rate_range
)
SELECT
    rate_range,
    record_count,
    ROUND(100.0 * record_count / SUM(record_count) OVER (), 2) AS record_pct,
    total_ai_count,
    total_real_count,
    ROUND(100.0 * total_ai_count / NULLIF(total_real_count, 0), 2) AS actual_rate
FROM rate_distribution
ORDER BY
    CASE rate_range
        WHEN '<30%' THEN 1
        WHEN '30%-50%' THEN 2
        WHEN '50%-70%' THEN 3
        WHEN '70%-90%' THEN 4
        WHEN '>=90%' THEN 5
    END;
```

**预期结果**：
- `rate_range`：识别率区间
- `record_count`：该区间的记录数
- `record_pct`：该区间记录的占比
- `total_ai_count`：该区间 AI 识别的总牛只数
- `total_real_count`：该区间真实牛只的总数
- `actual_rate`：该区间的实际识别率

---

## 查询 3：按牧场统计 AI 识别率

**目的**：对比各牧场的 AI 识别情况

```sql
-- 查询3: 按牧场统计 AI 识别率
WITH ranch_ai_stats AS (
    SELECT
        tenant_id AS ranch_id,
        COUNT(*) AS total_records,
        COUNT(DISTINCT region_id) AS unique_regions,
        ROUND(AVG(ratio), 4) AS avg_recognition_rate,
        ROUND(MIN(ratio), 4) AS min_recognition_rate,
        ROUND(MAX(ratio), 4) AS max_recognition_rate,
        SUM(value) AS total_ai_count,
        SUM(cattle_count) AS total_real_count,
        ROUND(100.0 * SUM(value) / NULLIF(SUM(cattle_count), 0), 2) AS overall_rate,
        COUNT(CASE WHEN ratio < 0.5 THEN 1 END) AS low_rate_count,
        ROUND(100.0 * COUNT(CASE WHEN ratio < 0.5 THEN 1 END) / NULLIF(COUNT(*), 0), 2) AS low_rate_pct
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
    GROUP BY tenant_id
)
SELECT
    ranch_id,
    total_records,
    unique_regions,
    avg_recognition_rate,
    min_recognition_rate,
    max_recognition_rate,
    total_ai_count,
    total_real_count,
    overall_rate,
    low_rate_count,
    low_rate_pct
FROM ranch_ai_stats
ORDER BY overall_rate DESC;
```

**预期结果**：
- `ranch_id`：牧场 ID
- `total_records`：该牧场的识别记录数
- `unique_regions`：该牧场的区域数
- `avg_recognition_rate`：平均识别率
- `min_recognition_rate` / `max_recognition_rate`：最低/最高识别率
- `overall_rate`：整体识别率（AI 识别总数 / 真实牛只总数）
- `low_rate_count` / `low_rate_pct`：低识别率记录数和占比

---

## 查询 4：按区域统计 AI 识别率

**目的**：识别识别率最低的区域

```sql
-- 查询4: 按区域统计 AI 识别率（识别率最低的10个区域）
SELECT
    region_id,
    region_name,
    COUNT(*) AS record_count,
    ROUND(AVG(ratio), 4) AS avg_recognition_rate,
    ROUND(MIN(ratio), 4) AS min_recognition_rate,
    ROUND(MAX(ratio), 4) AS max_recognition_rate,
    SUM(value) AS total_ai_count,
    SUM(cattle_count) AS total_real_count,
    ROUND(100.0 * SUM(value) / NULLIF(SUM(cattle_count), 0), 2) AS overall_rate
FROM ods_psi_region_ai_data
WHERE value IS NOT NULL
  AND cattle_count IS NOT NULL
  AND cattle_count > 0
GROUP BY region_id, region_name
HAVING COUNT(*) >= 3  -- 至少3次记录
ORDER BY overall_rate ASC
LIMIT 10;
```

**预期结果**：
- `region_id`：区域 ID
- `region_name`：区域名称
- `record_count`：该区域的识别记录数
- `avg_recognition_rate`：平均识别率
- `overall_rate`：整体识别率

---

## 查询 5：AI 识别告警情况

**目的**：统计告警记录的情况

```sql
-- 查询5: AI 识别告警情况
SELECT
    alert_status,
    CASE
        WHEN alert_status = 0 THEN '正常'
        WHEN alert_status = 1 THEN '告警'
        ELSE '未知'
    END AS status_name,
    COUNT(*) AS record_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
    ROUND(AVG(ratio), 4) AS avg_ratio
FROM ods_psi_region_ai_data
WHERE value IS NOT NULL
  AND cattle_count IS NOT NULL
  AND cattle_count > 0
GROUP BY alert_status
ORDER BY alert_status;
```

**预期结果**：
- `alert_status`：告警状态（0=正常，1=告警）
- `status_name`：状态名称
- `record_count`：该状态的记录数
- `pct`：该状态的占比
- `avg_ratio`：该状态的平均识别率

---

## 查询 6：牛只体重测量覆盖率分析

**目的**：统计有称重记录的牛只数量 vs 总在栏牛只数量

```sql
-- 查询6: 牛只体重测量覆盖率分析
WITH weighted_cattle AS (
    SELECT DISTINCT code AS cattle_code
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
),
onstall_cattle AS (
    -- 获取最新在栏状态的牛只
    SELECT DISTINCT code AS cattle_code
    FROM ods_ranch_onstall_history
    WHERE code IS NOT NULL
)
SELECT
    COUNT(DISTINCT o.cattle_code) AS onstall_cattle_count,
    COUNT(DISTINCT w.cattle_code) AS weighted_cattle_count,
    ROUND(100.0 * COUNT(DISTINCT w.cattle_code) / NULLIF(COUNT(DISTINCT o.cattle_code), 0), 2) AS weight_coverage_rate
FROM onstall_cattle o
LEFT JOIN weighted_cattle w ON o.cattle_code = w.cattle_code;
```

**预期结果**：
- `onstall_cattle_count`：在栏牛只数量
- `weighted_cattle_count`：有称重记录的牛只数量
- `weight_coverage_rate`：称重覆盖率（百分比）

---

## 查询 7：牛只称重频次分布

**目的**：统计每头牛的称重次数分布

```sql
-- 查询7: 牛只称重频次分布
WITH cattle_weight_count AS (
    SELECT
        code AS cattle_code,
        COUNT(*) AS weight_count
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
    GROUP BY code
),
weight_distribution AS (
    SELECT
        weight_count,
        COUNT(*) AS cattle_count
    FROM cattle_weight_count
    GROUP BY weight_count
    ORDER BY weight_count
)
SELECT
    weight_count,
    cattle_count,
    ROUND(100.0 * cattle_count / SUM(cattle_count) OVER (), 2) AS percentage
FROM weight_distribution
ORDER BY weight_count
LIMIT 10;
```

**预期结果**：
- `weight_count`：称重次数
- `cattle_count`：对应称重次数的牛只数量
- `percentage`：占比（百分比）

---

## 查询 8：牛只称重月龄覆盖率分析

**目的**：统计各生长阶段的称重记录覆盖情况

```sql
-- 查询8: 牛只称重月龄覆盖率分析
WITH cattle_age_coverage AS (
    SELECT
        code AS cattle_code,
        weight_day_age AS day_age,
        ROW_NUMBER() OVER (PARTITION BY code ORDER BY weight_date) AS rn
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
      AND weight_day_age IS NOT NULL
),
age_distribution AS (
    SELECT
        CASE
            WHEN day_age < 100 THEN '0-99天(慢生期)'
            WHEN day_age BETWEEN 100 AND 300 THEN '100-300天(猛长期)'
            WHEN day_age > 300 THEN '300天以上(稳生期)'
        END AS age_range,
        COUNT(DISTINCT cattle_code) AS cattle_count
    FROM cattle_age_coverage
    WHERE rn = 1  -- 每头牛只统计一次
    GROUP BY age_range
),
total_cattle_count AS (
    SELECT COUNT(DISTINCT code) AS cnt
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
)
SELECT
    a.age_range,
    a.cattle_count,
    t.cnt AS total_cattle_count,
    ROUND(100.0 * a.cattle_count / NULLIF(t.cnt, 0), 2) AS coverage_percentage
FROM age_distribution a
CROSS JOIN total_cattle_count t
ORDER BY
    CASE a.age_range
        WHEN '0-99天(慢生期)' THEN 1
        WHEN '100-300天(猛长期)' THEN 2
        WHEN '300天以上(稳生期)' THEN 3
    END;
```

**预期结果**：
- `age_range`：生长阶段
- `cattle_count`：该阶段有称重记录的牛只数量
- `total_cattle_count`：总称重牛只数量
- `coverage_percentage`：覆盖率（百分比）

---

## 查询 9：入栏体重与首次日常称重差异分析

**目的**：分析入栏体重与首次日常称重体重的差异情况

```sql
-- 查询9: 入栏体重与首次日常称重差异分析
WITH install_weights AS (
    SELECT
        code AS cattle_code,
        CAST(weight AS DOUBLE) AS install_weight,
        install_date
    FROM ods_ranch_install
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
),
first_daily_weights AS (
    SELECT
        code AS cattle_code,
        MIN(weight_date) AS first_weight_date,
        FIRST_VALUE(CAST(weight AS DOUBLE)) OVER (PARTITION BY code ORDER BY weight_date) AS first_daily_weight
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
    GROUP BY code, weight, weight_date
),
weight_diff AS (
    SELECT
        i.cattle_code,
        i.install_weight,
        f.first_daily_weight,
        f.first_weight_date,
        i.install_date,
        DATEDIFF('day', i.install_date, f.first_weight_date) AS days_diff,
        ABS(f.first_daily_weight - i.install_weight) AS weight_diff,
        ABS(f.first_daily_weight - i.install_weight) / NULLIF(i.install_weight, 0) * 100 AS weight_diff_pct
    FROM install_weights i
    INNER JOIN first_daily_weights f ON i.cattle_code = f.cattle_code
    WHERE f.first_weight_date > i.install_date  -- 首次日常称重在入栏之后
)
SELECT
    COUNT(*) AS total_cattle_count,
    ROUND(AVG(weight_diff), 2) AS avg_weight_diff,
    ROUND(MAX(weight_diff), 2) AS max_weight_diff,
    ROUND(AVG(weight_diff_pct), 2) AS avg_weight_diff_pct,
    ROUND(MAX(weight_diff_pct), 2) AS max_weight_diff_pct,
    ROUND(AVG(days_diff), 2) AS avg_days_diff,
    COUNT(CASE WHEN weight_diff > 10 THEN 1 END) AS large_diff_count,
    ROUND(100.0 * COUNT(CASE WHEN weight_diff > 10 THEN 1 END) / NULLIF(COUNT(*), 0), 2) AS large_diff_pct
FROM weight_diff;
```

**预期结果**：
- `total_cattle_count`：对比牛只数量
- `avg_weight_diff`：平均体重差异（kg）
- `max_weight_diff`：最大体重差异（kg）
- `avg_weight_diff_pct`：平均差异比例（百分比）
- `max_weight_diff_pct`：最大差异比例（百分比）
- `avg_days_diff`：平均称重间隔天数
- `large_diff_count`：差异 >10kg 的牛只数量
- `large_diff_pct`：差异 >10kg 的牛只占比（百分比）

---

## 查询 10：各牧场数据采集质量对比

**目的**：对比各牧场的称重覆盖率、AI 牛只盘点率和平均称重次数

**✅ 重要更新（2026-04-20）**：
- 新增AI牛只盘点率指标
- 使用中位数识别率替代平均识别率
- 添加牧场名称显示

```sql
-- 查询10: 各牧场数据采集质量对比（含AI盘点率）
WITH ranch_inventory_check AS (
    -- AI 牛只盘点率统计
    SELECT
        tenant_id AS ranch_id,
        COUNT(*) AS ai_check_records,
        COUNT(DISTINCT date) AS ai_check_days,
        ROUND(APPROX_QUANTILE(ratio, 0.5), 4) AS median_ai_check_rate,
        COUNT(CASE WHEN ratio >= 0.9 THEN 1 END) AS qualified_records,
        ROUND(100.0 * COUNT(CASE WHEN ratio >= 0.9 THEN 1 END) / COUNT(*), 2) AS qualified_rate
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
      AND ratio <= 1.2  -- 排除极端异常值
    GROUP BY tenant_id
),
ranch_weight AS (
    SELECT DISTINCT
        i.tenant_id AS ranch_id,
        i.code AS cattle_code
    FROM ods_ranch_install i
    WHERE i.code IS NOT NULL
),
ranch_weight_detail AS (
    SELECT
        w.ranch_id,
        w.cattle_code,
        COUNT(*) AS total_weight_records
    FROM ranch_weight w
    INNER JOIN ods_psi_sample_weight sw ON w.cattle_code = sw.code
    WHERE CAST(sw.weight AS DOUBLE) > 0
    GROUP BY w.ranch_id, w.cattle_code
),
ranch_weight_agg AS (
    SELECT
        ranch_id,
        COUNT(DISTINCT cattle_code) AS weight_cattle_count,
        SUM(total_weight_records) AS total_weight_records
    FROM ranch_weight_detail
    GROUP BY ranch_id
),
ranch_onstall AS (
    SELECT
        tenant_id AS ranch_id,
        COUNT(DISTINCT code) AS onstall_cattle_count
    FROM ods_ranch_onstall_history
    WHERE code IS NOT NULL
    GROUP BY tenant_id
)
SELECT
    o.ranch_id,
    o.onstall_cattle_count,
    COALESCE(w.weight_cattle_count, 0) AS weight_cattle_count,
    ROUND(100.0 * COALESCE(w.weight_cattle_count, 0) / NULLIF(o.onstall_cattle_count, 0), 2) AS weight_coverage_rate,
    ROUND(1.0 * w.total_weight_records / NULLIF(w.weight_cattle_count, 0), 2) AS avg_weight_per_cattle,
    a.ai_check_records,
    a.ai_check_days,
    ROUND(a.median_ai_check_rate * 100, 2) AS median_ai_check_rate,
    ROUND(a.qualified_rate, 2) AS ai_qualified_rate
FROM ranch_onstall o
LEFT JOIN ranch_weight_agg w ON o.ranch_id = w.ranch_id
LEFT JOIN ranch_inventory_check a ON o.ranch_id = a.ranch_id
ORDER BY w.weight_cattle_count DESC
LIMIT 10;
```

**预期结果**：
- `ranch_id`：牧场 ID
- `onstall_cattle_count`：在栏牛只数量
- `weight_cattle_count`：称重牛只数量
- `weight_coverage_rate`：称重覆盖率（百分比）
- `avg_weight_per_cattle`：平均称重次数/牛
- `ai_check_records`：AI盘点记录数
- `ai_check_days`：AI盘点天数
- `median_ai_check_rate`：AI盘点中位数识别率（百分比）
- `ai_qualified_rate`：AI盘点合格率（识别率≥90%的记录占比）

---

## 补充查询 1：极端高识别率案例

**目的**：查看识别率异常高的案例（识别率 > 150%）

```sql
-- 补充查询1: 查看异常高识别率的情况（ratio > 1.5）
SELECT
    region_id,
    region_name,
    tenant_id,
    date,
    value AS ai_count,
    cattle_count AS real_count,
    ratio,
    CASE
        WHEN ratio > 2.0 THEN '严重异常(>200%)'
        WHEN ratio > 1.5 THEN '异常(>150%)'
        WHEN ratio > 1.2 THEN '偏高(>120%)'
        ELSE '正常'
    END AS abnormal_level
FROM ods_psi_region_ai_data
WHERE value IS NOT NULL
  AND cattle_count IS NOT NULL
  AND cattle_count > 0
  AND ratio > 1.5
ORDER BY ratio DESC
LIMIT 20;
```

---

## 补充查询 2：识别率为 0 的区域

**目的**：查看长期识别率为 0 的区域

```sql
-- 补充查询2: 查看识别率为0的情况
SELECT
    region_id,
    region_name,
    tenant_id,
    COUNT(*) AS zero_count,
    MIN(date) AS first_zero_date,
    MAX(date) AS last_zero_date,
    ROUND(AVG(cattle_count), 2) AS avg_real_count
FROM ods_psi_region_ai_data
WHERE value = 0
  AND cattle_count IS NOT NULL
  AND cattle_count > 0
GROUP BY region_id, region_name, tenant_id
HAVING COUNT(*) >= 5  -- 至少5次识别率为0
ORDER BY zero_count DESC
LIMIT 10;
```

---

## 补充查询 3：时间趋势分析

**目的**：查看最近 30 天的识别率趋势

```sql
-- 补充查询3: 时间趋势 - 最近30天的平均识别率
WITH daily_stats AS (
    SELECT
        CAST(date AS DATE) AS stat_date,
        COUNT(*) AS record_count,
        ROUND(AVG(ratio), 4) AS avg_ratio,
        ROUND(100.0 * COUNT(CASE WHEN ratio < 0.7 THEN 1 END) / COUNT(*), 2) AS below_70_pct
    FROM ods_psi_region_ai_data
    WHERE value IS NOT NULL
      AND cattle_count IS NOT NULL
      AND cattle_count > 0
      AND date >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY CAST(date AS DATE)
)
SELECT
    stat_date,
    record_count,
    avg_ratio,
    below_70_pct
FROM daily_stats
ORDER BY stat_date DESC
LIMIT 10;
```

---

## 补充查询 4：总体称重记录统计

**目的**：查看总体称重记录和日龄字段情况

```sql
-- 补充查询4: 总体称重记录统计
SELECT
    COUNT(DISTINCT code) AS unique_cattle_count,
    COUNT(*) AS total_weight_records,
    COUNT(DISTINCT CASE WHEN weight_day_age IS NOT NULL THEN code END) AS cattle_with_age,
    COUNT(CASE WHEN weight_day_age IS NOT NULL THEN 1 END) AS records_with_age
FROM ods_psi_sample_weight
WHERE code IS NOT NULL
  AND CAST(weight AS DOUBLE) > 0;
```

---

## 补充查询 5：入栏体重分布

**目的**：查看入栏体重的分布情况

```sql
-- 补充查询5: 入栏体重分布
SELECT
    COUNT(*) AS total_install_count,
    ROUND(AVG(CAST(weight AS DOUBLE)), 2) AS avg_install_weight,
    ROUND(MIN(CAST(weight AS DOUBLE)), 2) AS min_install_weight,
    ROUND(MAX(CAST(weight AS DOUBLE)), 2) AS max_install_weight,
    COUNT(CASE WHEN CAST(weight AS DOUBLE) > 500 THEN 1 END) AS weight_gt_500_count,
    ROUND(100.0 * COUNT(CASE WHEN CAST(weight AS DOUBLE) > 500 THEN 1 END) / COUNT(*), 2) AS weight_gt_500_pct
FROM ods_ranch_install
WHERE code IS NOT NULL
  AND CAST(weight AS DOUBLE) > 0;
```

---

## 补充查询 6：首次日常称重分布

**目的**：查看首次日常称重体重的分布情况

```sql
-- 补充查询6: 首次日常称重分布
WITH first_weights AS (
    SELECT
        code AS cattle_code,
        FIRST_VALUE(CAST(weight AS DOUBLE)) OVER (PARTITION BY code ORDER BY weight_date) AS first_weight,
        weight_date AS first_weight_date
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
    GROUP BY code, weight, weight_date
)
SELECT
    COUNT(*) AS total_cattle_count,
    ROUND(AVG(first_weight), 2) AS avg_first_weight,
    ROUND(MIN(first_weight), 2) AS min_first_weight,
    ROUND(MAX(first_weight), 2) AS max_first_weight,
    COUNT(CASE WHEN first_weight > 500 THEN 1 END) AS weight_gt_500_count,
    ROUND(100.0 * COUNT(CASE WHEN first_weight > 500 THEN 1 END) / COUNT(*), 2) AS weight_gt_500_pct
FROM first_weights;
```

---

## 补充查询 7：有日龄信息的牛只详细分析

**目的**：分析有日龄信息的牛只的详细情况

```sql
-- 补充查询7: 有日龄信息的牛只详细分析
WITH cattle_age_records AS (
    SELECT
        code AS cattle_code,
        weight_day_age AS day_age,
        weight,
        weight_date
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
      AND weight_day_age IS NOT NULL
),
cattle_age_stats AS (
    SELECT
        cattle_code,
        COUNT(*) AS record_count,
        MIN(day_age) AS min_age,
        MAX(day_age) AS max_age,
        MAX(day_age) - MIN(day_age) AS age_span
    FROM cattle_age_records
    GROUP BY cattle_code
)
SELECT
    COUNT(*) AS total_cattle_with_age,
    ROUND(AVG(record_count), 2) AS avg_records_per_cattle,
    ROUND(AVG(age_span), 2) AS avg_age_span,
    MIN(age_span) AS min_age_span,
    MAX(age_span) AS max_age_span
FROM cattle_age_stats;
```

---

## 查询 11：通过出生日期计算日龄分布（推荐）

**目的**：利用 `ods_ranch_onstall` 的 `birth_date` 字段，结合称重日期计算日龄，解决 `weight_day_age` 字段缺失问题

**注意**：完整查询请参考 `docs/通过出生日期计算日龄-补充查询.sql`

```sql
-- 查询11: 通过出生日期计算日龄分布
WITH cattle_birth AS (
    -- 获取牛只的出生日期
    SELECT
        id AS cattle_id,
        code AS cattle_code,
        birth_date
    FROM ods_ranch_onstall
    WHERE code IS NOT NULL
      AND birth_date IS NOT NULL
),
cattle_weight AS (
    -- 获取称重记录
    SELECT
        code AS cattle_code,
        weight_date,
        CAST(weight AS DOUBLE) AS weight
    FROM ods_psi_sample_weight
    WHERE code IS NOT NULL
      AND CAST(weight AS DOUBLE) > 0
),
cattle_age_calc AS (
    -- 计算日龄
    SELECT
        w.cattle_code,
        c.birth_date,
        w.weight_date,
        DATEDIFF('day', c.birth_date, w.weight_date) AS calculated_day_age,
        w.weight,
        ROW_NUMBER() OVER (PARTITION BY w.cattle_code ORDER BY w.weight_date) AS rn
    FROM cattle_weight w
    INNER JOIN cattle_birth c ON w.cattle_code = c.cattle_code
    WHERE w.weight_date >= c.birth_date  -- 称重日期必须大于等于出生日期
),
age_distribution AS (
    -- 按生长阶段统计（首次称重）
    SELECT
        CASE
            WHEN calculated_day_age < 0 THEN '<0天(异常)'
            WHEN calculated_day_age < 100 THEN '0-99天(慢生期)'
            WHEN calculated_day_age BETWEEN 100 AND 300 THEN '100-300天(猛长期)'
            WHEN calculated_day_age BETWEEN 300 AND 600 THEN '300-600天(稳生期)'
            ELSE '>600天(超期)'
        END AS age_range,
        COUNT(DISTINCT cattle_code) AS cattle_count,
        COUNT(*) AS record_count
    FROM cattle_age_calc
    WHERE rn = 1  -- 每头牛只统计一次（首次称重）
    GROUP BY age_range
),
total_stats AS (
    -- 总体统计
    SELECT
        COUNT(DISTINCT cattle_code) AS total_cattle,
        COUNT(*) AS total_records,
        ROUND(AVG(calculated_day_age), 2) AS avg_day_age,
        ROUND(MIN(calculated_day_age), 2) AS min_day_age,
        ROUND(MAX(calculated_day_age), 2) AS max_day_age
    FROM cattle_age_calc
)
SELECT
    a.age_range,
    a.cattle_count,
    t.total_cattle AS total_cattle_count,
    ROUND(100.0 * a.cattle_count / NULLIF(t.total_cattle, 0), 2) AS coverage_percentage,
    a.record_count,
    ROUND(100.0 * a.record_count / NULLIF(t.total_records, 0), 2) AS record_pct
FROM age_distribution a
CROSS JOIN total_stats t
ORDER BY
    CASE a.age_range
        WHEN '<0天(异常)' THEN 0
        WHEN '0-99天(慢生期)' THEN 1
        WHEN '100-300天(猛长期)' THEN 2
        WHEN '300-600天(稳生期)' THEN 3
        WHEN '>600天(超期)' THEN 4
    END;
```

**预期结果**：
- `age_range`：生长阶段（慢生期、猛长期、稳生期）
- `cattle_count`：该阶段有日龄计算的牛只数量
- `total_cattle_count`：总称重牛只数量
- `coverage_percentage`：覆盖率（百分比）
- `record_count`：该阶段的称重记录数
- `record_pct`：该阶段记录的占比

---

## 查询 12：总体出生日期覆盖率统计

**目的**：统计出生日期字段的覆盖情况，评估通过计算方式获取日龄的可行性

```sql
-- 查询12: 总体出生日期覆盖率统计
SELECT
    COUNT(DISTINCT c.cattle_code) AS total_cattle_with_birth,
    COUNT(DISTINCT w.cattle_code) AS total_cattle_with_weight,
    COUNT(DISTINCT a.cattle_code) AS total_cattle_with_age_calc,
    ROUND(100.0 * COUNT(DISTINCT a.cattle_code) / NULLIF(COUNT(DISTINCT w.cattle_code), 0), 2) AS birth_date_coverage_rate,
    ROUND(AVG(a.calculated_day_age), 2) AS avg_day_age,
    ROUND(MIN(a.calculated_day_age), 2) AS min_day_age,
    ROUND(MAX(a.calculated_day_age), 2) AS max_day_age
FROM ods_psi_sample_weight w
LEFT JOIN (
    SELECT id AS cattle_id, code AS cattle_code, birth_date
    FROM ods_ranch_onstall
    WHERE birth_date IS NOT NULL
) c ON w.code = c.cattle_code
LEFT JOIN (
    SELECT
        w.cattle_code,
        DATEDIFF('day', c.birth_date, w.weight_date) AS calculated_day_age
    FROM ods_psi_sample_weight w
    INNER JOIN (SELECT id, code, birth_date FROM ods_ranch_onstall WHERE birth_date IS NOT NULL) c ON w.code = c.cattle_code
    WHERE w.weight_date >= c.birth_date
      AND CAST(w.weight AS DOUBLE) > 0
) a ON w.code = a.cattle_code
WHERE w.code IS NOT NULL AND CAST(w.weight AS DOUBLE) > 0;
```

**预期结果**：
- `total_cattle_with_birth`：有出生日期的牛只数量
- `total_cattle_with_weight`：有称重记录的牛只数量
- `total_cattle_with_age_calc`：可计算日龄的牛只数量
- `birth_date_coverage_rate`：出生日期覆盖率（百分比）
- `avg_day_age` / `min_day_age` / `max_day_age`：日龄统计

---

## 查询 13：各牧场日龄覆盖情况对比

**目的**：对比各牧场的日龄覆盖情况，识别数据质量差的牧场

```sql
-- 查询13: 各牧场日龄覆盖情况对比
WITH ranch_age_stats AS (
    SELECT
        r.tenant_id AS ranch_id,
        COUNT(DISTINCT c.cattle_code) AS total_cattle_with_birth,
        COUNT(DISTINCT a.cattle_code) AS total_cattle_with_age,
        ROUND(AVG(a.calculated_day_age), 2) AS avg_day_age,
        ROUND(100.0 * COUNT(DISTINCT a.cattle_code) / NULLIF(COUNT(DISTINCT c.cattle_code), 0), 2) AS age_coverage_rate
    FROM ods_ranch_onstall r
    LEFT JOIN ods_psi_sample_weight w ON r.code = w.code
    LEFT JOIN (
        SELECT
            w.cattle_code,
            DATEDIFF('day', r.birth_date, w.weight_date) AS calculated_day_age
        FROM ods_psi_sample_weight w
        INNER JOIN ods_ranch_onstall r ON w.code = r.code
        WHERE r.birth_date IS NOT NULL
          AND w.weight_date >= r.birth_date
          AND CAST(w.weight AS DOUBLE) > 0
    ) a ON r.code = a.cattle_code
    WHERE r.birth_date IS NOT NULL
    GROUP BY r.tenant_id
)
SELECT
    ranch_id,
    total_cattle_with_birth,
    total_cattle_with_age,
    age_coverage_rate,
    avg_day_age
FROM ranch_age_stats
ORDER BY total_cattle_with_birth DESC
LIMIT 10;
```

**预期结果**：
- `ranch_id`：牧场 ID
- `total_cattle_with_birth`：该牧场有出生日期的牛只数量
- `total_cattle_with_age`：该牧场可计算日龄的牛只数量
- `age_coverage_rate`：日龄覆盖率（百分比）
- `avg_day_age`：平均日龄

---

## 查询 14：月龄覆盖密度分析（关键月龄段）

**目的**：按每30天一个统计单位，分析关键月龄段的覆盖密度（首次称重）

**✅ 验证结果（2026-04-20）**：
- 出生日期覆盖率：69.53%
- 0-30天（入栏时）：59.32% 的牛只
- 31-60天：1.98%
- 61-90天：3.96%
- 猛长期（100-300天）：19.01%

```sql
-- 查询14: 月龄覆盖密度分析（关键月龄段）
WITH age_calculation AS (
    SELECT
        w.code AS cattle_code,
        c.birth_date,
        w.weight_date,
        DATEDIFF('day', c.birth_date, w.weight_date) AS calculated_day_age,
        ROW_NUMBER() OVER (PARTITION BY w.code ORDER BY w.weight_date) AS rn
    FROM ods_psi_sample_weight w
    INNER JOIN ods_ranch_onstall c ON w.code = c.code
    WHERE c.birth_date IS NOT NULL
      AND w.weight_date >= c.birth_date
      AND CAST(w.weight AS DOUBLE) > 0
),
age_ranges AS (
    SELECT
        calculated_day_age,
        cattle_code,
        CASE
            WHEN calculated_day_age BETWEEN 0 AND 30 THEN '0-30天(0-1月)'
            WHEN calculated_day_age BETWEEN 31 AND 60 THEN '31-60天(1-2月)'
            WHEN calculated_day_age BETWEEN 61 AND 90 THEN '61-90天(2-3月)'
            WHEN calculated_day_age BETWEEN 91 AND 120 THEN '91-120天(3-4月)'
            WHEN calculated_day_age BETWEEN 121 AND 150 THEN '121-150天(4-5月)'
            WHEN calculated_day_age BETWEEN 151 AND 180 THEN '151-180天(5-6月)'
            WHEN calculated_day_age BETWEEN 181 AND 210 THEN '181-210天(6-7月)'
            WHEN calculated_day_age BETWEEN 211 AND 240 THEN '211-240天(7-8月)'
            WHEN calculated_day_age BETWEEN 241 AND 270 THEN '241-270天(8-9月)'
            WHEN calculated_day_age BETWEEN 271 AND 300 THEN '271-300天(9-10月)'
            WHEN calculated_day_age BETWEEN 301 AND 360 THEN '301-360天(10-12月)'
            WHEN calculated_day_age > 360 THEN '360天以上(12月+)'
            ELSE '<0天(异常)'
        END AS age_range,
        rn
    FROM age_calculation
    WHERE calculated_day_age >= 0
),
range_distribution AS (
    SELECT
        age_range,
        COUNT(DISTINCT cattle_code) AS unique_cattle_count,
        COUNT(*) AS total_records,
        ROUND(AVG(calculated_day_age), 2) AS avg_day_age
    FROM age_ranges
    WHERE rn = 1  -- 首次称重
    GROUP BY age_range
),
total_stats AS (
    SELECT COUNT(DISTINCT cattle_code) AS total_cattle
    FROM age_ranges
    WHERE rn = 1 AND calculated_day_age >= 0
)
SELECT
    r.age_range,
    r.unique_cattle_count,
    t.total_cattle AS total_cattle_count,
    ROUND(100.0 * r.unique_cattle_count / NULLIF(t.total_cattle, 0), 2) AS coverage_percentage,
    r.total_records,
    r.avg_day_age
FROM range_distribution r
CROSS JOIN total_stats t
ORDER BY
    CASE r.age_range
        WHEN '0-30天(0-1月)' THEN 1
        WHEN '31-60天(1-2月)' THEN 2
        WHEN '61-90天(2-3月)' THEN 3
        WHEN '91-120天(3-4月)' THEN 4
        WHEN '121-150天(4-5月)' THEN 5
        WHEN '151-180天(5-6月)' THEN 6
        WHEN '181-210天(6-7月)' THEN 7
        WHEN '211-240天(7-8月)' THEN 8
        WHEN '241-270天(8-9月)' THEN 9
        WHEN '271-300天(9-10月)' THEN 10
        WHEN '301-360天(10-12月)' THEN 11
        WHEN '360天以上(12月+)' THEN 12
        ELSE 0
    END;
```

**预期结果**：
- `age_range`：月龄段
- `unique_cattle_count`：该月龄段的牛只数量
- `total_cattle_count`：总牛只数量
- `coverage_percentage`：覆盖率（百分比）
- `total_records`：称重记录数
- `avg_day_age`：平均日龄

---

## 查询 15：极端异常值检测

**目的**：识别需要清洗的极端异常值

```sql
-- 查询15: 极端异常值检测
WITH age_calculation AS (
    SELECT
        w.code AS cattle_code,
        w.tenant_id AS ranch_id,
        c.birth_date,
        w.weight_date,
        DATEDIFF('day', c.birth_date, w.weight_date) AS calculated_day_age,
        CAST(w.weight AS DOUBLE) AS weight
    FROM ods_psi_sample_weight w
    INNER JOIN ods_ranch_onstall c ON w.code = c.code
    WHERE c.birth_date IS NOT NULL
      AND w.weight_date >= c.birth_date
      AND CAST(w.weight AS DOUBLE) > 0
),
abnormal_values AS (
    SELECT
        cattle_code,
        ranch_id,
        birth_date,
        weight_date,
        calculated_day_age,
        weight,
        CASE
            WHEN calculated_day_age > 2000 THEN '日龄异常(>2000天)'
            WHEN calculated_day_age < 0 THEN '日龄异常(<0天)'
            WHEN weight > 1000 THEN '体重异常(>1000kg)'
            WHEN weight < 0 THEN '体重异常(<0kg)'
            ELSE '正常'
        END AS abnormal_type
    FROM age_calculation
)
SELECT
    abnormal_type,
    COUNT(DISTINCT cattle_code) AS unique_cattle_count,
    COUNT(*) AS total_records,
    ROUND(AVG(calculated_day_age), 2) AS avg_day_age,
    ROUND(MIN(calculated_day_age), 2) AS min_day_age,
    ROUND(MAX(calculated_day_age), 2) AS max_day_age,
    ROUND(AVG(weight), 2) AS avg_weight,
    ROUND(MIN(weight), 2) AS min_weight,
    ROUND(MAX(weight), 2) AS max_weight
FROM abnormal_values
WHERE abnormal_type != '正常'
GROUP BY abnormal_type
ORDER BY total_records DESC;
```

**预期结果**：
- 识别出日龄 >2000天、体重 >1000kg 的异常记录
- 用于数据清洗

---

## 查询 16：数据清洗SQL（删除极端异常值）

**目的**：删除极端异常值，提升数据质量

**⚠️ 警告**：此查询会删除数据，请在测试环境验证后，在生产环境谨慎使用！

```sql
-- 查询16: 数据清洗（删除极端异常值）
-- ⚠️ 警告：此操作会删除数据，请先备份！

-- 查看将被删除的记录
SELECT
    COUNT(*) AS records_to_delete,
    '删除条件：weight > 1000 OR calculated_day_age > 2000' AS delete_condition
FROM ods_psi_sample_weight w
INNER JOIN ods_ranch_onstall c ON w.code = c.code
WHERE CAST(w.weight AS DOUBLE) > 1000
   OR DATEDIFF('day', c.birth_date, w.weight_date) > 2000;

-- 执行删除（谨慎使用！）
-- DELETE FROM ods_psi_sample_weight
-- WHERE code IN (
--     SELECT w.code
--     FROM ods_psi_sample_weight w
--     INNER JOIN ods_ranch_onstall c ON w.code = c.code
--     WHERE CAST(w.weight AS DOUBLE) > 1000
--        OR DATEDIFF('day', c.birth_date, w.weight_date) > 2000
-- );
```

---

## 查询 17：日龄数据质量综合评分

**目的**：评估各牧场的日龄数据质量，识别需要改进的牧场

```sql
-- 查询17: 日龄数据质量综合评分
WITH ranch_stats AS (
    SELECT
        w.tenant_id AS ranch_id,
        COUNT(DISTINCT w.code) AS total_cattle_with_weight,
        COUNT(DISTINCT CASE WHEN c.birth_date IS NOT NULL THEN w.code END) AS cattle_with_birth_date,
        COUNT(DISTINCT CASE
            WHEN c.birth_date IS NOT NULL
              AND w.weight_date >= c.birth_date
              AND DATEDIFF('day', c.birth_date, w.weight_date) BETWEEN 0 AND 2000
            THEN w.code
        END) AS cattle_with_valid_age,
        ROUND(AVG(CASE
            WHEN c.birth_date IS NOT NULL
              AND w.weight_date >= c.birth_date
            THEN DATEDIFF('day', c.birth_date, w.weight_date)
        END), 2) AS avg_day_age
    FROM ods_psi_sample_weight w
    LEFT JOIN ods_ranch_onstall c ON w.code = c.code
    WHERE w.code IS NOT NULL
      AND CAST(w.weight AS DOUBLE) > 0
    GROUP BY w.tenant_id
)
SELECT
    ranch_id,
    total_cattle_with_weight,
    cattle_with_birth_date,
    cattle_with_valid_age,
    ROUND(100.0 * cattle_with_birth_date / NULLIF(total_cattle_with_weight, 0), 2) AS birth_date_coverage_rate,
    ROUND(100.0 * cattle_with_valid_age / NULLIF(total_cattle_with_weight, 0), 2) AS valid_age_coverage_rate,
    avg_day_age,
    -- 数据质量评分（0-100分）
    ROUND(
        50.0 * (cattle_with_birth_date::DOUBLE / NULLIF(total_cattle_with_weight, 0)) +
        50.0 * (cattle_with_valid_age::DOUBLE / NULLIF(total_cattle_with_weight, 0))
    , 2) AS quality_score,
    CASE
        WHEN ROUND(50.0 * (cattle_with_birth_date::DOUBLE / NULLIF(total_cattle_with_weight, 0)) + 50.0 * (cattle_with_valid_age::DOUBLE / NULLIF(total_cattle_with_weight, 0)), 2) >= 80 THEN '优秀'
        WHEN ROUND(50.0 * (cattle_with_birth_date::DOUBLE / NULLIF(total_cattle_with_weight, 0)) + 50.0 * (cattle_with_valid_age::DOUBLE / NULLIF(total_cattle_with_weight, 0)), 2) >= 60 THEN '良好'
        WHEN ROUND(50.0 * (cattle_with_birth_date::DOUBLE / NULLIF(total_cattle_with_weight, 0)) + 50.0 * (cattle_with_valid_age::DOUBLE / NULLIF(total_cattle_with_weight, 0)), 2) >= 40 THEN '及格'
        ELSE '不及格'
    END AS quality_grade
FROM ranch_stats
ORDER BY quality_score DESC, total_cattle_with_weight DESC;
```

**预期结果**：
- 各牧场的日龄数据质量评分（0-100分）
- 数据质量等级（优秀/良好/及格/不及格）
- 识别需要改进的牧场

---

## 运行说明

### DuckDB 命令行运行

```bash
duckdb dev.duckdb < 查询文件.sql
```

### Python 运行

```python
import duckdb

# 连接到数据库
conn = duckdb.connect('dev.duckdb')

# 运行查询
result = conn.execute("""
    -- 在此粘贴 SQL 查询
""").fetchdf()

# 打印结果
print(result)

# 关闭连接
conn.close()
```

### 自动化脚本运行（推荐）

```bash
# 运行完整的月龄测重覆盖率分析
python3 scripts/analyze_monthly_age_coverage.py

# 该脚本会自动运行所有查询并生成 CSV 报告
```

### 注意事项

1. 所有查询均基于 ODS 原始数据层，可直接在生产环境运行
2. 查询 1-10 为主查询，用于生成报告的核心数据
3. 补充查询 1-7 为辅助查询，用于更详细的数据分析
4. **✅ 查询 11-17 为新增查询**，通过出生日期计算日龄（已验证，推荐使用）
5. 运行前请确认已连接到正确的数据库（dev.duckdb）
6. 如遇到性能问题，可以添加 LIMIT 子句限制返回行数
7. ⚠️ **重要**：运行查询 11-17 前请先关闭 DBeaver 等数据库连接工具，避免文件锁定
8. ⚠️ **警告**：查询 16 会删除数据，请先备份并在测试环境验证后使用

---

**文档版本**：v4.0
**更新日期**：2026-04-20
**更新内容**：
- ✅ 新增查询 11-17，通过出生日期计算日龄（已验证）
- ✅ 新增月龄覆盖密度分析、极端异常值检测、数据清洗SQL
- ✅ 新增日龄数据质量综合评分查询
- ✅ 更新实际验证数据：日龄数据可用性从 0.06% → 69.53%（提升 1,159 倍）
- 修正 AI 识别率计算，排除极端异常值
- 新增 Python 自动化脚本：`scripts/analyze_monthly_age_coverage.py`
- 新增补充查询文件 `docs/通过出生日期计算日龄-补充查询.sql`
**维护者**：数据科学团队
