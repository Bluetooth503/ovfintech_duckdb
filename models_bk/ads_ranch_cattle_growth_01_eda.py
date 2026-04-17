"""
ads_ranch_cattle_growth_01_eda - 肉牛生长数据质量探索性分析 (EDA)

用途：在建立 Gompertz / NLME 模型之前，系统性地检查称重数据质量，
      识别数据缺陷和建模风险。

核心检查项：
1. 数据规模与字段完整性
2. 每头牛称重次数分布
3. 称重时间跨度（日龄覆盖）
4. 称重间隔合理性
5. 体重单调性（异常跳点/下降）
6. 拐点区间（100-300天）覆盖度
7. 品种/牧场数据分层质量
"""
import warnings
warnings.filterwarnings("ignore")
from typing import Dict, Optional, Tuple
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# 设置中文字体（如果需要保存图片）
plt.rcParams['font.sans-serif'] = ['SimHei', 'DejaVu Sans']
plt.rcParams['axes.unicode_minus'] = False

# ---------- 建模常用门槛值（用于 EDA 统计） ----------
MIN_OBS_PER_CATTLE = 5          # 单头最小观测数
MIN_SPAN_DAYS = 150             # 最小称重跨度
INFLECTION_RANGE = (100, 300)   # 拐点优先区间
MONO_TOLERANCE_KG = 10          # 单调性容差


def _fmt_pct(n: int, total: int) -> str:
    if total == 0:
        return "0 (0.0%)"
    return f"{n} ({n/total*100:.1f}%)"


def analyze_cattle_observations(df: pd.DataFrame) -> pd.DataFrame:
    """分析每头牛的称重记录数"""
    obs_counts = df.groupby('cattle_id').size()
    bins = [1, 2, 3, 4, 5, 10, 20, 50, 100, float('inf')]
    labels = ['1', '2', '3', '4', '5-9', '10-19', '20-49', '50-99', '100+']
    dist = pd.cut(obs_counts, bins=bins, right=False, labels=labels).value_counts().sort_index()

    result = []
    total_cattle = len(obs_counts)
    for label, count in dist.items():
        result.append({
            'check_item': '称重次数分布',
            'category': str(label),
            'n_cattle': int(count),
            'pct': f"{count/total_cattle*100:.1f}%"
        })
    # 关键阈值统计
    for threshold in [3, 4, 5, 10]:
        n = int((obs_counts >= threshold).sum())
        result.append({
            'check_item': '称重次数≥阈值',
            'category': f'≥{threshold}次',
            'n_cattle': n,
            'pct': f"{n/total_cattle*100:.1f}%"
        })
    return pd.DataFrame(result)


def analyze_weight_span(df: pd.DataFrame, time_col: str = 'age_days') -> pd.DataFrame:
    """分析每头牛的称重时间跨度"""
    span = df.groupby('cattle_id')[time_col].agg(['min', 'max', 'count'])
    span['span_days'] = span['max'] - span['min']
    total = len(span)

    thresholds = [0, 30, 60, 90, 120, 150, 200, 300, 365]
    result = []
    for i in range(len(thresholds) - 1):
        lo, hi = thresholds[i], thresholds[i + 1]
        n = ((span['span_days'] >= lo) & (span['span_days'] < hi)).sum()
        result.append({
            'check_item': f'{time_col}_称重跨度分布',
            'category': f'{lo}-{hi-1}天',
            'n_cattle': int(n),
            'pct': f"{n/total*100:.1f}%"
        })
    n_max = (span['span_days'] >= 365).sum()
    result.append({
        'check_item': f'{time_col}_称重跨度分布',
        'category': '≥365天',
        'n_cattle': int(n_max),
        'pct': f"{n_max/total*100:.1f}%"
    })

    # 关键阈值
    for t in [30, 60, 90, 120, 150]:
        n = (span['span_days'] >= t).sum()
        result.append({
            'check_item': f'{time_col}_称重跨度≥阈值',
            'category': f'≥{t}天',
            'n_cattle': int(n),
            'pct': f"{n/total*100:.1f}%"
        })
    return pd.DataFrame(result)


