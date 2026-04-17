"""
ads_ranch_cattle_growth_04_adg_panel_analysis - ADG 面板固定效应分析

目标：以 period_adg（区间日均增重）为因变量，构建固定效应面板模型，
      分析品种、牧场、季节、生长阶段对日增重的影响。

特点：
- 不依赖 S 型曲线假设，对稀疏数据更友好
- 每次称重都能产生一个 ADG 观测值，数据利用率高
- 结果直接对应业务关心的"日增重多少"
"""
import warnings
warnings.filterwarnings("ignore")
from typing import Dict, List, Optional
import numpy as np
import pandas as pd

# ---------- 数据过滤门槛 ----------
MIN_ADG = -2.0          # 允许小幅测量误差，但排除极端异常
MAX_ADG = 5.0           # 肉牛日增重上限约 4-5kg
MIN_WEIGHT = 30.0       # 最小体重门槛
MAX_WEIGHT = 1500.0     # 最大体重门槛


def prepare_panel_data(df_input: pd.DataFrame) -> Optional[pd.DataFrame]:
    """准备面板分析数据"""
    df = df_input.copy()

    # 核心字段检查
    required = ["cattle_id", "current_weight", "period_adg", "stats_date", "sku_name", "ranch_name"]
    for col in required:
        if col not in df.columns:
            print(f"错误：缺少必需字段 {col}")
            return None

    # 基础过滤
    df = df[df["cattle_id"].notna() & df["period_adg"].notna()].copy()
    df = df[(df["current_weight"] >= MIN_WEIGHT) & (df["current_weight"] <= MAX_WEIGHT)]
    df = df[(df["period_adg"] >= MIN_ADG) & (df["period_adg"] <= MAX_ADG)]

    if len(df) == 0:
        print("错误：过滤后无有效数据")
        return None

    # 时间变量
    time_col = "age_days" if ("age_days" in df.columns and df["age_days"].notna().any()) else "days_since_entry"
    if time_col in df.columns:
        df = df[df[time_col].notna() & (df[time_col] > 0)].copy()

    # 季节/月份
    df["stats_date"] = pd.to_datetime(df["stats_date"], errors="coerce")
    df["month"] = df["stats_date"].dt.month.astype("Int64")
    df["season"] = df["month"].map({
        12: "冬季", 1: "冬季", 2: "冬季",
        3: "春季", 4: "春季", 5: "春季",
        6: "夏季", 7: "夏季", 8: "夏季",
        9: "秋季", 10: "秋季", 11: "秋季",
    }).fillna("未知季节")

    # 生长阶段
    if "stage_name" in df.columns and df["stage_name"].notna().any():
        df["stage_name"] = df["stage_name"].fillna("unknown_stage").astype(str)
    else:
        df["stage_name"] = "unknown_stage"

    # 品种和牧场
    df["sku_name"] = df["sku_name"].fillna("unknown_sku").astype(str)
    df["ranch_name"] = df["ranch_name"].fillna("unknown_ranch").astype(str)

    print(f"面板数据准备完成: {len(df):,} 条记录, {df['cattle_id'].nunique():,} 头牛")
    return df


