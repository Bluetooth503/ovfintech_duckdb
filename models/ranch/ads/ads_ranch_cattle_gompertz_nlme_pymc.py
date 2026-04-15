"""
ads_ranch_cattle_gompertz_nlme_pymc - Gompertz NLME 多维度生长曲线混合效应模型（PyMC 贝叶斯版）

基于 dws_ranch_cattle_adg_agg_i 数据，使用 PyMC 实现贝叶斯 NLME
固定效应：品种(sku_name)、牧场(ranch_name)、饲料结构特征；随机效应：个体层面 A/B/C 参数偏差
"""
import warnings
from typing import Dict, Optional
import numpy as np
import pandas as pd
import pymc as pm
import arviz as az

warnings.filterwarnings("ignore")

# ---------- 数据质量控制 ----------
MIN_CATTLE_PER_STALL = 20              # 栏位最小样本数
MIN_OBS_PER_CATTLE = 3                 # 单头牛最小观测数（3参数模型数学要求）

# ---------- 性能控制 ----------
MAX_CATTLE_FOR_MODELING = 200          # 最大建模牛只数, 默认2000

# ---------- MCMC 采样参数 ----------
N_DRAWS = 500                          # 采样次数
N_TUNE = 500                           # 预烧期次数
TARGET_ACCEPT = 0.90                   # 目标接受率
CHAINS = 2                             # MCMC 链数量（必须>=2才能计算R-hat）
N_JOBS = 4                             # 并行作业数

# ---------- 模型先验超参数 ----------
PRIOR_A_MU = np.log(532)               # 成熟体重先验均值
PRIOR_A_SIGMA = 1.5                    # 成熟体重先验标准差
PRIOR_B_MU = np.log(0.015)             # 生长速率先验均值
PRIOR_B_SIGMA = 1.5                    # 生长速率先验标准差
PRIOR_C_MU = 200                       # 拐点日龄先验均值
PRIOR_C_SIGMA = 80                     # 拐点日龄先验标准差

# ---------- 随机效应参数 ----------
LKJ_ETA = 2.0                          # LKJ 相关系数先验参数

# ---------- 饲料特征列 ----------
FEED_FEATURES = [
    'concentrate_ratio',
    'roughage_ratio',
    'period_avg_feed_intake',
    'feed_cost_per_kg_gain',
]