def analyze_interval_days(df: pd.DataFrame, time_col: str = 'age_days') -> pd.DataFrame:
    """分析相邻两次称重的间隔天数"""
    df_sorted = df.sort_values([time_col, 'stats_date'])
    intervals = df_sorted.groupby('cattle_id')[time_col].diff().dropna()
    if len(intervals) == 0:
        return pd.DataFrame()

    result = []
    total_intervals = len(intervals)
    bins = [
        (0, 1), (1, 7), (7, 14), (14, 30), (30, 60),
        (60, 90), (90, 120), (120, 180), (180, 365), (365, float('inf'))
    ]
    for lo, hi in bins:
        if hi == float('inf'):
            n = (intervals >= lo).sum()
            label = f'≥{lo}天'
        else:
            n = ((intervals >= lo) & (intervals < hi)).sum()
            label = f'{lo}-{hi-1}天'
        result.append({
            'check_item': '称重间隔分布',
            'category': label,
            'n_intervals': int(n),
            'pct': f"{n/total_intervals*100:.1f}%"
        })
    result.append({
        'check_item': '称重间隔统计',
        'category': '均值',
        'n_intervals': float(intervals.mean()),
        'pct': '-'
    })
    result.append({
        'check_item': '称重间隔统计',
        'category': '中位数',
        'n_intervals': float(intervals.median()),
        'pct': '-'
    })
    return pd.DataFrame(result)


def analyze_monotonicity(df: pd.DataFrame, time_col: str = 'age_days', tolerance: float = MONO_TOLERANCE_KG) -> pd.DataFrame:
    """分析体重非单调递增的异常记录"""
    df_sorted = df.sort_values(time_col)
    result = []
    total_cattle = df['cattle_id'].nunique()

    # 严格单调
    strict_ok = []
    # 容差内单调
    approx_ok = []
    # 有问题
    problem_cattle = []

    for cattle_id, group in df_sorted.groupby('cattle_id'):
        w = group[time_col].values
        y = group['current_weight'].values
        # 按时间排序
        idx = np.argsort(w)
        y_sorted = y[idx]
        diffs = np.diff(y_sorted)
        if np.all(diffs >= 0):
            strict_ok.append(cattle_id)
        elif np.all(diffs >= -tolerance):
            approx_ok.append(cattle_id)
        else:
            problem_cattle.append(cattle_id)

    result.append({
        'check_item': '体重单调性',
        'category': '严格单调递增',
        'n_cattle': len(strict_ok),
        'pct': f"{len(strict_ok)/total_cattle*100:.1f}%"
    })
    result.append({
        'check_item': '体重单调性',
        'category': f'容差内单调(±{tolerance}kg)',
        'n_cattle': len(approx_ok),
        'pct': f"{len(approx_ok)/total_cattle*100:.1f}%"
    })
    result.append({
        'check_item': '体重单调性',
        'category': '存在异常下降',
        'n_cattle': len(problem_cattle),
        'pct': f"{len(problem_cattle)/total_cattle*100:.1f}%"
    })

    # 统计异常记录的下降幅度
    problem_records = []
    for cattle_id in problem_cattle:
        group = df_sorted[df_sorted['cattle_id'] == cattle_id].sort_values(time_col)
        w = group[time_col].values
        y = group['current_weight'].values
        idx = np.argsort(w)
        y_sorted = y[idx]
        diffs = np.diff(y_sorted)
        for d in diffs:
            if d < -tolerance:
                problem_records.append({'cattle_id': cattle_id, 'drop_kg': abs(d)})

    if problem_records:
        drop_df = pd.DataFrame(problem_records)
        result.append({
            'check_item': '异常下降统计',
            'category': '异常记录数',
            'n_cattle': len(drop_df),
            'pct': '-'
        })
        result.append({
            'check_item': '异常下降统计',
            'category': '最大下降(kg)',
            'n_cattle': float(drop_df['drop_kg'].max()),
            'pct': '-'
        })
        result.append({
            'check_item': '异常下降统计',
            'category': '平均下降(kg)',
            'n_cattle': float(drop_df['drop_kg'].mean()),
            'pct': '-'
        })
    return pd.DataFrame(result)


