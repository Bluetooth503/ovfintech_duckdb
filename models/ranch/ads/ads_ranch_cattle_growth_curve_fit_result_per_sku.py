"""
========================================
模型名称：ads_ranch_cattle_growth_curve_fit_result_per_sku
模型描述：牧场牛只生长曲线非线性拟合结果（群体曲线 + 个体校正）
作者：dbt
创建时间：2026-04-02
说明：
  - 基于 dws_ranch_cattle_adg_agg_i 的 age_days + current_weight 进行拟合
  - 采用群体曲线方案：按品种(sku_id)拟合群体曲线，个体只做简单校正
  - 解决单头牛称重次数不足(大部分<5次)无法单独拟合的问题
  - 返回每头牛的校正后参数、预测体重、生长阶段评估

【输出指标详解】

一、标识信息
  - cattle_id: 牛只唯一标识
  - sku_id: 品种ID
  - sku_name: 品种名称

二、群体曲线信息（品种级）
  - breed_model: 选中的生长模型名称（Gompertz/Logistic/Brody）
  - breed_n_obs: 参与品种拟合的数据点数量
  - breed_aic: 模型AIC值，越小表示拟合越好
  - breed_rmse: 品种级拟合的均方根误差（kg）

三、群体曲线参数（因模型而异）
  Gompertz/Logistic模型：
    - breed_param_a: 成熟体重渐近值（kg）
    - breed_param_b: 生长速率参数
    - breed_param_c: 拐点时间（日龄）
  Brody模型：
    - breed_param_a: 成熟体重渐近值（kg）
    - breed_param_w0: 初始体重（kg）
    - breed_param_k: 生长速率常数

四、个体校正信息
  - individual_n_obs: 该牛只的称重次数
  - individual_r2: 校正后的决定系数，越接近1表示个体拟合越好
  - individual_rmse: 个体拟合的均方根误差（kg）
  - correction_factor: 个体校正因子（实际/预测的中位数比值）
    * <1.0: 该牛生长慢于品种平均
    * =1.0: 该牛生长符合品种平均
    * >1.0: 该牛生长快于品种平均

五、个体观测范围
  - obs_age_min: 该牛最小称重日龄
  - obs_age_max: 该牛最大称重日龄
  - obs_weight_min: 该牛最小称重体重（kg）
  - obs_weight_max: 该牛最大称重体重（kg）

六、当前状态
  - current_age_days: 最新称重日龄
  - current_weight: 最新称重体重（kg）
  - current_stage: 当前生长阶段名称

七、可靠性评级
  - reliability: 数据可靠性评级
    * "高": 称重次数≥5，预测较可靠
    * "中": 称重次数3-4，预测有一定参考性
    * "低": 称重次数=2，预测仅供参考

八、未来体重预测（每行一个预测时点）
  - predict_target_age: 预测目标日龄
  - predict_target_weight: 预测的体重（kg）
  - predict_days_ahead: 距离现在还有几天
  默认预测：当前日龄+30/60/90/180天

九、元数据
  - dw_update_time: 数据更新时间

【使用建议】
  1. 生长异常监测：筛选 correction_factor < 0.85 或 > 1.15 的牛只
  2. 出栏时机预测：筛选 predict_target_weight >= 目标出栏重
  3. 数据质量筛查：筛选 reliability = '低' 的牛只增加称重频率
  4. 群体对比：按 sku_name 分组比较平均 correction_factor
========================================
"""
import warnings
from typing import Dict, List, Tuple

import numpy as np
import pandas as pd
from scipy.optimize import curve_fit

warnings.filterwarnings("ignore")

# --------------------------------------------------------------------------------
# 入参配置
# --------------------------------------------------------------------------------
UPSTREAM_MODEL = "dws_ranch_cattle_adg_agg_i"
X_COL = "age_days"
Y_COL = "current_weight"
SKU_COL = "sku_id"
SKU_NAME_COL = "sku_name"
CATTLE_COL = "cattle_id"
MIN_POINTS_PER_CATTLE = 2          # 单头牛最小观测点数（降低门槛）
MIN_POINTS_PER_BREED = 30          # 品种级拟合最小观测点数
MAXFEV = 10000