def validate_and_adjust_config(n_observations: int, n_individuals: int) -> Dict:
    """根据数据规模自动调整 MCMC 配置"""
    config = {'n_draws': N_DRAWS, 'n_tune': N_TUNE, 'max_cattle': MAX_CATTLE_FOR_MODELING, 'chains': CHAINS}
    if n_observations < 1000:
        config.update({'n_draws': max(N_DRAWS // 2, 500), 'n_tune': max(N_TUNE // 2, 500), 'chains': max(CHAINS // 2, 2)})
    return config


def log_model_diagnostics(trace, data: Dict) -> Dict:
    """提取 MCMC 采样诊断指标（按变量逐个计算，避免全量 to_array 内存爆炸）"""
    try:
        stats = trace.sample_stats
        var_names = ['beta_log_A', 'beta_log_B', 'beta_C', 'Sigma']
        ess_list, rhat_list = [], []
        for v in var_names:
            if v in trace.posterior:
                try:
                    ess_v = az.ess(trace, var_names=[v])
                    rhat_v = az.rhat(trace, var_names=[v])
                    ess_list.append(float(np.nanmin(ess_v[v].values)))
                    rhat_list.append(float(np.nanmax(rhat_v[v].values)))
                except Exception:
                    continue
        return {
            'ess_mean': float(np.mean(ess_list)) if ess_list else np.nan,
            'ess_min': float(np.min(ess_list)) if ess_list else np.nan,
            'rhat_max': float(np.max(rhat_list)) if rhat_list else np.nan,
            'rhat_above_threshold': sum(1 for r in rhat_list if r > 1.05),
            'divergences': int(stats.diverging.sum().values),
            'max_tree_depth': int(stats.tree_depth.max().values),
            'mean_accept_prob': float(stats.acceptance_rate.mean().values)
        }
    except Exception:
        return {}


def prepare_nlme_data(df_adg: pd.DataFrame, df_feed: Optional[pd.DataFrame] = None) -> Optional[Dict]:
    """准备 NLME 建模数据，清洗并构建设计矩阵"""
    df = df_adg.copy()
    df = df[(df['current_weight'] > 0) & df['cattle_id'].notna()]
    print(f"初始数据规模: {len(df)} 条记录, {df['cattle_id'].nunique()} 头牛")

    # 时间维度：优先 age_days，缺失时用 days_since_entry
    if df['age_days'].notna().any():
        df['time_variable'] = df['age_days']
        time_source = 'age_days'
        print(f"使用age_days作为时间变量，有效数据: {df['age_days'].notna().sum()}/{len(df)}")
    elif df['days_since_entry'].notna().any():
        df['time_variable'] = df['days_since_entry']
        time_source = 'days_since_entry'
        print(f"使用days_since_entry替代，有效数据: {df['days_since_entry'].notna().sum()}/{len(df)}")
    else:
        print("错误：缺少时间维度数据，无法建模")
        return None

    before = len(df)
    df = df[df['time_variable'].notna() & (df['time_variable'] > 0)]
    print(f"过滤时间维度无效数据: {before} -> {len(df)} 条记录")

    # 筛选有足够观测的牛只
    valid_cattle = df.groupby('cattle_id').size().pipe(lambda s: s[s >= MIN_OBS_PER_CATTLE]).index
    df = df[df['cattle_id'].isin(valid_cattle)]
    print(f"筛选观测数≥{MIN_OBS_PER_CATTLE}的牛只: {df['cattle_id'].nunique()} 头")

    # 填充分类字段
    for col, tag in [('stall_id', 'stall'), ('customer_id', 'customer'), ('sku_name', 'sku'), ('ranch_name', 'ranch')]:
        df[col] = df[col].fillna(f'unknown_{tag}').astype(str)

    # 生长阶段
    if df['stage_name'].notna().any():
        df['stage_name'] = df['stage_name'].fillna('unknown_stage').astype(str)
        stage_info = {'available': True, 'unique_stages': df['stage_name'].unique().tolist(), 'n_stages': df['stage_name'].nunique()}
        print(f"发现生长阶段信息: {stage_info['n_stages']} 个不同阶段")
    else:
        df['stage_name'] = 'unknown_stage'
        stage_info = {'available': False, 'n_stages': 0}

    # 筛选有效栏位
    valid_stalls = df.groupby('stall_id')['cattle_id'].nunique().pipe(lambda s: s[s >= MIN_CATTLE_PER_STALL]).index
    df = df[df['stall_id'].isin(valid_stalls)]
    print(f"筛选有效栏位(≥{MIN_CATTLE_PER_STALL}头): {len(valid_stalls)} 个栏位")

    if len(df) == 0:
        print("错误：过滤后没有剩余数据")
        return None

    # 限制建模规模
    if df['cattle_id'].nunique() > MAX_CATTLE_FOR_MODELING:
        sampled = df['cattle_id'].drop_duplicates().sample(MAX_CATTLE_FOR_MODELING, random_state=42)
        df = df[df['cattle_id'].isin(sampled)]
        print(f"限制建模规模到 {MAX_CATTLE_FOR_MODELING} 头牛")

    # 性能指标统计
    performance_info = {}
    for col, name in [('period_adg', 'adg'), ('period_fcr', 'fcr')]:
        if col in df.columns and df[col].notna().any():
            performance_info[f'{name}_available'] = True
            performance_info[f'{name}_stats'] = {'mean': float(df[col].mean()), 'median': float(df[col].median()), 'std': float(df[col].std())}
        else:
            performance_info[f'{name}_available'] = False

    # 关联饲料特征数据
    feed_info = {'available': False, 'features': []}
    if df_feed is not None and len(df_feed) > 0:
        feed_cols = ['cattle_id', 'stats_date'] + [c for c in FEED_FEATURES if c in df_feed.columns]
        df_feed_sub = df_feed[feed_cols].copy()
        df_feed_sub['cattle_id'] = df_feed_sub['cattle_id'].astype(str)
        df['cattle_id'] = df['cattle_id'].astype(str)
        before_merge = len(df)
        df = pd.merge(df, df_feed_sub, left_on=['cattle_id', 'stats_date'], right_on=['cattle_id', 'stats_date'], how='left')
        if len(df) != before_merge:
            print(f"警告：merge 后行数变化 {before_merge} -> {len(df)}，可能存在重复键，执行去重")
            df = df.drop_duplicates(subset=['cattle_id', 'stats_date'])
        print(f"关联饲料数据: {before_merge} -> {len(df)} 条记录")
        available_features = [c for c in FEED_FEATURES if c in df.columns]
        for c in available_features:
            df[c] = df[c].fillna(0)
        feed_info = {'available': True, 'features': available_features, 'scaling': {}}
        print(f"✅ 饲料特征维度: {', '.join(available_features)}")
    else:
        print("⚠️ 无饲料数据，固定效应仅包含品种+牧场")

    # 固定效应设计矩阵：品种 + 牧场 + 饲料特征（饲料连续特征做 z-score 标准化）
    sku_dummies = pd.get_dummies(df['sku_name'], prefix='sku', drop_first=True).astype(int)
    ranch_dummies = pd.get_dummies(df['ranch_name'], prefix='ranch', drop_first=True).astype(int)
    X_parts = [pd.DataFrame({'intercept': 1}, index=df.index), sku_dummies, ranch_dummies]
    available_feed_features = [c for c in FEED_FEATURES if c in df.columns]
    if available_feed_features:
        feed_df = df[available_feed_features].astype(float)
        # 对饲料连续特征做 z-score 标准化
        for c in available_feed_features:
            mean_v = feed_df[c].mean()
            std_v = feed_df[c].std()
            if std_v > 1e-12:
                feed_df[c] = (feed_df[c] - mean_v) / std_v
                feed_info['scaling'][c] = {'mean': float(mean_v), 'std': float(std_v)}
            else:
                feed_info['scaling'][c] = {'mean': float(mean_v), 'std': 1.0}
        X_parts.append(feed_df)
    X_fixed = pd.concat(X_parts, axis=1)
    print(f"✅ 固定效应：品种({len(sku_dummies.columns)}) + 牧场({len(ranch_dummies.columns)}) + 饲料({len(available_feed_features)})")

    cattle_ids = df['cattle_id'].astype('category').cat.codes.values
    n_cattle = df['cattle_id'].nunique()
    print(f"最终建模数据: {len(df)} 条记录, {n_cattle} 头牛, {len(X_fixed.columns)} 个固定效应")

    return {
        'df': df, 'X': X_fixed.values, 'X_cols': X_fixed.columns.tolist(),
        'cattle_idx': cattle_ids, 'n_cattle': n_cattle,
        'age': df['time_variable'].values.astype(float), 'weight': df['current_weight'].values.astype(float),
        'stall_ids': df['stall_id'].unique().tolist(), 'customer_ids': df['customer_id'].unique().tolist(),
        'sku_names': df['sku_name'].unique().tolist(), 'cattle_ids': df['cattle_id'].unique().tolist(),
        'stage_info': stage_info, 'performance_info': performance_info, 'time_source': time_source,
        'feed_info': feed_info
    }


def fit_gompertz_nlme_pymc(data: Dict, n_draws: int = N_DRAWS, n_tune: int = N_TUNE, target_accept: float = TARGET_ACCEPT) -> Dict:
    """使用 PyMC 拟合 Gompertz NLME 模型"""
    with pm.Model() as nlme_model:
        n_fixed = data['X'].shape[1]

        # 固定效应先验：intercept 用先验均值，其余系数用 0
        mu_A = np.zeros(n_fixed)
        mu_A[0] = PRIOR_A_MU
        beta_A = pm.Normal('beta_log_A', mu=mu_A, sigma=PRIOR_A_SIGMA, shape=n_fixed)

        mu_B = np.zeros(n_fixed)
        mu_B[0] = PRIOR_B_MU
        beta_B = pm.Normal('beta_log_B', mu=mu_B, sigma=PRIOR_B_SIGMA, shape=n_fixed)

        mu_C = np.zeros(n_fixed)
        mu_C[0] = PRIOR_C_MU
        beta_C = pm.Normal('beta_C', mu=mu_C, sigma=PRIOR_C_SIGMA, shape=n_fixed)

        # 随机效应
        chol, _, _ = pm.LKJCholeskyCov('chol_cov', n=3, eta=LKJ_ETA, sd_dist=pm.Exponential.dist(0.8, shape=3))
        Sigma = pm.Deterministic('Sigma', chol @ chol.T)
        u = pm.MvNormal('u', mu=0, chol=chol, shape=(data['n_cattle'], 3))

        # 参数组合：固定效应 + 随机效应
        log_A = pm.math.dot(data['X'], beta_A) + u[data['cattle_idx'], 0]
        log_B = pm.math.dot(data['X'], beta_B) + u[data['cattle_idx'], 1]
        C = pm.math.dot(data['X'], beta_C) + u[data['cattle_idx'], 2]
        A = pm.math.exp(log_A)
        B = pm.math.exp(log_B)

        # Gompertz 预测 + 似然
        t = data['age']
        mu = A * pm.math.exp(-pm.math.exp(-B * (t - C)))
        sigma = pm.HalfNormal('sigma', sigma=50)
        pm.Normal('y_obs', mu=mu, sigma=sigma, observed=data['weight'])

        trace = pm.sample(draws=n_draws, tune=n_tune, chains=CHAINS, cores=N_JOBS, target_accept=target_accept, return_inferencedata=True, progressbar=True, max_treedepth=12)

    return {'trace': trace, 'data': data, 'model_type': 'pymc'}


def extract_nlme_results(results: Dict) -> pd.DataFrame:
    """从 NLME 拟合结果中提取结构化 DataFrame"""
    if 'error' in results:
        return pd.DataFrame([{'result_type': 'error', 'parameter': results['error'], 'estimate': None}])

    rows = []
    trace, data = results['trace'], results['data']

    # 固定效应
    for i, col in enumerate(data['X_cols']):
        for param_name, beta_name in [('log_A', 'beta_log_A'), ('log_B', 'beta_log_B'), ('C', 'beta_C')]:
            post = trace.posterior[beta_name].values
            rows.append({
                'result_type': 'fixed_effect', 'parameter': param_name, 'level': col,
                'estimate': float(np.mean(post[:, :, i])), 'std_error': float(np.std(post[:, :, i])),
                'ci_lower': float(np.percentile(post[:, :, i], 2.5)), 'ci_upper': float(np.percentile(post[:, :, i], 97.5))
            })

    # 方差分解
    Sigma_post = trace.posterior['Sigma'].values
    for name, idx in [('u_log_A_variance', 0), ('u_log_B_variance', 1), ('u_C_variance', 2)]:
        rows.append({'result_type': 'variance', 'parameter': name, 'estimate': float(np.mean(Sigma_post[:, :, idx, idx]))})

    # 随机效应（前100头）
    u_post = trace.posterior['u'].values
    for i, cattle_id in enumerate(data['cattle_ids'][:100]):
        rows.append({'result_type': 'random_effect', 'parameter': 'u_log_A', 'cattle_id': cattle_id, 'estimate': float(np.mean(u_post[:, :, i, 0])), 'std_error': float(np.std(u_post[:, :, i, 0]))})
        rows.append({'result_type': 'random_effect', 'parameter': 'u_log_B', 'cattle_id': cattle_id, 'estimate': float(np.mean(u_post[:, :, i, 1])), 'std_error': float(np.std(u_post[:, :, i, 1]))})
        rows.append({'result_type': 'random_effect', 'parameter': 'u_C', 'cattle_id': cattle_id, 'estimate': float(np.mean(u_post[:, :, i, 2])), 'std_error': float(np.std(u_post[:, :, i, 2]))})

    return pd.DataFrame(rows)


def model(dbt, session):
    """DBT Python 模型主入口"""
    dbt.config(
        materialized="table",
        description="Gompertz NLME 多维度生长曲线混合效应模型结果（PyMC 贝叶斯版，含饲料维度）",
        tags=["ranch", "ads", "model", "nlme", "gompertz", "growth_curve", "python", "feed", "pymc"]
    )

    df_input = dbt.ref("dws_ranch_cattle_adg_agg_i").to_df()
    if len(df_input) == 0:
        return pd.DataFrame({'model_status': ['no_data'], 'result_type': ['error'], 'message': ['Input data is empty']})

    print(f"输入数据规模: {len(df_input)} 条记录, {df_input['cattle_id'].nunique()} 头牛")

    required_fields = ['cattle_id', 'current_weight', 'age_days', 'days_since_entry', 'stall_id', 'customer_id', 'sku_name', 'ranch_name']
    missing_fields = [f for f in required_fields if f not in df_input.columns]
    if missing_fields:
        print(f"错误：缺少必需字段: {', '.join(missing_fields)}")
        return pd.DataFrame({'model_status': ['missing_fields'], 'result_type': ['error'], 'message': [f'Missing: {", ".join(missing_fields)}']})

    # 读取饲料结构数据
    try:
        df_feed = dbt.ref("dws_ranch_cattle_feed_breakdown_agg_i").to_df()
        print(f"饲料数据规模: {len(df_feed)} 条记录")
    except Exception as e:
        print(f"读取饲料数据失败: {e}, 跳过饲料维度")
        df_feed = None

    nlme_data = prepare_nlme_data(df_input, df_feed)
    if nlme_data is None:
        return pd.DataFrame({'model_status': ['insufficient_data'], 'result_type': ['error'], 'message': ['Not enough valid data']})

    config = validate_and_adjust_config(len(nlme_data['df']), nlme_data['n_cattle'])
    print(f"模型配置: {config}")

    try:
        results = fit_gompertz_nlme_pymc(nlme_data, n_draws=config['n_draws'], n_tune=config['n_tune'])
        print("PyMC模型拟合成功")
    except Exception as e:
        print(f"PyMC fitting failed: {e}")
        df_err = pd.DataFrame({
            'model_status': ['pymc_failed'],
            'result_type': ['error'],
            'parameter': [str(e)],
            'estimate': [None],
            'n_individuals': [nlme_data['n_cattle']],
            'fit_timestamp': [pd.Timestamp.now()],
            'time_source': [nlme_data.get('time_source', 'unknown')]
        })
        if 'stage_info' in nlme_data:
            df_err['stage_data_available'] = nlme_data['stage_info'].get('available', False)
        if 'performance_info' in nlme_data:
            df_err['adg_data_available'] = nlme_data['performance_info'].get('adg_available', False)
            df_err['fcr_data_available'] = nlme_data['performance_info'].get('fcr_available', False)
        if 'feed_info' in nlme_data:
            df_err['feed_data_available'] = nlme_data['feed_info'].get('available', False)
        return df_err

    df_results = extract_nlme_results(results)

    # 元数据
    df_results['model_status'] = 'success'
    df_results['model_type'] = results.get('model_type', 'unknown')
    df_results['n_individuals'] = nlme_data['n_cattle']
    df_results['fit_timestamp'] = pd.Timestamp.now()
    df_results['time_source'] = nlme_data.get('time_source', 'unknown')

    if 'stage_info' in nlme_data:
        df_results['stage_data_available'] = nlme_data['stage_info'].get('available', False)
    if 'performance_info' in nlme_data:
        df_results['adg_data_available'] = nlme_data['performance_info'].get('adg_available', False)
        df_results['fcr_data_available'] = nlme_data['performance_info'].get('fcr_available', False)
    if 'feed_info' in nlme_data:
        df_results['feed_data_available'] = nlme_data['feed_info'].get('available', False)

    diagnostics = log_model_diagnostics(results['trace'], nlme_data)
    for key, value in diagnostics.items():
        df_results[f'diag_{key}'] = value

    print(f"模型结果生成完毕: {len(df_results)} 条记录")
    return df_results
