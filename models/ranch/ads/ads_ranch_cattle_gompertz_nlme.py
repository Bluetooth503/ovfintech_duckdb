"""
========================================
模型名称：ads_ranch_cattle_gompertz_nlme
模型描述：Gompertz NLME 多维度生长曲线混合效应模型
说明：
  - 基于 dws_ranch_cattle_adg_agg_i 数据进行NLME建模
  - 使用 PyMC 实现贝叶斯 NLME
  - 固定效应：品种、牧场、栏舍
  - 随机效应：个体层面的 A/B/C 参数偏差
  - 输出固定效应、随机效应、方差分解结果
========================================
"""
import warnings
from typing import Dict, List, Tuple, Optional
import json
import numpy as np
import pandas as pd
import pymc as pm
import arviz as az
from scipy.optimize import curve_fit

warnings.filterwarnings("ignore")

# --------------------------------------------------------------------------------
# 配置参数
# --------------------------------------------------------------------------------
MIN_CATTLE_PER_SKU = 30         # 品种最小样本数
MIN_CATTLE_PER_RANCH = 20       # 牧场最小样本数
MIN_OBS_PER_CATTLE = 3          # 单头牛最小观测数
MAX_CATTLE_FOR_MODELING = 200000  # 最大建模牛只数（性能考虑）
N_DRAWS = 500                   # MCMC 采样次数
N_TUNE = 300                    # 预烧期（tune）次数