def analyze_inflection_coverage(df: pd.DataFrame, time_col: str = 'age_days') -> pd.DataFrame:
    """分析拐点区间覆盖度"""
    inf_lo, inf_hi = INFLECTION_RANGE
    total_cattle = df['cattle_id'].nunique()

    cattle_has_inflection = df.groupby('cattle_id')[time_col].apply(
        lambda x: ((x >= inf_lo) & (x <= inf_hi)).any()
    )
    n_has = int(cattle_has_inflection.sum())
    n_no = total_cattle - n_has

    # 进一步统计：在拐点区间内的称重记录数
    inf_records = df[(df[time_col] >= inf_lo) & (df[time_col] <= inf_hi)]
    inf_obs_per_cattle = inf_records.groupby('cattle_id').size()

    result = [
        {
            'check_item': '拐点区间覆盖',
            'category': f'[{inf_lo}-{inf_hi}天]有观测',
            'n_cattle': n_has,
            'pct': f"{n_has/total_cattle*100:.1f}%"
        },
        {
            'check_item': '拐点区间覆盖',
            'category': f'[{inf_lo}-{inf_hi}天]无观测',
            'n_cattle': n_no,
            'pct': f"{n_no/total_cattle*100:.1f}%"
        }
    ]

    # 有观测的牛中，有多少头至少有 N 次观测
    for min_obs in [1, 2, 3, 5]:
        n = int((inf_obs_per_cattle >= min_obs).sum())
        result.append({
            'check_item': '拐点区间称重次数',
            'category': f'≥{min_obs}次',
            'n_cattle': n,
            'pct': f"{n/total_cattle*100:.1f}%"
        })
    return pd.DataFrame(result)


def analyze_data_completeness(df: pd.DataFrame) -> pd.DataFrame:
    """分析各字段缺失率"""
    total = len(df)
    result = []
    for col in df.columns:
        missing = df[col].isna().sum()
        result.append({
            'check_item': '字段缺失率',
            'category': col,
            'n_missing': int(missing),
            'pct': f"{missing/total*100:.2f}%"
        })
    return pd.DataFrame(result)


def analyze_group_quality(df: pd.DataFrame) -> pd.DataFrame:
    """按品种×牧场组合分析数据质量"""
    df['sku_ranch'] = df['sku_name'].fillna('unknown') + ' x ' + df['ranch_name'].fillna('unknown')
    group_stats = df.groupby('sku_ranch').agg(
        n_cattle=('cattle_id', 'nunique'),
        n_obs=('cattle_id', 'size'),
        avg_obs_per_cattle=('cattle_id', lambda x: x.size / x.nunique()),
        min_age=('age_days', 'min'),
        max_age=('age_days', 'max'),
    ).reset_index()
    group_stats['span_days'] = group_stats['max_age'] - group_stats['min_age']

    total_groups = len(group_stats)
    result = []

    # 组合规模分布
    thresholds = [1, 10, 20, 50, 100]
    for i, t in enumerate(thresholds):
        if i == 0:
            n = (group_stats['n_cattle'] == t).sum()
            label = '1头'
        else:
            n = (group_stats['n_cattle'] >= t).sum()
            label = f'≥{t}头'
        result.append({
            'check_item': '品种×牧场组合规模',
            'category': label,
            'n_groups': int(n),
            'pct': f"{n/total_groups*100:.1f}%"
        })

    # 组合内平均观测数
    result.append({
        'check_item': '组合质量统计',
        'category': '组合平均牛只数',
        'n_groups': float(group_stats['n_cattle'].mean()),
        'pct': '-'
    })
    result.append({
        'check_item': '组合质量统计',
        'category': '组合平均记录数/头',
        'n_groups': float(group_stats['avg_obs_per_cattle'].mean()),
        'pct': '-'
    })
    result.append({
        'check_item': '组合质量统计',
        'category': '组合平均日龄跨度',
        'n_groups': float(group_stats['span_days'].mean()),
        'pct': '-'
    })

    return pd.DataFrame(result)


def analyze_model_readiness(df: pd.DataFrame, time_col: str = 'age_days') -> pd.DataFrame:
    """综合评估：满足各种建模门槛的牛只数量"""
    total_cattle = df['cattle_id'].nunique()

    # 基础统计
    obs_counts = df.groupby('cattle_id').size()
    span = df.groupby('cattle_id')[time_col].agg(['min', 'max'])
    span['span_days'] = span['max'] - span['min']
    inflection = df.groupby('cattle_id')[time_col].apply(
        lambda x: ((x >= INFLECTION_RANGE[0]) & (x <= INFLECTION_RANGE[1])).any()
    )

    # 单调性（容差10kg）
    df_sorted = df.sort_values(time_col)
    approx_ok = []
    for cattle_id, group in df_sorted.groupby('cattle_id'):
        w = group[time_col].values
        y = group['current_weight'].values
        idx = np.argsort(w)
        y_sorted = y[idx]
        if np.all(np.diff(y_sorted) >= -MONO_TOLERANCE_KG):
            approx_ok.append(cattle_id)
    mono_ok = set(approx_ok)

    result = []
    thresholds_obs = [3, 4, 5]
    thresholds_span = [60, 90, 120, 150]

    mono_series = pd.Series(
        {cid: cid in mono_ok for cid in obs_counts.index},
        dtype=bool
    )

    for obs_t in thresholds_obs:
        for span_t in thresholds_span:
            mask = (
                (obs_counts >= obs_t) &
                (span['span_days'] >= span_t) &
                inflection &
                mono_series.reindex(obs_counts.index).fillna(False)
            )
            n = mask.sum()
            result.append({
                'check_item': '建模 readiness 综合评估',
                'category': f'观测≥{obs_t}, 跨度≥{span_t}, 拐点覆盖, 单调',
                'n_cattle': int(n),
                'pct': f"{n/total_cattle*100:.1f}%"
            })
    return pd.DataFrame(result)


