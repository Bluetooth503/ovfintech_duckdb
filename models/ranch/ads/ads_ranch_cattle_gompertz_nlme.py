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
import os
from typing import Dict, List, Tuple, Optional
import json
import numpy as np
import pandas as pd
import pymc as pm
import arviz as az
from scipy.optimize import curve_fit
warnings.filterwarnings("ignore")

# --------------------------------------------------------------------------------
# 基于大规模实际数据的优化配置 (2026-04-14)
# 数据规模: 168,861头牛, 2,634个栏位, 57个投资方
# 称重分布: 中位数2次, 范围1-17次, 85.5%的牛只有≥2次观测, 14.5%的牛只有≥3次观测
# 日龄数据: 严重缺失(99.9%为空)，需要考虑替代方案
# 体重范围: 0.1-10519.0kg, 中位数352.0kg, P75=484.0kg
# 数据质量策略: 设置为3次以确保模型拟合质量，虽然数据利用率降低但数学上更合理
# --------------------------------------------------------------------------------
# 数据质量控制(基于大规模数据优化，优先保证模型拟合质量)
MIN_CATTLE_PER_STALL = 20              # 栏位最小样本数(中位数35头，设置20头门槛)
MIN_CATTLE_PER_INVESTOR = 500          # 投资方最小样本数(中位数2195头，设置500头门槛)
MIN_OBS_PER_CATTLE = 3                 # 单头牛最小观测数(3次观测是3参数模型的数学要求，确保模型可识别性)

# 性能控制
MAX_CATTLE_FOR_MODELING = 2000         # 最大建模牛只数(降低到2000以适应硬件限制)

# MCMC 采样参数(大规模数据优化，针对硬件限制调整)
N_DRAWS = 1000                         # MCMC 采样次数(降低到1000以提高速度)
N_TUNE = 500                           # 预烧期(tune)次数(相应减少)
TARGET_ACCEPT = 0.90                   # 目标接受率(提高到0.90改善收敛)
CHAINS = 2                             # MCMC 链数量(减少到2以降低内存)
N_JOBS = 1                             # 并行作业数(避免内存问题)

# 模型先验超参数(基于实际数据分布优化)
PRIOR_A_MU = np.log(532)               # 成熟体重先验均值(基于P75=484kg和异常值处理)
PRIOR_A_SIGMA = 1.5                    # 成熟体重先验标准差
PRIOR_B_MU = np.log(0.015)             # 生长速率先验均值
PRIOR_B_SIGMA = 1.5                    # 生长速率先验标准差
PRIOR_C_MU = 200                       # 拐点日龄先验均值(日龄数据缺失，使用经验值)
PRIOR_C_SIGMA = 80                     # 拐点日龄先验标准差(增加不确定性以适应数据缺失)

# 随机效应参数
RANDOM_EFFECT_SD_PRIOR = 1.0           # 随机效应标准差先验
LKJ_ETA = 2.0                          # LKJ相关系数先验参数


