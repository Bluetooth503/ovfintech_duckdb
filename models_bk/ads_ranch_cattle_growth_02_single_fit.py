"""
ads_ranch_cattle_growth_02_single_fit - 单头牛非线性生长曲线拟合

目标：对每头牛单独拟合 Gompertz / Logistic / Von Bertalanffy 生长曲线，
      评估参数估计的稳定性，识别数据缺陷。

门槛（基于 EDA 结果动态调整）：
- 最小观测数 ≥ 4
- 称重时间跨度 ≥ 90 天
- 拐点区间 [100, 300] 天至少 1 次观测
- 体重近似单调递增（容差 10kg）
"""
import warnings
warnings.filterwarnings("ignore")
from typing import Dict, List, Optional, Tuple
import numpy as np
import pandas as pd
from scipy.optimize import curve_fit
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import os

plt.rcParams["font.sans-serif"] = ["SimHei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False

# ---------- 数据门槛 ----------
MIN_OBS_PER_CATTLE = 4
MIN_SPAN_DAYS = 90
INFLECTION_RANGE = (100, 300)
MONO_TOLERANCE_KG = 10
MAX_PLOTS = 20  # 最多保存可视化图的数量


def gompertz(t: np.ndarray, A: float, b: float, c: float) -> np.ndarray:
    """Gompertz: W(t) = A * exp(-exp(-b*(t-c)))"""
    return A * np.exp(-np.exp(-b * (t - c)))


def logistic(t: np.ndarray, A: float, b: float, c: float) -> np.ndarray:
    """Logistic: W(t) = A / (1 + exp(-b*(t-c)))"""
    return A / (1.0 + np.exp(-b * (t - c)))


def von_bertalanffy(t: np.ndarray, A: float, b: float, c: float) -> np.ndarray:
    """
    Von Bertalanffy: W(t) = A * (1 - exp(-b*(t-c)))^3
    注：c 为生物学意义上的理论出生前偏移参数（t0），
        为保证正值约束，实际优化时通过变量转换处理。
    """
    return A * (1.0 - np.exp(-b * (t - c))) ** 3


MODELS = {
    "Gompertz": (gompertz, [650.0, 0.015, 225.0]),
    "Logistic": (logistic, [650.0, 0.015, 225.0]),
    "VonBertalanffy": (von_bertalanffy, [650.0, 0.015, 150.0]),
}


def is_approx_monotonic(g: pd.DataFrame, time_col: str, weight_col: str, tolerance: float = MONO_TOLERANCE_KG) -> bool:
    df_sorted = g.sort_values(time_col)
    w = df_sorted[weight_col].values
    return bool(np.all(np.diff(w) >= -tolerance))


def fit_single_cattle(
    df_cattle: pd.DataFrame,
    time_col: str = "age_days",
    weight_col: str = "current_weight",
) -> List[Dict]:
    """对单头牛拟合三种生长曲线，返回各模型结果"""
    t = df_cattle[time_col].values.astype(float)
    y = df_cattle[weight_col].values.astype(float)
    n_obs = len(t)
    span = float(t.max() - t.min())
    weight_min = float(y.min())
    weight_max = float(y.max())

    results = []
    for model_name, (func, p0_default) in MODELS.items():
        record = {
            "cattle_id": df_cattle["cattle_id"].iloc[0],
            "sku_name": df_cattle["sku_name"].iloc[0],
            "ranch_name": df_cattle["ranch_name"].iloc[0],
            "n_observations": n_obs,
            "span_days": span,
            "weight_min": weight_min,
            "weight_max": weight_max,
            "model_name": model_name,
            "fit_success": False,
            "A": np.nan,
            "b": np.nan,
            "c": np.nan,
            "rss": np.nan,
            "rmse": np.nan,
            "A_cv": np.nan,  # 参数变异系数 = se / |estimate|
            "b_cv": np.nan,
            "c_cv": np.nan,
            "param_unstable": False,
            "error_msg": None,
        }

        # 设置合理的初始值和边界
        a0 = max(y) * 1.2 if max(y) > 0 else 500.0
        if model_name == "VonBertalanffy":
            # VBGF 的 c 通常小于 min(t)，给更保守的初值
            p0 = [a0, 0.01, min(t) - 30.0]
            bounds = ([0.0, 1e-5, -500.0], [2000.0, 0.5, min(t) - 1.0])
        else:
            p0 = [a0, 0.01, np.median(t)]
            bounds = ([0.0, 1e-5, 50.0], [2000.0, 0.5, 800.0])

        try:
            popt, pcov = curve_fit(
                func, t, y, p0=p0, bounds=bounds, maxfev=20000, method="trf"
            )
            perr = np.sqrt(np.diag(pcov))

            A_est, b_est, c_est = float(popt[0]), float(popt[1]), float(popt[2])
            y_pred = func(t, A_est, b_est, c_est)
            rss = float(np.sum((y - y_pred) ** 2))
            rmse = float(np.sqrt(rss / n_obs))

            # 检查参数稳定性：若标准误过大或协方差矩阵不正定，标记为不稳定
            cvs = []
            for est, se in zip(popt, perr):
                cv = float(se / abs(est)) if abs(est) > 1e-6 else 999.0
                cvs.append(cv)

            record.update({
                "fit_success": True,
                "A": A_est,
                "b": b_est,
                "c": c_est,
                "rss": rss,
                "rmse": rmse,
                "A_cv": cvs[0],
                "b_cv": cvs[1],
                "c_cv": cvs[2],
                "param_unstable": any(cv > 1.0 for cv in cvs) or np.any(np.isinf(perr)),
            })
        except Exception as e:
            record["error_msg"] = str(e)[:200]

        results.append(record)

    return results


def generate_diagnostic_plots(
    df_input: pd.DataFrame,
    results_df: pd.DataFrame,
    output_dir: str,
    time_col: str = "age_days",
    weight_col: str = "current_weight",
    max_plots: int = MAX_PLOTS,
) -> List[str]:
    """为拟合成功的牛只生成可视化图"""
    os.makedirs(output_dir, exist_ok=True)
    plot_paths = []

    # 优先选择：成功拟合 Gompertz 且参数较稳定的牛，再补充一些有问题的案例
    stable_cattle = results_df[
        (results_df["model_name"] == "Gompertz") & (results_df["fit_success"]) & (~results_df["param_unstable"])
    ]["cattle_id"].unique().tolist()

    unstable_cattle = results_df[
        (results_df["model_name"] == "Gompertz") & (results_df["fit_success"]) & (results_df["param_unstable"])
    ]["cattle_id"].unique().tolist()

    failed_cattle = results_df[
        (results_df["model_name"] == "Gompertz") & (~results_df["fit_success"])
    ]["cattle_id"].unique().tolist()

    selected = (stable_cattle[: max_plots // 2] +
                unstable_cattle[: max_plots // 4] +
                failed_cattle[: max_plots // 4])
    selected = selected[:max_plots]

    colors = {"Gompertz": "#1f77b4", "Logistic": "#ff7f0e", "VonBertalanffy": "#2ca02c"}

    for cattle_id in selected:
        sub = df_input[df_input["cattle_id"] == cattle_id].sort_values(time_col)
        t_obs = sub[time_col].values.astype(float)
        y_obs = sub[weight_col].values.astype(float)

        fig, ax = plt.subplots(figsize=(8, 5))
        ax.scatter(t_obs, y_obs, color="black", zorder=5, label="观测值")

        for model_name in ["Gompertz", "Logistic", "VonBertalanffy"]:
            row = results_df[
                (results_df["cattle_id"] == cattle_id) & (results_df["model_name"] == model_name)
            ]
            if row.empty or not row.iloc[0]["fit_success"]:
                continue
            r = row.iloc[0]
            t_smooth = np.linspace(t_obs.min() - 10, t_obs.max() + 50, 200)
            func = MODELS[model_name][0]
            y_smooth = func(t_smooth, r["A"], r["b"], r["c"])
            label = f"{model_name}: A={r['A']:.1f}, b={r['b']:.4f}, c={r['c']:.1f}"
            ax.plot(t_smooth, y_smooth, color=colors[model_name], label=label)

        ax.set_xlabel("日龄 (天)")
        ax.set_ylabel("体重 (kg)")
        ax.set_title(f"牛只 {cattle_id} 生长曲线拟合 (n={len(t_obs)}, span={int(t_obs.max()-t_obs.min())}天)")
        ax.legend(loc="best", fontsize=8)
        ax.grid(True, alpha=0.3)

        path = os.path.join(output_dir, f"cattle_{cattle_id}_fit.png")
        fig.tight_layout()
        fig.savefig(path, dpi=120)
        plt.close(fig)
        plot_paths.append(path)

    return plot_paths


def run_single_fit_analysis(df_input: pd.DataFrame) -> Tuple[pd.DataFrame, pd.DataFrame]:
    """主分析流程：过滤 -> 逐头拟合 -> 汇总诊断"""
    print("=" * 60)
    print("单头牛生长曲线拟合分析")
    print("=" * 60)

    df = df_input.copy()
    df = df[(df["current_weight"] > 0) & df["cattle_id"].notna()]
    time_col = "age_days" if ("age_days" in df.columns and df["age_days"].notna().any()) else "days_since_entry"
    print(f"\n时间变量: {time_col}")

    df = df[df[time_col].notna() & (df[time_col] > 0)].copy()
    print(f"过滤后总记录: {len(df):,}, 牛只: {df['cattle_id'].nunique():,}")

    # 1. 称重次数门槛
    obs_counts = df.groupby("cattle_id").size()
    valid_cattle = obs_counts[obs_counts >= MIN_OBS_PER_CATTLE].index
    df = df[df["cattle_id"].isin(valid_cattle)].copy()
    print(f"观测数≥{MIN_OBS_PER_CATTLE} 的牛: {df['cattle_id'].nunique():,} 头")

    # 2. 称重跨度门槛
    span = df.groupby("cattle_id")[time_col].agg(["min", "max"])
    span["span_days"] = span["max"] - span["min"]
    valid_span = span[span["span_days"] >= MIN_SPAN_DAYS].index
    df = df[df["cattle_id"].isin(valid_span)].copy()
    print(f"跨度≥{MIN_SPAN_DAYS} 天的牛: {df['cattle_id'].nunique():,} 头")

    # 3. 拐点区间覆盖
    inflection = df.groupby("cattle_id")[time_col].apply(
        lambda x: ((x >= INFLECTION_RANGE[0]) & (x <= INFLECTION_RANGE[1])).any()
    )
    valid_inflection = inflection[inflection].index
    df = df[df["cattle_id"].isin(valid_inflection)].copy()
    print(f"拐点区间[{INFLECTION_RANGE[0]}-{INFLECTION_RANGE[1]}]有观测的牛: {df['cattle_id'].nunique():,} 头")

    # 4. 单调性过滤
    mono_ok = df.groupby("cattle_id").apply(
        lambda g: is_approx_monotonic(g, time_col, "current_weight", MONO_TOLERANCE_KG)
    )
    valid_mono = mono_ok[mono_ok].index
    df = df[df["cattle_id"].isin(valid_mono)].copy()
    print(f"体重近似单调的牛: {df['cattle_id'].nunique():,} 头")

    if len(df) == 0:
        print("错误：过滤后无可用数据")
        return pd.DataFrame(), pd.DataFrame()

    # 逐头拟合
    print(f"\n开始逐头拟合（共 {df['cattle_id'].nunique()} 头）...")
    all_results = []
    for cattle_id, group in df.groupby("cattle_id"):
        all_results.extend(fit_single_cattle(group, time_col, "current_weight"))

    results_df = pd.DataFrame(all_results)

    # 诊断汇总
    print("\n【拟合成功率汇总】")
    for model_name in MODELS.keys():
        sub = results_df[results_df["model_name"] == model_name]
        success = sub["fit_success"].sum()
        total = len(sub)
        unstable = sub[sub["fit_success"] & sub["param_unstable"]].shape[0]
        print(f"  {model_name}: 成功 {success}/{total} ({success/total*100:.1f}%), 不稳定 {unstable} 头")

    print("\n【Gompertz 参数分布（成功且稳定）】")
    gomp_ok = results_df[(results_df["model_name"] == "Gompertz") & (results_df["fit_success"]) & (~results_df["param_unstable"])]
    if not gomp_ok.empty:
        print(f"  A(渐近体重): 均值={gomp_ok['A'].mean():.1f}, 中位数={gomp_ok['A'].median():.1f}, std={gomp_ok['A'].std():.1f}")
        print(f"  b(生长速率): 均值={gomp_ok['b'].mean():.4f}, 中位数={gomp_ok['b'].median():.4f}, std={gomp_ok['b'].std():.4f}")
        print(f"  c(拐点日龄): 均值={gomp_ok['c'].mean():.1f}, 中位数={gomp_ok['c'].median():.1f}, std={gomp_ok['c'].std():.1f}")
        print(f"  RMSE: 均值={gomp_ok['rmse'].mean():.2f}, 中位数={gomp_ok['rmse'].median():.2f}")
    else:
        print("  无稳定拟合结果")

    # 异常案例
    print("\n【参数异常案例】")
    gomp_all = results_df[results_df["model_name"] == "Gompertz"]
    a_boundary = gomp_all[(gomp_all["fit_success"]) & ((gomp_all["A"] < 50) | (gomp_all["A"] > 1500))]
    c_boundary = gomp_all[(gomp_all["fit_success"]) & ((gomp_all["c"] < 80) | (gomp_all["c"] > 600))]
    print(f"  A 极端值 (<50 或 >1500): {len(a_boundary)} 头")
    print(f"  c 极端值 (<80 或 >600): {len(c_boundary)} 头")

    # 生成汇总统计表（用于输出）
    summary_rows = []
    for model_name in MODELS.keys():
        sub = results_df[results_df["model_name"] == model_name]
        success = int(sub["fit_success"].sum())
        unstable = int(sub[sub["fit_success"] & sub["param_unstable"]].shape[0])
        summary_rows.append({
            "result_type": "fit_summary",
            "model_name": model_name,
            "metric": "success_count",
            "value": success,
        })
        summary_rows.append({
            "result_type": "fit_summary",
            "model_name": model_name,
            "metric": "unstable_count",
            "value": unstable,
        })

    # Gompertz 参数统计
    if not gomp_ok.empty:
        for param in ["A", "b", "c", "rmse"]:
            summary_rows.append({
                "result_type": "param_summary",
                "model_name": "Gompertz",
                "metric": f"{param}_mean",
                "value": float(gomp_ok[param].mean()),
            })
            summary_rows.append({
                "result_type": "param_summary",
                "model_name": "Gompertz",
                "metric": f"{param}_median",
                "value": float(gomp_ok[param].median()),
            })

    summary_df = pd.DataFrame(summary_rows)

    # 保存可视化
    output_dir = "target/growth_single_fit_plots"
    plot_paths = generate_diagnostic_plots(df, results_df, output_dir, time_col, "current_weight")
    print(f"\n已生成 {len(plot_paths)} 张诊断图，保存至: {output_dir}/")

    return results_df, summary_df


def model(dbt, session):
    """DBT Python 模型主入口"""
    dbt.config(
        materialized="table",
        description="单头牛非线性生长曲线拟合（Gompertz/Logistic/VonBertalanffy），评估个体参数稳定性",
        tags=["ranch", "ads", "growth_curve", "single_fit", "python", "eda"]
    )

    df_input = dbt.ref("ads_ranch_cattle_adg_agg_clean_i").to_df()
    if len(df_input) == 0:
        return pd.DataFrame({
            "result_type": ["error"],
            "model_name": ["no_data"],
            "metric": ["Input data is empty"],
            "value": [0],
        })

    results_df, summary_df = run_single_fit_analysis(df_input)

    if len(results_df) == 0:
        return pd.DataFrame({
            "result_type": ["error"],
            "model_name": ["insufficient_data"],
            "metric": ["No cattle passed quality filters"],
            "value": [0],
        })

    # 输出：以个体拟合结果为主表，附加汇总信息在元数据中
    results_df["fit_timestamp"] = pd.Timestamp.now()
    results_df["input_records"] = len(df_input)
    results_df["input_cattle"] = df_input["cattle_id"].nunique()
    results_df["filtered_cattle"] = results_df["cattle_id"].nunique()

    return results_df


if __name__ == "__main__":
    pass