def run_eda(df_input: pd.DataFrame) -> pd.DataFrame:
    """主入口：运行全部 EDA 检查并返回汇总结果"""
    print("=" * 60)
    print("肉牛生长数据质量 EDA 报告")
    print("=" * 60)

    df = df_input.copy()
    df = df[(df['current_weight'] > 0) & df['cattle_id'].notna()]
    print(f"\n【数据概览】")
    print(f"  总记录数: {len(df):,}")
    print(f"  总牛只数: {df['cattle_id'].nunique():,}")
    print(f"  品种数: {df['sku_name'].nunique()}")
    print(f"  牧场数: {df['ranch_name'].nunique()}")
    print(f"  栏舍数: {df['stall_id'].nunique()}")
    print(f"  时间范围: {df['stats_date'].min()} ~ {df['stats_date'].max()}")

    # 确定时间变量
    if 'age_days' in df.columns and df['age_days'].notna().any():
        time_col = 'age_days'
        time_valid = df['age_days'].notna().sum()
        print(f"  时间变量: age_days (有效记录 {time_valid}/{len(df)})")
    elif 'days_since_entry' in df.columns and df['days_since_entry'].notna().any():
        time_col = 'days_since_entry'
        time_valid = df['days_since_entry'].notna().sum()
        print(f"  时间变量: days_since_entry (有效记录 {time_valid}/{len(df)})")
    else:
        print("  警告: 无有效时间变量")
        time_col = None

    df_time = df[df[time_col].notna() & (df[time_col] > 0)].copy() if time_col else df.copy()
    print(f"  过滤无效时间后: {len(df_time):,} 条记录")

    # 执行各项分析
    parts = []
    parts.append(analyze_data_completeness(df))
    parts.append(analyze_cattle_observations(df_time))
    if time_col:
        parts.append(analyze_weight_span(df_time, time_col))
        parts.append(analyze_interval_days(df_time, time_col))
        parts.append(analyze_monotonicity(df_time, time_col))
        parts.append(analyze_inflection_coverage(df_time, time_col))
    parts.append(analyze_group_quality(df_time))
    if time_col:
        parts.append(analyze_model_readiness(df_time, time_col))

    summary = pd.concat(parts, ignore_index=True)

    # 打印关键结论
    print("\n【关键结论摘要】")
    readiness = summary[summary['check_item'] == '建模 readiness 综合评估']
    for _, row in readiness.iterrows():
        print(f"  {row['category']}: {row['n_cattle']} 头 ({row['pct']})")

    return summary


def model(dbt, session):
    """DBT Python 模型主入口"""
    dbt.config(
        materialized="table",
        description="肉牛生长数据质量 EDA 报告",
        tags=["ranch", "ads", "eda", "growth_curve", "python", "data_quality"]
    )

    df_input = dbt.ref("dws_ranch_cattle_adg_agg_i").to_df()
    if len(df_input) == 0:
        return pd.DataFrame({'check_item': ['no_data'], 'category': ['error'], 'n_cattle': [0], 'pct': ['0%']})

    summary = run_eda(df_input)
    summary['eda_timestamp'] = pd.Timestamp.now()
    summary['input_records'] = len(df_input)
    summary['input_cattle'] = df_input['cattle_id'].nunique()
    return summary


# 允许本地直接运行调试
if __name__ == "__main__":
    # 示例：直接读取 CSV 调试（如果有导出数据的话）
    # df = pd.read_csv("/path/to/dws_ranch_cattle_adg_agg_i.csv")
    # summary = run_eda(df)
    # print(summary.to_string(index=False))
    pass