def gompertz(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    """Gompertz 生长曲线函数: W(t) = A * exp(-exp(-B * (t - C)))"""
    return A * np.exp(-np.exp(-B * (t - C)))


def validate_and_adjust_config(n_observations: int, n_individuals: int) -> Dict:
    """根据数据规模自动调整配置参数"""
    config = {'n_draws': N_DRAWS, 'n_tune': N_TUNE, 'max_cattle': MAX_CATTLE_FOR_MODELING, 'chains': CHAINS}
    if n_observations < 1000: config.update({'n_draws': max(N_DRAWS // 2, 500), 'n_tune': max(N_TUNE // 2, 500), 'chains': max(CHAINS // 2, 2)})
    if n_individuals > 10000: config.update({'max_cattle': min(MAX_CATTLE_FOR_MODELING, 3000), 'chains': 2})
    return config


def log_model_diagnostics(trace, data: Dict) -> Dict:
    """记录模型诊断信息"""
    try:
        ess = az.ess(trace)
        rhat = az.rhat(trace)
        sample_stats = trace.sample_stats
        return {'ess_mean': float(ess.to_array().mean()), 'ess_min': float(ess.to_array().min()), 'rhat_max': float(rhat.to_array().max()), 'rhat_above_threshold': int((rhat.to_array() > 1.05).sum()), 'divergences': int(sample_stats.diverging.sum().values), 'max_tree_depth': int(sample_stats.tree_depth.max().values), 'mean_accept_prob': float(sample_stats.acceptance_rate.mean().values)}
    except Exception as e:
        return {'diagnostic_error': str(e)}


def prepare_nlme_data(df: pd.DataFrame) -> Optional[Dict]:
    """准备NLME建模所需的数据结构，处理日龄字段缺失问题"""
    df = df.copy()
    df = df[df['current_weight'] > 0]
    df = df.dropna(subset=['cattle_id'])

    # 处理日龄字段缺失问题：优先使用age_days，缺失时使用入栏后天数或其他替代方案
    if 'age_days' not in df.columns or df['age_days'].isna().all():
        if 'days_since_entry' in df.columns and df['days_since_entry'].notna().any():
            df['age_days'] = df['days_since_entry']
        elif 'weight_days' in df.columns and df['weight_days'].notna().any():
            df['age_days'] = df['weight_days']
        else:
            # 如果完全没有时间维度数据，返回None或考虑替代建模方法
            print("警告：缺少时间维度数据，无法进行生长曲线建模")
            return None

    # 过滤时间维度有效数据
    df = df[df['age_days'].notna() & (df['age_days'] > 0)]

    # 筛选有足够观测的牛只
    cattle_obs = df.groupby('cattle_id').size()
    valid_cattle = cattle_obs[cattle_obs >= MIN_OBS_PER_CATTLE].index
    df = df[df['cattle_id'].isin(valid_cattle)]

    # 适应实际数据结构：处理栏舍和投资方字段缺失
    if 'stall_id' not in df.columns or df['stall_id'].isna().all():
        if 'stall_name' in df.columns and df['stall_name'].notna().any():
            df['stall_id'] = df['stall_name']
        else:
            df['stall_id'] = 'default_stall'

    if 'investor_id' not in df.columns or df['investor_id'].isna().all():
        if 'investor_name' in df.columns and df['investor_name'].notna().any():
            df['investor_id'] = df['investor_name']
        elif 'customer_id' in df.columns and df['customer_id'].notna().any():
            df['investor_id'] = df['customer_id'].astype(str)
        else:
            df['investor_id'] = 'default_investor'

    if 'sku_name' not in df.columns or df['sku_name'].isna().all():
        df['sku_name'] = 'default_sku'

    # 筛选有效栏位(替代牧场)
    stall_counts = df.groupby('stall_id')['cattle_id'].nunique()
    valid_stalls = stall_counts[stall_counts >= MIN_CATTLE_PER_STALL].index
    df = df[df['stall_id'].isin(valid_stalls)]

    # 筛选有效投资方(替代牧场)
    investor_counts = df.groupby('investor_id')['cattle_id'].nunique()
    valid_investors = investor_counts[investor_counts >= MIN_CATTLE_PER_INVESTOR].index
    df = df[df['investor_id'].isin(valid_investors)]

    if len(df) == 0: return None

    # 限制建模规模（性能考虑）
    if df['cattle_id'].nunique() > MAX_CATTLE_FOR_MODELING:
        sampled_cattle = df['cattle_id'].drop_duplicates().sample(MAX_CATTLE_FOR_MODELING, random_state=42)
        df = df[df['cattle_id'].isin(sampled_cattle)]

    # 编码为类别型
    df['stall_id'] = df['stall_id'].astype(str)
    df['investor_id'] = df['investor_id'].astype(str)
    df['sku_name'] = df['sku_name'].astype(str)
    df['cattle_id'] = df['cattle_id'].astype(str)

    # 生成设计矩阵（固定效应：栏位 + 投资方 + 品种）
    stall_dummies = pd.get_dummies(df['stall_id'], prefix='stall', drop_first=True).astype(int)
    investor_dummies = pd.get_dummies(df['investor_id'], prefix='investor', drop_first=True).astype(int)
    sku_dummies = pd.get_dummies(df['sku_name'], prefix='sku', drop_first=True).astype(int)

    # 智能选择固定效应以控制模型复杂度
    if len(investor_dummies.columns) > 30:  # 投资方过多时只保留投资方效应
        X_fixed = pd.concat([pd.DataFrame({'intercept': 1}, index=df.index), investor_dummies], axis=1)
    elif len(stall_dummies.columns) > 100:  # 栏位过多时只保留投资方效应
        X_fixed = pd.concat([pd.DataFrame({'intercept': 1}, index=df.index), investor_dummies], axis=1)
    elif len(investor_dummies.columns) + len(stall_dummies.columns) > 150:  # 总维度过多时只用投资方
        X_fixed = pd.concat([pd.DataFrame({'intercept': 1}, index=df.index), investor_dummies], axis=1)
    else:  # 否则包含所有效应
        X_fixed = pd.concat([pd.DataFrame({'intercept': 1}, index=df.index), stall_dummies, investor_dummies, sku_dummies], axis=1)

    # 牛只ID编码
    cattle_ids = df['cattle_id'].astype('category').cat.codes.values
    n_cattle = df['cattle_id'].nunique()

    return {'df': df, 'X': X_fixed.values, 'X_cols': X_fixed.columns.tolist(), 'cattle_idx': cattle_ids, 'n_cattle': n_cattle, 'age': df['age_days'].values.astype(float), 'weight': df['current_weight'].values.astype(float), 'stall_ids': df['stall_id'].unique().tolist(), 'investor_ids': df['investor_id'].unique().tolist(), 'sku_names': df['sku_name'].unique().tolist(), 'cattle_ids': df['cattle_id'].unique().tolist()}


def fit_gompertz_nlme_pymc(data: Dict, n_draws: int = N_DRAWS, n_tune: int = N_TUNE, target_accept: float = TARGET_ACCEPT) -> Optional[Dict]:
    """使用 PyMC 拟合 Gompertz NLME 模型"""
    try:
        with pm.Model() as nlme_model:
            # ==================== 固定效应先验 ====================
            n_fixed = data['X'].shape[1]

            # 对于高维固定效应，使用更紧的先验
            beta_A = pm.Normal('beta_log_A', mu=PRIOR_A_MU, sigma=PRIOR_A_SIGMA, shape=n_fixed)
            beta_B = pm.Normal('beta_log_B', mu=PRIOR_B_MU, sigma=PRIOR_B_SIGMA, shape=n_fixed)
            beta_C = pm.Normal('beta_C', mu=PRIOR_C_MU, sigma=PRIOR_C_SIGMA, shape=n_fixed)

            # ==================== 随机效应 ====================
            # 降低随机效应复杂性以改善收敛
            chol, _, _ = pm.LKJCholeskyCov('chol_cov', n=3, eta=LKJ_ETA, sd_dist=pm.Exponential.dist(0.8, shape=3))
            Sigma = pm.Deterministic('Sigma', chol @ chol.T)
            u = pm.MvNormal('u', mu=0, chol=chol, shape=(data['n_cattle'], 3))

            # ==================== 参数组合 ====================
            log_A_pop = pm.math.dot(data['X'], beta_A)
            log_B_pop = pm.math.dot(data['X'], beta_B)
            C_pop = pm.math.dot(data['X'], beta_C)
            log_A = log_A_pop + u[data['cattle_idx'], 0]
            log_B = log_B_pop + u[data['cattle_idx'], 1]
            C = C_pop + u[data['cattle_idx'], 2]
            A = pm.math.exp(log_A)
            B = pm.math.exp(log_B)

            # ==================== Gompertz 预测 ====================
            t = data['age']
            mu = A * pm.math.exp(-pm.math.exp(-B * (t - C)))

            # ==================== 似然 ====================
            sigma = pm.HalfNormal('sigma', sigma=50)
            y_obs = pm.Normal('y_obs', mu=mu, sigma=sigma, observed=data['weight'])

            # ==================== 采样 ====================
            trace = pm.sample(
                draws=n_draws,
                tune=n_tune,
                chains=CHAINS,
                cores=N_JOBS,
                target_accept=target_accept,
                return_inferencedata=True,
                progressbar=True,
                max_treedepth=12  # 增加树深度以改善收敛
            )

        return {'trace': trace, 'data': data, 'model_type': 'pymc'}

    except Exception as e:
        print(f"PyMC建模失败: {e}")
        raise e  # 重新抛出异常以便主函数使用简化方法


def fit_gompertz_nlme_simplified(data: Dict) -> Dict:
    """简化的两阶段 NLME 近似（当 PyMC 不可用时）"""
    df = data['df']
    cattle_groups = df.groupby('cattle_id')

    # 阶段1：个体拟合
    individual_params = {}
    for cattle_id, group in cattle_groups:
        if len(group) < MIN_OBS_PER_CATTLE: continue
        t = group['age_days'].values.astype(float)
        y = group['current_weight'].values.astype(float)

        try:
            popt, _ = curve_fit(gompertz, t, y, p0=[max(y)*1.2, 0.01, np.median(t)], bounds=([0, 0, -np.inf], [np.inf, np.inf, np.inf]), maxfev=10000)
            individual_params[cattle_id] = {'A': popt[0], 'B': popt[1], 'C': popt[2], 'log_A': np.log(popt[0]), 'log_B': np.log(popt[1]), 'sku': group['sku_name'].iloc[0], 'ranch': group['ranch_name'].iloc[0]}
        except Exception:
            continue

    if len(individual_params) < 10: return {'error': 'Insufficient data for modeling'}

    # 阶段2：固定效应估计
    params_df = pd.DataFrame(individual_params).T
    sku_dummies = pd.get_dummies(params_df['sku'], prefix='sku', drop_first=True).astype(int)
    ranch_dummies = pd.get_dummies(params_df['ranch'], prefix='ranch', drop_first=True).astype(int)
    X = pd.concat([pd.DataFrame({'intercept': 1}, index=params_df.index), sku_dummies, ranch_dummies], axis=1)

    # OLS 估计
    def ols_fit(y, X_mat):
        X_np = X_mat.values.astype(float)
        y = y.astype(float)
        XtX = X_np.T @ X_np + 0.001 * np.eye(X_np.shape[1])
        beta = np.linalg.solve(XtX, X_np.T @ y)
        residuals = y - X_np @ beta
        return beta, residuals, X_mat.columns.tolist()

    beta_A, resid_A, cols_A = ols_fit(params_df['log_A'].values, X)
    beta_B, resid_B, cols_B = ols_fit(params_df['log_B'].values, X)
    beta_C, resid_C, cols_C = ols_fit(params_df['C'].values, X)

    # 计算方差
    var_A, var_B, var_C = np.var(resid_A), np.var(resid_B), np.var(resid_C)

    return {'model_type': 'simplified', 'fixed_effects': {'log_A': {'beta': beta_A, 'cols': cols_A}, 'log_B': {'beta': beta_B, 'cols': cols_B}, 'C': {'beta': beta_C, 'cols': cols_C}}, 'random_effects_variance': {'u_log_A': var_A, 'u_log_B': var_B, 'u_C': var_C}, 'individual_residuals': {'log_A': dict(zip(params_df.index, resid_A)), 'log_B': dict(zip(params_df.index, resid_B)), 'C': dict(zip(params_df.index, resid_C))}, 'n_individuals': len(individual_params)}


def extract_nlme_results(results: Dict) -> pd.DataFrame:
    """从 NLME 拟合结果中提取结构化输出"""
    rows = []

    if 'error' in results: return pd.DataFrame([{'result_type': 'error', 'parameter': results['error'], 'estimate': None}])

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
                rows.append({'result_type': 'fixed_effect', 'parameter': param_name, 'level': col, 'estimate': float(mean_val), 'std_error': float(std_val), 'ci_lower': float(hdi_lower), 'ci_upper': float(hdi_upper)})

        # 方差分解
        Sigma_post = trace.posterior['Sigma'].values
        rows.append({'result_type': 'variance', 'parameter': 'u_log_A_variance', 'estimate': float(np.mean(Sigma_post[:, :, 0, 0]))})
        rows.append({'result_type': 'variance', 'parameter': 'u_log_B_variance', 'estimate': float(np.mean(Sigma_post[:, :, 1, 1]))})
        rows.append({'result_type': 'variance', 'parameter': 'u_C_variance', 'estimate': float(np.mean(Sigma_post[:, :, 2, 2]))})

        # 随机效应（前100头牛）
        u_post = trace.posterior['u'].values
        for i, cattle_id in enumerate(data['cattle_ids'][:100]):
            rows.append({'result_type': 'random_effect', 'parameter': 'u_log_A', 'cattle_id': cattle_id, 'estimate': float(np.mean(u_post[:, :, i, 0])), 'std_error': float(np.std(u_post[:, :, i, 0]))})
    else:
        # 简化模型结果
        fe = results['fixed_effects']

        for param in ['log_A', 'log_B', 'C']:
            beta, cols = fe[param]['beta'], fe[param]['cols']
            for i, col in enumerate(cols):
                rows.append({'result_type': 'fixed_effect', 'parameter': param, 'level': col, 'estimate': float(beta[i]), 'std_error': None, 'ci_lower': None, 'ci_upper': None})

        # 方差分解
        var = results['random_effects_variance']
        for param, val in var.items(): rows.append({'result_type': 'variance', 'parameter': param, 'estimate': float(val)})

        # 个体随机效应
        resid = results['individual_residuals']['log_A']
        for cattle_id, val in list(resid.items())[:100]: rows.append({'result_type': 'random_effect', 'parameter': 'u_log_A', 'cattle_id': cattle_id, 'estimate': float(val), 'std_error': None})

    return pd.DataFrame(rows)


def model(dbt, session):
    """DBT Python 模型主函数"""
    dbt.config(materialized="table", description="Gompertz NLME 多维度生长曲线混合效应模型结果", tags=["ranch", "ads", "model", "nlme", "gompertz", "growth_curve", "python"])

    # 读取输入数据
    df_input = dbt.ref("dws_ranch_cattle_adg_agg_i").to_df()

    if len(df_input) == 0: return pd.DataFrame({'model_status': ['no_data'], 'result_type': ['error'], 'message': ['Input data is empty']})

    # 准备NLME数据
    nlme_data = prepare_nlme_data(df_input)

    if nlme_data is None: return pd.DataFrame({'model_status': ['insufficient_data'], 'result_type': ['error'], 'message': ['Not enough valid data for NLME modeling']})

    # 根据数据规模自适应调整配置
    config = validate_and_adjust_config(len(nlme_data['df']), nlme_data['n_cattle'])

    # 拟合模型
    try:
        results = fit_gompertz_nlme_pymc(nlme_data, n_draws=config['n_draws'], n_tune=config['n_tune'])
        if 'trace' in results: results['diagnostics'] = log_model_diagnostics(results['trace'], nlme_data)
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

    # 添加模型诊断信息(如果有)
    if 'diagnostics' in results:
        for key, value in results['diagnostics'].items(): df_results[f'diag_{key}'] = value

    return df_results