def gompertz(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    """Gompertz 生长曲线函数: W(t) = A * exp(-exp(-B * (t - C)))"""
    return A * np.exp(-np.exp(-B * (t - C)))


def prepare_nlme_data(df: pd.DataFrame) -> Optional[Dict]:
    """准备NLME建模所需的数据结构"""
    df = df.copy()
    df = df[df['current_weight'] > 0]
    df = df.dropna(subset=['age_days', 'current_weight', 'cattle_id', 'sku_name', 'ranch_name'])

    # 筛选有足够观测的牛只
    cattle_obs = df.groupby('cattle_id').size()
    valid_cattle = cattle_obs[cattle_obs >= MIN_OBS_PER_CATTLE].index
    df = df[df['cattle_id'].isin(valid_cattle)]

    # 筛选有效品种
    sku_counts = df.groupby('sku_name')['cattle_id'].nunique()
    valid_sku = sku_counts[sku_counts >= MIN_CATTLE_PER_SKU].index
    df = df[df['sku_name'].isin(valid_sku)]

    # 筛选有效牧场
    ranch_counts = df.groupby('ranch_name')['cattle_id'].nunique()
    valid_ranch = ranch_counts[ranch_counts >= MIN_CATTLE_PER_RANCH].index
    df = df[df['ranch_name'].isin(valid_ranch)]

    if len(df) == 0:
        return None

    # 限制建模规模（性能考虑）
    if df['cattle_id'].nunique() > MAX_CATTLE_FOR_MODELING:
        sampled_cattle = df['cattle_id'].drop_duplicates().sample(MAX_CATTLE_FOR_MODELING, random_state=42)
        df = df[df['cattle_id'].isin(sampled_cattle)]

    # 编码为类别型
    df['sku_name'] = df['sku_name'].astype('category')
    df['ranch_name'] = df['ranch_name'].astype('category')
    df['cattle_id'] = df['cattle_id'].astype('category')

    # 生成设计矩阵（固定效应：品种 + 牧场）
    sku_dummies = pd.get_dummies(df['sku_name'], prefix='sku', drop_first=True)
    ranch_dummies = pd.get_dummies(df['ranch_name'], prefix='ranch', drop_first=True)
    X_fixed = pd.concat([pd.DataFrame({'intercept': 1}, index=df.index), sku_dummies, ranch_dummies], axis=1)

    # 牛只ID编码
    cattle_ids = df['cattle_id'].cat.codes.values
    n_cattle = df['cattle_id'].nunique()

    return {
        'df': df,
        'X': X_fixed.values,
        'X_cols': X_fixed.columns.tolist(),
        'cattle_idx': cattle_ids,
        'n_cattle': n_cattle,
        'age': df['age_days'].values.astype(float),
        'weight': df['current_weight'].values.astype(float),
        'sku_names': df['sku_name'].cat.categories.tolist(),
        'ranch_names': df['ranch_name'].cat.categories.tolist(),
        'cattle_ids': df['cattle_id'].cat.categories.tolist()
    }


def fit_gompertz_nlme_pymc(data: Dict, n_draws: int = N_DRAWS, n_tune: int = N_TUNE) -> Optional[Dict]:
    """使用 PyMC 拟合 Gompertz NLME 模型"""
    with pm.Model() as nlme_model:
        # ==================== 固定效应先验 ====================
        n_fixed = data['X'].shape[1]

        # log(A) 的固定效应（成熟体重）
        beta_A = pm.Normal('beta_log_A', mu=np.log(600), sigma=1, shape=n_fixed)
        # log(B) 的固定效应（生长速率）
        beta_B = pm.Normal('beta_log_B', mu=np.log(0.01), sigma=1, shape=n_fixed)
        # C 的固定效应（拐点日龄）
        beta_C = pm.Normal('beta_C', mu=300, sigma=50, shape=n_fixed)

        # ==================== 随机效应 ====================
        # 随机效应协方差矩阵（Cholesky分解）
        packed_L = pm.LKJCholeskyCov('packed_L', n=3, eta=2, sd_dist=pm.Exponential.dist(1.0, shape=3))
        L = pm.expand_packed_triangular(3, packed_L)
        Sigma = pm.Deterministic('Sigma', L @ L.T)

        # 个体随机效应
        u = pm.MvNormal('u', mu=0, chol=L, shape=(data['n_cattle'], 3))

        # ==================== 参数组合 ====================
        # 线性预测（固定效应部分）
        log_A_pop = pm.math.dot(data['X'], beta_A)
        log_B_pop = pm.math.dot(data['X'], beta_B)
        C_pop = pm.math.dot(data['X'], beta_C)

        # 加上个体随机效应
        log_A = log_A_pop + u[data['cattle_idx'], 0]
        log_B = log_B_pop + u[data['cattle_idx'], 1]
        C = C_pop + u[data['cattle_idx'], 2]

        # 转换到原始尺度
        A = pm.math.exp(log_A)
        B = pm.math.exp(log_B)

        # ==================== Gompertz 预测 ====================
        t = data['age']
        mu = A * pm.math.exp(-pm.math.exp(-B * (t - C)))

        # ==================== 似然 ====================
        sigma = pm.HalfNormal('sigma', sigma=50)
        y_obs = pm.Normal('y_obs', mu=mu, sigma=sigma, observed=data['weight'])

        # ==================== 采样 ====================
        trace = pm.sample(draws=n_draws, tune=n_tune, chains=2, target_accept=0.9, return_inferencedata=True, progressbar=False)

    return {'trace': trace, 'data': data, 'model_type': 'pymc'}


def fit_gompertz_nlme_simplified(data: Dict) -> Dict:
    """简化的两阶段 NLME 近似（当 PyMC 不可用时）: 阶段1每头牛单独拟合 Gompertz, 阶段2用 OLS 估计固定效应"""
    df = data['df']
    cattle_groups = df.groupby('cattle_id')

    # 阶段1：个体拟合
    individual_params = {}
    for cattle_id, group in cattle_groups:
        if len(group) < MIN_OBS_PER_CATTLE:
            continue
        t = group['age_days'].values.astype(float)
        y = group['current_weight'].values.astype(float)

        try:
            popt, _ = curve_fit(gompertz, t, y, p0=[max(y)*1.2, 0.01, np.median(t)], bounds=([0, 0, -np.inf], [np.inf, np.inf, np.inf]), maxfev=10000)
            individual_params[cattle_id] = {
                'A': popt[0], 'B': popt[1], 'C': popt[2],
                'log_A': np.log(popt[0]), 'log_B': np.log(popt[1]),
                'sku': group['sku_name'].iloc[0],
                'ranch': group['ranch_name'].iloc[0]
            }
        except Exception:
            continue

    if len(individual_params) < 10:
        return {'error': 'Insufficient data for modeling'}

    # 阶段2：固定效应估计
    params_df = pd.DataFrame(individual_params).T

    # 准备设计矩阵
    sku_dummies = pd.get_dummies(params_df['sku'], prefix='sku', drop_first=True)
    ranch_dummies = pd.get_dummies(params_df['ranch'], prefix='ranch', drop_first=True)
    X = pd.concat([pd.DataFrame({'intercept': 1}, index=params_df.index), sku_dummies, ranch_dummies], axis=1)

    # OLS 估计
    def ols_fit(y, X_mat):
        X_np = X_mat.values
        XtX = X_np.T @ X_np + 0.001 * np.eye(X_np.shape[1])
        beta = np.linalg.solve(XtX, X_np.T @ y)
        residuals = y - X_np @ beta
        return beta, residuals, X_mat.columns.tolist()

    beta_A, resid_A, cols_A = ols_fit(params_df['log_A'].values, X)
    beta_B, resid_B, cols_B = ols_fit(params_df['log_B'].values, X)
    beta_C, resid_C, cols_C = ols_fit(params_df['C'].values, X)

    # 计算方差
    var_A, var_B, var_C = np.var(resid_A), np.var(resid_B), np.var(resid_C)

    return {
        'model_type': 'simplified',
        'fixed_effects': {
            'log_A': {'beta': beta_A, 'cols': cols_A},
            'log_B': {'beta': beta_B, 'cols': cols_B},
            'C': {'beta': beta_C, 'cols': cols_C}
        },
        'random_effects_variance': {'u_log_A': var_A, 'u_log_B': var_B, 'u_C': var_C},
        'individual_residuals': {
            'log_A': dict(zip(params_df.index, resid_A)),
            'log_B': dict(zip(params_df.index, resid_B)),
            'C': dict(zip(params_df.index, resid_C))
        },
        'n_individuals': len(individual_params)
    }


def extract_nlme_results(results: Dict) -> pd.DataFrame:
    """从 NLME 拟合结果中提取结构化输出"""
    rows = []

    if 'error' in results:
        return pd.DataFrame([{'result_type': 'error', 'parameter': results['error'], 'estimate': None}])

    if results.get('model_type') == 'pymc':
        # PyMC 结果提取
        trace, data = results['trace'], results['data']

        # 固定效应
        for i, col in enumerate(data['X_cols']):
            for param_name, beta_name in [('log_A', 'beta_log_A'), ('log_B', 'beta_log_B'), ('C', 'beta_C')]:
                post = trace.posterior[beta_name].values
                mean_val = np.mean(post[:, :, i])
                std_val = np.std(post[:, :, i])
                hdi_lower, hdi_upper = np.percentile(post[:, :, i], 2.5), np.percentile(post[:, :, i], 97.5)
                rows.append({
                    'result_type': 'fixed_effect', 'parameter': param_name, 'level': col,
                    'estimate': float(mean_val), 'std_error': float(std_val),
                    'ci_lower': float(hdi_lower), 'ci_upper': float(hdi_upper)
                })

        # 方差分解
        Sigma_post = trace.posterior['Sigma'].values
        rows.append({'result_type': 'variance', 'parameter': 'u_log_A_variance', 'estimate': float(np.mean(Sigma_post[:, :, 0, 0]))})
        rows.append({'result_type': 'variance', 'parameter': 'u_log_B_variance', 'estimate': float(np.mean(Sigma_post[:, :, 1, 1]))})
        rows.append({'result_type': 'variance', 'parameter': 'u_C_variance', 'estimate': float(np.mean(Sigma_post[:, :, 2, 2]))})

        # 随机效应（前100头牛）
        u_post = trace.posterior['u'].values
        for i, cattle_id in enumerate(data['cattle_ids'][:100]):
            rows.append({
                'result_type': 'random_effect', 'parameter': 'u_log_A', 'cattle_id': cattle_id,
                'estimate': float(np.mean(u_post[:, :, i, 0])), 'std_error': float(np.std(u_post[:, :, i, 0]))
            })
    else:
        # 简化模型结果
        fe = results['fixed_effects']

        for param in ['log_A', 'log_B', 'C']:
            beta, cols = fe[param]['beta'], fe[param]['cols']
            for i, col in enumerate(cols):
                rows.append({
                    'result_type': 'fixed_effect', 'parameter': param, 'level': col,
                    'estimate': float(beta[i]), 'std_error': None, 'ci_lower': None, 'ci_upper': None
                })

        # 方差分解
        var = results['random_effects_variance']
        for param, val in var.items():
            rows.append({'result_type': 'variance', 'parameter': param, 'estimate': float(val)})

        # 个体随机效应
        resid = results['individual_residuals']['log_A']
        for cattle_id, val in list(resid.items())[:100]:
            rows.append({
                'result_type': 'random_effect', 'parameter': 'u_log_A', 'cattle_id': cattle_id,
                'estimate': float(val), 'std_error': None
            })

    return pd.DataFrame(rows)


def model(dbt, session):
    """DBT Python 模型主函数"""
    dbt.config(
        materialized="table",
        description="Gompertz NLME 多维度生长曲线混合效应模型结果",
        tags=["ranch", "ads", "model", "nlme", "gompertz", "growth_curve", "python"]
    )

    # 读取输入数据
    df_input = dbt.ref("dws_ranch_cattle_adg_agg_i").to_df()

    if len(df_input) == 0:
        return pd.DataFrame({'model_status': ['no_data'], 'result_type': ['error'], 'message': ['Input data is empty']})

    # 准备NLME数据
    nlme_data = prepare_nlme_data(df_input)

    if nlme_data is None:
        return pd.DataFrame({'model_status': ['insufficient_data'], 'result_type': ['error'], 'message': ['Not enough valid data for NLME modeling']})

    # 拟合模型
    try:
        results = fit_gompertz_nlme_pymc(nlme_data, n_draws=N_DRAWS, n_tune=N_TUNE)
    except Exception as e:
        # 如果PyMC失败，回退到简化版
        print(f"PyMC fitting failed: {e}, using simplified method")
        results = fit_gompertz_nlme_simplified(nlme_data)

    # 提取结果
    df_results = extract_nlme_results(results)

    # 添加元数据
    df_results['model_status'] = 'success'
    df_results['model_type'] = results.get('model_type', 'unknown')
    df_results['n_individuals'] = nlme_data['n_cattle']
    df_results['fit_timestamp'] = pd.Timestamp.now()

    return df_results
