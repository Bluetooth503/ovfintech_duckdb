"""
========================================
模型名称：ads_ranch_cattle_growth_curve_fit_result_i
模型描述：牧场牛只生长曲线非线性拟合结果（Gompertz / Logistic / Brody）
作者：dbt
创建时间：2026-04-02
说明：
  - 基于 dws_ranch_cattle_adg_agg_i 的 age_days + current_weight 进行拟合
  - 使用 dbt-duckdb Python 模型运行，通过 DuckDB 读取上游数据并回写结果
  - 返回每头牛三种模型的参数、R²、RMSE、AIC，并标记最优模型（AIC最小）
========================================
"""
import warnings
from typing import Dict, List

import numpy as np
import pandas as pd
from scipy.optimize import curve_fit

warnings.filterwarnings("ignore")

# --------------------------------------------------------------------------------
# 入参配置
# --------------------------------------------------------------------------------
UPSTREAM_MODEL = "dws_ranch_cattle_adg_agg_i"  # 上游数据来源模型
X_COL = "age_days"                             # 自变量：日龄
Y_COL = "current_weight"                       # 因变量：当前体重
GROUP_COL = "cattle_id"                        # 分组列：牛只ID
MIN_POINTS = 5                                 # 单头牛最小观测点数
MAXFEV = 10000                                 # curve_fit 最大迭代次数
PARAM_COLUMNS = ["param_a", "param_b", "param_c", "param_w0", "param_k"]  # 输出参数列
OUTPUT_COLUMNS = ["cattle_id", "model", "success", "n_obs", "r2", "rmse", "aic", "is_best_model", "error"] + PARAM_COLUMNS


def _gompertz(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    """Gompertz 模型: W(t) = A * exp(-exp(-B * (t - C)))"""
    return A * np.exp(-np.exp(-B * (t - C)))


def _logistic(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    """Logistic 模型: W(t) = A / (1 + exp(-B * (t - C)))"""
    return A / (1 + np.exp(-B * (t - C)))


def _brody(t: np.ndarray, A: float, W0: float, k: float) -> np.ndarray:
    """Brody 模型: W(t) = A - (A - W0) * exp(-k * t)"""
    return A - (A - W0) * np.exp(-k * t)


_MODEL_SPECS = {
    "Gompertz": {"func": _gompertz, "p0_func": lambda t, y: [float(max(y)) * 1.2, 0.01, float(np.median(t))], "param_names": ["A", "B", "C"], "bounds": ([0.0, 0.0, -np.inf], [np.inf, np.inf, np.inf])},
    "Logistic": {"func": _logistic, "p0_func": lambda t, y: [float(max(y)) * 1.2, 0.01, float(np.median(t))], "param_names": ["A", "B", "C"], "bounds": ([0.0, 0.0, -np.inf], [np.inf, np.inf, np.inf])},
    "Brody": {"func": _brody, "p0_func": lambda t, y: [float(max(y)) * 1.2, float(y[0]) if y[0] > 0 else 20.0, 0.01], "param_names": ["A", "W0", "k"], "bounds": ([0.0, 0.0, 0.0], [np.inf, np.inf, np.inf])},
}


def _compute_metrics(y_true: np.ndarray, y_pred: np.ndarray, n_params: int) -> Dict[str, float]:
    """计算 R2, RMSE, AIC"""
    n = len(y_true)
    ss_res = float(np.sum((y_true - y_pred) ** 2))
    ss_tot = float(np.sum((y_true - np.mean(y_true)) ** 2))
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 1e-12 else np.nan
    rmse = np.sqrt(ss_res / n)
    aic = n * np.log(ss_res / n) + 2 * n_params if ss_res > 1e-12 else np.inf
    return {"r2": r2, "rmse": rmse, "aic": aic}


def _fit_model(t: np.ndarray, y: np.ndarray, model_name: str) -> Dict:
    """拟合单个模型并返回参数和评估指标"""
    spec = _MODEL_SPECS[model_name]
    func, p0, bounds, param_names = spec["func"], spec["p0_func"](t, y), spec.get("bounds", (-np.inf, np.inf)), spec["param_names"]
    result = {"model": model_name, "success": False, "params": {}, "r2": np.nan, "rmse": np.nan, "aic": np.nan, "error": None}
    try:
        popt, _ = curve_fit(func, t, y, p0=p0, bounds=bounds, maxfev=MAXFEV)
        y_pred = func(t, *popt)
        metrics = _compute_metrics(y, y_pred, len(param_names))
        result.update({"success": True, "params": dict(zip(param_names, [float(v) for v in popt])), **metrics})
    except Exception as e:
        result["error"] = str(e)
    return result


def _fit_single_cattle(df_cattle: pd.DataFrame) -> List[Dict]:
    """对单头牛的数据进行三种模型拟合"""
    df = df_cattle[[X_COL, Y_COL]].dropna().sort_values(X_COL)
    if len(df) < MIN_POINTS:
        return []
    t = df[X_COL].values.astype(float)
    y = df[Y_COL].values.astype(float)
    mask = (t >= 0) & (y > 0)
    if mask.sum() < MIN_POINTS:
        return []
    t, y = t[mask], y[mask]
    cattle_id = str(df_cattle["cattle_id"].iloc[0])
    return [_fit_model(t, y, name) | {"cattle_id": cattle_id, "n_obs": int(len(t))} for name in _MODEL_SPECS.keys()]


def model(dbt, session):
    dbt.config(materialized="table", description="牧场牛只生长曲线非线性拟合结果", tags=["ranch", "ads", "growth_curve", "python", "curve_fitting"])

    df = dbt.ref("dws_ranch_cattle_adg_agg_i").to_df()

    all_records = [rec for _, g in df.groupby(GROUP_COL, sort=False) for rec in _fit_single_cattle(g)]

    if not all_records:
        return pd.DataFrame(columns=OUTPUT_COLUMNS)

    rows = []
    for rec in all_records:
        row = {"cattle_id": rec["cattle_id"], "model": rec["model"], "success": rec["success"], "n_obs": rec["n_obs"], "r2": rec["r2"], "rmse": rec["rmse"], "aic": rec["aic"], "is_best_model": False, "error": rec.get("error")}
        row.update({f"param_{k.lower()}": v for k, v in rec.get("params", {}).items()})
        rows.append(row)

    df_result = pd.DataFrame(rows)
    for col in PARAM_COLUMNS:
        if col not in df_result.columns:
            df_result[col] = np.nan

    best_idx = df_result[df_result["success"] == True].groupby("cattle_id")["aic"].idxmin()
    if not best_idx.empty:
        df_result.loc[best_idx.values, "is_best_model"] = True

    return df_result
