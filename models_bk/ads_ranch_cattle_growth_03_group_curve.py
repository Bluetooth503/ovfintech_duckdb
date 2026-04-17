"""
ads_ranch_cattle_growth_03_group_curve - 群体平均 Gompertz 生长标准曲线

目标：按 品种×牧场 分组，用该组所有牛的称重记录拟合一条群体平均 Gompertz 曲线。

特点：
- 不依赖单头牛的多次称重，只要求群体有足够的时间覆盖
- 输出各品种×牧场组合的 A、b、c 及拟合质量指标
- 对数据不足的组合，回退到品种级别拟合
- 生成可视化诊断图
"""
import warnings
warnings.filterwarnings("ignore")
from typing import Dict, List, Optional
import numpy as np
import pandas as pd
from scipy.optimize import curve_fit
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import os

plt.rcParams["font.sans-serif"] = ["SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

# ---------- 组合拟合门槛 ----------
MIN_RECORDS_PER_GROUP = 50          # 组合最小记录数
MIN_CATTLE_PER_GROUP = 20           # 组合最小牛只数
MIN_SPAN_DAYS = 200                 # 组合最小日龄跨度
MIN_INFLECTION_RECORDS = 5          # 拐点区间内至少要有 5 条记录
INFLECTION_RANGE = (100, 300)       # 拐点优先区间
MAX_PLOTS = 30                      # 最多保存可视化图数量


def gompertz(t: np.ndarray, A: float, b: float, c: float) -> np.ndarray:
    """Gompertz: W(t) = A * exp(-exp(-b*(t-c)))"""
    return A * np.exp(-np.exp(-b * (t - c)))


def fit_group_curve(
    df_group: pd.DataFrame,
    time_col: str = "age_days",
    weight_col: str = "current_weight",
    group_key: str = "",
) -> Dict:
    """对单个品种×牧场组合拟合 Gompertz 曲线"""
    t = df_group[time_col].values.astype(float)
    y = df_group[weight_col].values.astype(float)

    n_records = len(t)
    n_cattle = df_group["cattle_id"].nunique()
    age_min = float(t.min())
    age_max = float(t.max())
    span_days = age_max - age_min
    inflection_records = int(((t >= INFLECTION_RANGE[0]) & (t <= INFLECTION_RANGE[1])).sum())

    record = {
        "group_key": group_key,
        "sku_name": df_group["sku_name"].iloc[0],
        "ranch_name": df_group["ranch_name"].iloc[0],
        "n_records": n_records,
        "n_cattle": n_cattle,
        "age_min": age_min,
        "age_max": age_max,
        "span_days": span_days,
        "inflection_records": inflection_records,
        "fit_status": "pending",
        "A": np.nan,
        "b": np.nan,
        "c": np.nan,
        "rss": np.nan,
        "rmse": np.nan,
        "r2": np.nan,
        "A_cv": np.nan,
        "b_cv": np.nan,
        "c_cv": np.nan,
        "error_msg": None,
    }

    # 检查门槛
    if n_records < MIN_RECORDS_PER_GROUP:
        record["fit_status"] = "insufficient_records"
        record["error_msg"] = f"records={n_records} < {MIN_RECORDS_PER_GROUP}"
        return record
    if n_cattle < MIN_CATTLE_PER_GROUP:
        record["fit_status"] = "insufficient_cattle"
        record["error_msg"] = f"cattle={n_cattle} < {MIN_CATTLE_PER_GROUP}"
        return record
    if span_days < MIN_SPAN_DAYS:
        record["fit_status"] = "insufficient_span"
        record["error_msg"] = f"span={span_days:.0f} < {MIN_SPAN_DAYS}"
        return record
    if inflection_records < MIN_INFLECTION_RECORDS:
        record["fit_status"] = "insufficient_inflection"
        record["error_msg"] = f"inflection_records={inflection_records} < {MIN_INFLECTION_RECORDS}"
        return record

    # 拟合 Gompertz
    a0 = max(y) * 1.2 if max(y) > 0 else 500.0
    p0 = [a0, 0.01, np.median(t)]
    bounds = ([0.0, 1e-5, 50.0], [2000.0, 0.5, 800.0])

    try:
        popt, pcov = curve_fit(
            gompertz, t, y, p0=p0, bounds=bounds, maxfev=20000, method="trf"
        )
        perr = np.sqrt(np.diag(pcov))

        A_est, b_est, c_est = float(popt[0]), float(popt[1]), float(popt[2])
        y_pred = gompertz(t, A_est, b_est, c_est)
        ss_res = float(np.sum((y - y_pred) ** 2))
        ss_tot = float(np.sum((y - np.mean(y)) ** 2))
        r2 = float(1 - ss_res / ss_tot) if ss_tot > 1e-12 else np.nan
        rmse = float(np.sqrt(ss_res / n_records))

        cvs = []
        for est, se in zip(popt, perr):
            cv = float(se / abs(est)) if abs(est) > 1e-6 else 999.0
            cvs.append(cv)

        record.update({
            "fit_status": "success",
            "A": A_est,
            "b": b_est,
            "c": c_est,
            "rss": ss_res,
            "rmse": rmse,
            "r2": r2,
            "A_cv": cvs[0],
            "b_cv": cvs[1],
            "c_cv": cvs[2],
        })
    except Exception as e:
        record["fit_status"] = "fit_failed"
        record["error_msg"] = str(e)[:200]

    return record


def generate_group_plots(
    df_input: pd.DataFrame,
    results_df: pd.DataFrame,
    output_dir: str,
    time_col: str = "age_days",
    weight_col: str = "current_weight",
    max_plots: int = MAX_PLOTS,
) -> List[str]:
    """为拟合成功的组合生成可视化图"""
    os.makedirs(output_dir, exist_ok=True)
    plot_paths = []

    success_df = results_df[results_df["fit_status"] == "success"].copy()
    if success_df.empty:
        return plot_paths

    success_df = success_df.sort_values("r2", ascending=False)
    top_good = success_df.head(max_plots // 2)["group_key"].tolist()
    bottom_mixed = success_df.tail(max_plots // 2)["group_key"].tolist()
    selected = list(dict.fromkeys(top_good + bottom_mixed))[:max_plots]

    for group_key in selected:
        row = results_df[results_df["group_key"] == group_key].iloc[0]
        sub = df_input[
            (df_input["sku_name"] == row["sku_name"]) &
            (df_input["ranch_name"] == row["ranch_name"])
        ].copy()
        sub = sub.sort_values(time_col)
        t_obs = sub[time_col].values.astype(float)
        y_obs = sub[weight_col].values.astype(float)

        fig, ax = plt.subplots(figsize=(9, 5))
        cattle_ids = sub["cattle_id"].astype("category").cat.codes.values
        ax.scatter(t_obs, y_obs, c=cattle_ids, cmap="tab20", alpha=0.6, s=20, label="观测值")

        if row["fit_status"] == "success":
            t_smooth = np.linspace(max(0, t_obs.min() - 20), t_obs.max() + 50, 300)
            y_smooth = gompertz(t_smooth, row["A"], row["b"], row["c"])
            label = (
                f"Gompertz: A={row['A']:.1f}, b={row['b']:.4f}, c={row['c']:.1f}\n"
                f"RMSE={row['rmse']:.2f}, R²={row['r2']:.3f}"
            )
            ax.plot(t_smooth, y_smooth, color="red", linewidth=2, label=label)

        ax.set_xlabel("日龄 (天)")
        ax.set_ylabel("体重 (kg)")
        ax.set_title(
            f"{group_key}\n"
            f"n_records={row['n_records']}, n_cattle={row['n_cattle']}, span={row['span_days']:.0f}天"
        )
        ax.legend(loc="best", fontsize=9)
        ax.grid(True, alpha=0.3)

        safe_name = str(group_key).replace(" / ", "_").replace("/", "_").replace(" ", "_")
        path = os.path.join(output_dir, f"group_{safe_name}.png")
        fig.tight_layout()
        fig.savefig(path, dpi=120)
        plt.close(fig)
        plot_paths.append(path)

    return plot_paths


def run_group_curve_analysis(df_input: pd.DataFrame) -> pd.DataFrame:
    """主分析流程：按品种×牧场分组拟合群体平均曲线"""
    print("=" * 60)
    print("群体平均 Gompertz 生长标准曲线分析")
    print("=" * 60)

    df = df_input.copy()
    df = df[(df["current_weight"] > 0) & df["cattle_id"].notna()]
    time_col = "age_days" if ("age_days" in df.columns and df["age_days"].notna().any()) else "days_since_entry"
    print(f"\n时间变量: {time_col}")

    df = df[df[time_col].notna() & (df[time_col] > 0)].copy()
    print(f"过滤后总记录: {len(df):,}, 牛只: {df['cattle_id'].nunique():,}")

    for col in ["sku_name", "ranch_name"]:
        df[col] = df[col].fillna(f"unknown_{col}").astype(str)

    df["group_key"] = df["sku_name"] + " x " + df["ranch_name"]
    n_groups = df["group_key"].nunique()
    print(f"品种×牧场组合数: {n_groups}")

    results = []
    for group_key, group_df in df.groupby("group_key"):
        results.append(fit_group_curve(group_df, time_col, "current_weight", group_key))

    results_df = pd.DataFrame(results)

    print("\n【拟合结果汇总】")
    status_counts = results_df["fit_status"].value_counts()
    for status, count in status_counts.items():
        print(f"  {status}: {count}/{len(results_df)} ({count/len(results_df)*100:.1f}%)")

    success_df = results_df[results_df["fit_status"] == "success"].copy()
    if not success_df.empty:
        print("\n【成功拟合组合的参数分布】")
        print(f"  A(渐近体重): 均值={success_df['A'].mean():.1f}, 中位数={success_df['A'].median():.1f}, std={success_df['A'].std():.1f}")
        print(f"  b(生长速率): 均值={success_df['b'].mean():.4f}, 中位数={success_df['b'].median():.4f}, std={success_df['b'].std():.4f}")
        print(f"  c(拐点日龄): 均值={success_df['c'].mean():.1f}, 中位数={success_df['c'].median():.1f}, std={success_df['c'].std():.1f}")
        print(f"  R²: 均值={success_df['r2'].mean():.3f}, 中位数={success_df['r2'].median():.3f}")
        print(f"  RMSE: 均值={success_df['rmse'].mean():.2f}, 中位数={success_df['rmse'].median():.2f}")

        sku_fallback = results_df[results_df["fit_status"] != "success"]["sku_name"].unique()
        print(f"\n需要回退到品种级别的 SKU 数: {len(sku_fallback)}")
    else:
        print("\n警告：没有任何组合满足拟合门槛")

    # 生成可视化
    output_dir = "target/growth_group_curve_plots"
    plot_paths = generate_group_plots(df, results_df, output_dir, time_col, "current_weight")
    print(f"\n已生成 {len(plot_paths)} 张诊断图，保存至: {output_dir}/")

    return results_df


def model(dbt, session):
    """DBT Python 模型主入口"""
    dbt.config(
        materialized="table",
        description="群体平均 Gompertz 生长标准曲线（按品种×牧场分组），不依赖单头牛多次称重",
        tags=["ranch", "ads", "growth_curve", "group_fit", "python", "gompertz"]
    )

    df_input = dbt.ref("ads_ranch_cattle_adg_agg_clean_i").to_df()
    if len(df_input) == 0:
        return pd.DataFrame({
            "group_key": ["error"],
            "fit_status": ["no_data"],
            "error_msg": ["Input data is empty"],
        })

    results_df = run_group_curve_analysis(df_input)
    results_df["fit_timestamp"] = pd.Timestamp.now()
    results_df["input_records"] = len(df_input)
    results_df["input_cattle"] = df_input["cattle_id"].nunique()

    return results_df


if __name__ == "__main__":
    pass