# Gompertz 模型: W(t) = A * exp(-exp(-B * (t - C)))
def _gompertz(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    return A * np.exp(-np.exp(-B * (t - C)))


# Logistic 模型: W(t) = A / (1 + exp(-B * (t - C)))
def _logistic(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    return A / (1 + np.exp(-B * (t - C)))


# Brody 模型: W(t) = A - (A - W0) * exp(-k * t)
def _brody(t: np.ndarray, A: float, W0: float, k: float) -> np.ndarray:
    return A - (A - W0) * np.exp(-k * t)


_MODEL_SPECS = {
    "Gompertz": {
        "func": _gompertz,
        "p0_func": lambda t, y: [float(max(y)) * 1.2, 0.01, float(np.median(t))],
        "param_names": ["A", "B", "C"],
        "bounds": ([0.0, 0.0, -np.inf], [np.inf, np.inf, np.inf])
    },
    "Logistic": {
        "func": _logistic,
        "p0_func": lambda t, y: [float(max(y)) * 1.2, 0.01, float(np.median(t))],
        "param_names": ["A", "B", "C"],
        "bounds": ([0.0, 0.0, -np.inf], [np.inf, np.inf, np.inf])
    },
    "Brody": {
        "func": _brody,
        "p0_func": lambda t, y: [float(max(y)) * 1.2, float(y[0]) if y[0] > 0 else 20.0, 0.01],
        "param_names": ["A", "W0", "k"],
        "bounds": ([0.0, 0.0, 0.0], [np.inf, np.inf, np.inf])
    },
}


def _fit_model(t: np.ndarray, y: np.ndarray, model_name: str) -> Dict:
    """拟合单个模型并返回参数"""
    spec = _MODEL_SPECS[model_name]
    func = spec["func"]
    p0 = spec["p0_func"](t, y)
    bounds = spec.get("bounds", (-np.inf, np.inf))
    param_names = spec["param_names"]

    result = {
        "model": model_name,
        "success": False,
        "params": {},
        "error": None
    }

    try:
        popt, _ = curve_fit(func, t, y, p0=p0, bounds=bounds, maxfev=MAXFEV)
        result.update({
            "success": True,
            "params": dict(zip(param_names, [float(v) for v in popt]))
        })
    except Exception as e:
        result["error"] = str(e)

    return result


def _fit_breed_curve(df_breed: pd.DataFrame) -> Dict:
    """
    拟合品种级群体曲线
    使用该品种所有牛只的数据点一起拟合
    """
    df = df_breed[[X_COL, Y_COL]].dropna()
    if len(df) < MIN_POINTS_PER_BREED:
        return {"success": False, "error": f"数据点不足: {len(df)} < {MIN_POINTS_PER_BREED}"}

    t = df[X_COL].values.astype(float)
    y = df[Y_COL].values.astype(float)
    mask = (t >= 0) & (y > 0)

    if mask.sum() < MIN_POINTS_PER_BREED:
        return {"success": False, "error": "有效数据点不足"}

    t, y = t[mask], y[mask]

    # 尝试三种模型，选择AIC最小的
    best_result = None
    best_aic = np.inf

    for model_name in _MODEL_SPECS.keys():
        result = _fit_model(t, y, model_name)
        if result["success"]:
            # 计算AIC
            y_pred = _MODEL_SPECS[model_name]["func"](t, *result["params"].values())
            n = len(y)
            k = len(result["params"])
            rss = np.sum((y - y_pred) ** 2)
            aic = n * np.log(rss / n) + 2 * k if rss > 1e-12 else np.inf

            if aic < best_aic:
                best_aic = aic
                best_result = {
                    **result,
                    "n_obs": int(len(t)),
                    "aic": float(aic),
                    "rmse": float(np.sqrt(rss / n))
                }

    if best_result is None:
        return {"success": False, "error": "所有模型拟合失败"}

    return best_result


def _calculate_individual_correction(
    df_cattle: pd.DataFrame,
    breed_params: Dict,
    model_name: str
) -> Dict:
    """
    计算个体校正系数
    个体实际体重 / 群体曲线预测体重 的比值作为校正因子
    """
    df = df_cattle[[X_COL, Y_COL]].dropna().sort_values(X_COL)
    if len(df) < MIN_POINTS_PER_CATTLE:
        return {"success": False, "error": f"数据点不足: {len(df)} < {MIN_POINTS_PER_CATTLE}"}

    t = df[X_COL].values.astype(float)
    y_actual = df[Y_COL].values.astype(float)
    mask = (t >= 0) & (y_actual > 0)

    if mask.sum() < MIN_POINTS_PER_CATTLE:
        return {"success": False, "error": "有效数据点不足"}

    t, y_actual = t[mask], y_actual[mask]

    # 使用群体曲线参数预测
    func = _MODEL_SPECS[model_name]["func"]
    params = list(breed_params.values())
    y_predicted = func(t, *params)

    # 计算校正因子（实际/预测的中位数比值，更稳健）
    correction_factors = y_actual / y_predicted
    correction_factor = float(np.median(correction_factors))

    # 计算校正后的R²（评估个体拟合优度）
    y_corrected_pred = y_predicted * correction_factor
    ss_res = np.sum((y_actual - y_corrected_pred) ** 2)
    ss_tot = np.sum((y_actual - np.mean(y_actual)) ** 2)
    r2 = 1.0 - ss_res / ss_tot if ss_tot > 1e-12 else np.nan

    # 计算RMSE
    rmse = float(np.sqrt(ss_res / len(y_actual)))

    return {
        "success": True,
        "correction_factor": correction_factor,
        "r2": r2,
        "rmse": rmse,
        "n_obs": int(len(t)),
        "age_min": int(t.min()),
        "age_max": int(t.max()),
        "weight_min": float(y_actual.min()),
        "weight_max": float(y_actual.max()),
    }


def _predict_future_weight(
    current_age: int,
    current_weight: float,
    breed_params: Dict,
    correction_factor: float,
    model_name: str,
    target_ages: List[int] = None
) -> List[Dict]:
    """预测未来体重"""
    if target_ages is None:
        # 默认预测未来30、60、90、180天的体重
        target_ages = [current_age + 30, current_age + 60, current_age + 90, current_age + 180]

    func = _MODEL_SPECS[model_name]["func"]
    params = list(breed_params.values())

    predictions = []
    for age in target_ages:
        if age > current_age:
            predicted_weight = func(np.array([age]), *params)[0] * correction_factor
            predictions.append({
                "predict_age": age,
                "predict_weight": float(predicted_weight),
                "days_from_now": age - current_age
            })

    return predictions


def model(dbt, session):
    dbt.config(
        materialized="table",
        description="牧场牛只生长曲线非线性拟合结果（群体曲线+个体校正）",
        tags=["ranch", "ads", "growth_curve", "python", "curve_fitting", "breed_level"]
    )

    # 读取数据
    df = dbt.ref("dws_ranch_cattle_adg_agg_i").to_df()

    if df.empty:
        return pd.DataFrame()

    # 确保必要列存在
    required_cols = [CATTLE_COL, SKU_COL, SKU_NAME_COL, X_COL, Y_COL]
    for col in required_cols:
        if col not in df.columns:
            raise ValueError(f"缺少必要列: {col}")

    results = []

    # 按品种分组处理
    for sku_id, df_breed in df.groupby(SKU_COL):
        sku_name = df_breed[SKU_NAME_COL].iloc[0] if SKU_NAME_COL in df_breed.columns else None

        # 步骤1: 拟合品种级群体曲线
        breed_fit = _fit_breed_curve(df_breed)

        if not breed_fit["success"]:
            # 品种级拟合失败，跳过该品种
            continue

        model_name = breed_fit["model"]
        breed_params = breed_fit["params"]

        # 步骤2: 对每头牛计算个体校正
        for cattle_id, df_cattle in df_breed.groupby(CATTLE_COL):
            # 获取牛只最新状态
            latest = df_cattle.sort_values("stats_date").iloc[-1]

            # 计算个体校正
            correction = _calculate_individual_correction(
                df_cattle, breed_params, model_name
            )

            if not correction["success"]:
                continue

            # 预测未来体重
            predictions = _predict_future_weight(
                current_age=int(latest["age_days"]),
                current_weight=float(latest["current_weight"]),
                breed_params=breed_params,
                correction_factor=correction["correction_factor"],
                model_name=model_name
            )

            # 构建结果记录
            base_record = {
                # 标识信息
                "cattle_id": str(cattle_id),
                "sku_id": str(sku_id),
                "sku_name": str(sku_name) if sku_name else None,

                # 群体曲线信息
                "breed_model": model_name,
                "breed_n_obs": breed_fit["n_obs"],
                "breed_aic": breed_fit.get("aic"),
                "breed_rmse": breed_fit.get("rmse"),

                # 群体曲线参数
                **{f"breed_param_{k.lower()}": v for k, v in breed_params.items()},

                # 个体校正信息
                "individual_n_obs": correction["n_obs"],
                "individual_r2": correction["r2"],
                "individual_rmse": correction["rmse"],
                "correction_factor": correction["correction_factor"],

                # 个体观测范围
                "obs_age_min": correction["age_min"],
                "obs_age_max": correction["age_max"],
                "obs_weight_min": correction["weight_min"],
                "obs_weight_max": correction["weight_max"],

                # 当前状态
                "current_age_days": int(latest["age_days"]),
                "current_weight": float(latest["current_weight"]),
                "current_stage": latest.get("stage_name"),

                # 可靠性评级
                "reliability": (
                    "高" if correction["n_obs"] >= 5 else
                    "中" if correction["n_obs"] >= 3 else
                    "低"
                ),
            }

            # 添加预测结果（展开成多行）
            if predictions:
                for pred in predictions:
                    record = {
                        **base_record,
                        "predict_target_age": pred["predict_age"],
                        "predict_target_weight": pred["predict_weight"],
                        "predict_days_ahead": pred["days_from_now"],
                    }
                    results.append(record)
            else:
                # 没有预测数据（可能是老年牛）
                record = {
                    **base_record,
                    "predict_target_age": None,
                    "predict_target_weight": None,
                    "predict_days_ahead": None,
                }
                results.append(record)

    if not results:
        return pd.DataFrame()

    df_result = pd.DataFrame(results)
    df_result["dw_update_time"] = pd.Timestamp.now()

    return df_result