def fit_ols_panel(df: pd.DataFrame) -> pd.DataFrame:
    """使用 numpy 拟合 OLS 固定效应模型"""
    print("\n开始拟合 ADG 面板固定效应模型...")

    # 因变量
    y = df["period_adg"].values.astype(float)

    # 构建设计矩阵
    X_parts = [pd.DataFrame({"intercept": 1.0}, index=df.index)]

    # 1. 当前体重（控制变量）
    X_parts.append(pd.DataFrame({"current_weight": df["current_weight"].values.astype(float)}, index=df.index))

    # 2. 品种哑变量（以频次最高的为基准）
    sku_dummies = pd.get_dummies(df["sku_name"], prefix="sku", drop_first=False)
    # 将最多的品种设为基准组
    base_sku = sku_dummies.sum().idxmax()
    sku_dummies = sku_dummies.drop(columns=[base_sku])
    print(f"  品种维度: {len(sku_dummies.columns)} 个（基准: {base_sku.replace('sku_', '')}）")
    X_parts.append(sku_dummies.astype(int))

    # 3. 牧场哑变量
    ranch_dummies = pd.get_dummies(df["ranch_name"], prefix="ranch", drop_first=False)
    base_ranch = ranch_dummies.sum().idxmax()
    ranch_dummies = ranch_dummies.drop(columns=[base_ranch])
    print(f"  牧场维度: {len(ranch_dummies.columns)} 个（基准: {base_ranch.replace('ranch_', '')}）")
    X_parts.append(ranch_dummies.astype(int))

    # 4. 季节哑变量
    season_dummies = pd.get_dummies(df["season"], prefix="season", drop_first=False)
    base_season = "season_春季"
    if base_season in season_dummies.columns:
        season_dummies = season_dummies.drop(columns=[base_season])
    print(f"  季节维度: {len(season_dummies.columns)} 个（基准: 春季）")
    X_parts.append(season_dummies.astype(int))

    # 5. 生长阶段哑变量
    stage_dummies = pd.get_dummies(df["stage_name"], prefix="stage", drop_first=False)
    base_stage = stage_dummies.sum().idxmax()
    stage_dummies = stage_dummies.drop(columns=[base_stage])
    print(f"  生长阶段维度: {len(stage_dummies.columns)} 个（基准: {base_stage.replace('stage_', '')}）")
    X_parts.append(stage_dummies.astype(int))

    # 合并设计矩阵
    X = pd.concat(X_parts, axis=1)
    X_np = X.values.astype(float)

    # OLS 估计: beta = (X'X)^(-1) X'y
    XtX = X_np.T @ X_np
    Xty = X_np.T @ y

    try:
        beta = np.linalg.solve(XtX, Xty)
    except np.linalg.LinAlgError:
        print("警告: X'X 奇异，使用伪逆求解")
        beta = np.linalg.pinv(XtX) @ Xty

    # 残差和标准误
    y_pred = X_np @ beta
    residuals = y - y_pred
    n = len(y)
    k = len(beta)
    dof = n - k
    mse = np.sum(residuals ** 2) / dof if dof > 0 else np.nan

    # 参数协方差矩阵
    try:
        cov_beta = mse * np.linalg.inv(XtX)
        se_beta = np.sqrt(np.diag(cov_beta))
    except np.linalg.LinAlgError:
        cov_beta = mse * np.linalg.pinv(XtX)
        se_beta = np.sqrt(np.abs(np.diag(cov_beta)))

    t_stats = beta / (se_beta + 1e-12)
    p_values = 2 * (1 - np.minimum(1, np.abs(t_stats) / np.sqrt(dof + t_stats ** 2)))  # 近似 t 分布

    # R²
    ss_tot = np.sum((y - np.mean(y)) ** 2)
    ss_res = np.sum(residuals ** 2)
    r2 = 1 - ss_res / ss_tot if ss_tot > 1e-12 else np.nan
    adj_r2 = 1 - (ss_res / dof) / (ss_tot / (n - 1)) if dof > 0 and ss_tot > 1e-12 else np.nan

    print(f"\n【模型拟合优度】")
    print(f"  观测数 n={n:,}, 参数数 k={k}")
    print(f"  R² = {r2:.4f}, Adjusted R² = {adj_r2:.4f}")
    print(f"  RMSE = {np.sqrt(mse):.4f} kg/day")

    # 整理结果
    results = []
    for i, col in enumerate(X.columns):
        results.append({
            "result_type": "fixed_effect",
            "variable": col,
            "estimate": float(beta[i]),
            "std_error": float(se_beta[i]),
            "t_statistic": float(t_stats[i]),
            "p_value": float(p_values[i]),
            "significant_05": bool(p_values[i] < 0.05),
        })

    # 添加模型级汇总
    results.append({"result_type": "model_summary", "variable": "n_observations", "estimate": float(n), "std_error": np.nan, "t_statistic": np.nan, "p_value": np.nan, "significant_05": False})
    results.append({"result_type": "model_summary", "variable": "n_parameters", "estimate": float(k), "std_error": np.nan, "t_statistic": np.nan, "p_value": np.nan, "significant_05": False})
    results.append({"result_type": "model_summary", "variable": "r2", "estimate": float(r2), "std_error": np.nan, "t_statistic": np.nan, "p_value": np.nan, "significant_05": False})
    results.append({"result_type": "model_summary", "variable": "adjusted_r2", "estimate": float(adj_r2), "std_error": np.nan, "t_statistic": np.nan, "p_value": np.nan, "significant_05": False})
    results.append({"result_type": "model_summary", "variable": "rmse", "estimate": float(np.sqrt(mse)), "std_error": np.nan, "t_statistic": np.nan, "p_value": np.nan, "significant_05": False})

    # 打印显著变量
    sig_vars = [r for r in results if r["result_type"] == "fixed_effect" and r["significant_05"]]
    print(f"\n  显著变量数（p < 0.05）: {len(sig_vars)}/{len(X.columns)}")

    return pd.DataFrame(results)


def model(dbt, session):
    """DBT Python 模型主入口"""
    dbt.config(
        materialized="table",
        description="ADG 面板固定效应分析：品种、牧场、季节、生长阶段对日增重的影响",
        tags=["ranch", "ads", "adg", "panel", "fixed_effects", "python"]
    )

    df_input = dbt.ref("dws_ranch_cattle_adg_agg_i").to_df()
    if len(df_input) == 0:
        return pd.DataFrame({
            "result_type": ["error"],
            "variable": ["no_data"],
            "estimate": [0],
        })

    df = prepare_panel_data(df_input)
    if df is None or len(df) == 0:
        return pd.DataFrame({
            "result_type": ["error"],
            "variable": ["insufficient_data"],
            "estimate": [0],
        })

    results_df = fit_ols_panel(df)
    results_df["fit_timestamp"] = pd.Timestamp.now()
    results_df["input_records"] = len(df_input)
    results_df["input_cattle"] = df_input["cattle_id"].nunique()
    results_df["panel_records"] = len(df)
    results_df["panel_cattle"] = df["cattle_id"].nunique()

    return results_df


if __name__ == "__main__":
    pass
