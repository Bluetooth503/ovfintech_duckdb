"""
ads_ranch_cattle_gompertz_nlme_pymc_v2 - Gompertz NLME v2: 拐点优先采样 + C 紧约束先验

v1 问题: 称重间隔稀疏(62%>90天)，拐点区间(100-300天)仅15.4%牛只有覆盖，
        导致个体级拐点日龄C不可识别，u_C方差失控，模型不收敛。

v2 优化:
  1. 采样策略: 优先选择拐点区间有观测的牛只，提高C参数的可识别性
  2. 先验约束: u_C 的 sd 用 HalfNormal(30) 紧约束到 ±30 天
  3. 保留三参数随机效应 (A, b, C)
"""
import warnings
warnings.filterwarnings("ignore", category=FutureWarning)
from typing import Dict, Optional
import numpy as np
import pandas as pd
import pytensor
pytensor.config.mode = 'NUMBA'
import pymc as pm
import arviz as az


# ---------- 数据质量控制 ----------
MIN_OBS_PER_CATTLE = 5                 # 单头牛最小观测数（3参数模型数学要求）
MONO_TOLERANCE_KG = 10                 # 单调性容差（kg），允许小幅测量误差

# ---------- 拐点优先采样控制 ----------
MAX_CATTLE_FOR_MODELING = 200          # 最大建模牛只数
INFLECTION_AGE_RANGE = (100, 300)      # 拐点区间日龄范围（天）

# ---------- MCMC 采样参数 ----------
N_DRAWS = 500                          # 采样次数
N_TUNE = 1000                          # 预烧期次数
TARGET_ACCEPT = 0.9                    # 目标接受率
CHAINS = 4                             # MCMC 链数量
N_JOBS = 4                             # 并行作业数
MAX_TREE_DEPTH = 10                    # NUTS最大树深度

# ---------- 模型先验超参数（基于中国肉牛文献优化） ----------
PRIOR_A_MU = np.log(650)
PRIOR_A_SIGMA = 1.0
PRIOR_B_MU = np.log(0.015)
PRIOR_B_SIGMA = 0.5
PRIOR_C_MU = 225
PRIOR_C_SIGMA = 30
LKJ_ETA = 1.0

# ---------- 随机效应先验 ----------
# A/b 宽松 (HalfNormal sigma=1.25 ≈ Exponential(0.8) 均值)
# C 紧约束 (HalfNormal sigma=30, 个体拐点偏差 ±30 天)
RE_SD_SIGMA = [1.25, 1.25, 30]

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
        config.update({'n_draws': max(N_DRAWS // 2, 500), 'n_tune': max(N_TUNE // 2, 500), 'chains': max(CHAINS // 4, 4)})
    return config


def log_model_diagnostics(trace, data: Dict) -> Dict:
    """提取 MCMC 采样诊断指标"""
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


def _inflection_priority_sample(df: pd.DataFrame, max_n: int) -> pd.DataFrame:
    """拐点优先采样：优先选择拐点区间有观测的牛只，补充到 max_n 头"""
    inf_lo, inf_hi = INFLECTION_AGE_RANGE

    # 统计每头牛在拐点区间的观测数
    cattle_inf = df.groupby('cattle_id').agg(
        inf_n=('age_days', lambda x: ((x >= inf_lo) & (x <= inf_hi)).sum()),
        n_obs=('cattle_id', 'size')
    ).reset_index()

    cattle_inf_only = cattle_inf[cattle_inf['inf_n'] > 0]['cattle_id'].tolist()
    cattle_no_inf = cattle_inf[cattle_inf['inf_n'] == 0]['cattle_id'].tolist()

    n_inf = len(cattle_inf_only)
    n_no_inf = len(cattle_no_inf)
    print(f"  拐点区间[{inf_lo}-{inf_hi}天]有观测: {n_inf} 头, 无观测: {n_no_inf} 头")

    sampled_ids = []

    if n_inf >= max_n:
        # 拐点有观测的牛只超过配额，按品种×牧场分层采样
        cattle_meta = df[['cattle_id', 'sku_name', 'ranch_name']].drop_duplicates()
        pool = cattle_meta[cattle_meta['cattle_id'].isin(cattle_inf_only)]
        stratum_counts = pool.groupby(['sku_name', 'ranch_name']).size().reset_index(name='n')
        total = stratum_counts['n'].sum()
        stratum_counts['quota'] = (stratum_counts['n'] / total * max_n).round().astype(int).clip(lower=1)
        diff = int(max_n - stratum_counts['quota'].sum())
        if diff > 0:
            idx = stratum_counts['quota'].idxmax()
            stratum_counts.loc[idx, 'quota'] += diff
        elif diff < 0:
            for _ in range(abs(diff)):
                eligible = stratum_counts[stratum_counts['quota'] > 1]
                if len(eligible) == 0:
                    break
                idx = eligible['quota'].idxmax()
                stratum_counts.loc[idx, 'quota'] -= 1
        for _, row in stratum_counts.iterrows():
            p = pool[(pool['sku_name'] == row['sku_name']) & (pool['ranch_name'] == row['ranch_name'])]
            n_sample = min(int(row['quota']), len(p))
            sampled_ids.extend(p['cattle_id'].sample(n=n_sample, random_state=42).tolist())
        print(f"  从 {n_inf} 头拐点覆盖牛只中分层采样 {len(sampled_ids)} 头")
    else:
        # 拐点有观测的不足配额，全部纳入，再从无拐点观测的补充
        sampled_ids = list(cattle_inf_only)
        remaining = max_n - len(sampled_ids)
        if remaining > 0 and n_no_inf > 0:
            cattle_meta = df[['cattle_id', 'sku_name', 'ranch_name']].drop_duplicates()
            pool = cattle_meta[cattle_meta['cattle_id'].isin(cattle_no_inf)]
            stratum_counts = pool.groupby(['sku_name', 'ranch_name']).size().reset_index(name='n')
            total = stratum_counts['n'].sum()
            stratum_counts['quota'] = (stratum_counts['n'] / total * remaining).round().astype(int).clip(lower=1)
            diff = int(remaining - stratum_counts['quota'].sum())
            if diff > 0:
                idx = stratum_counts['quota'].idxmax()
                stratum_counts.loc[idx, 'quota'] += diff
            elif diff < 0:
                for _ in range(abs(diff)):
                    eligible = stratum_counts[stratum_counts['quota'] > 1]
                    if len(eligible) == 0:
                        break
                    idx = eligible['quota'].idxmax()
                    stratum_counts.loc[idx, 'quota'] -= 1
            for _, row in stratum_counts.iterrows():
                p = pool[(pool['sku_name'] == row['sku_name']) & (pool['ranch_name'] == row['ranch_name'])]
                n_sample = min(int(row['quota']), len(p))
                sampled_ids.extend(p['cattle_id'].sample(n=n_sample, random_state=42).tolist())
        print(f"  全部 {n_inf} 头拐点覆盖 + {len(sampled_ids)-n_inf} 头补充 = {len(sampled_ids)} 头")

    # 统计采样结果
    sampled_inf_n = sum(1 for cid in sampled_ids if cid in set(cattle_inf_only))
    print(f"  采样结果: {sampled_inf_n}/{len(sampled_ids)} 头有拐点区间观测 ({sampled_inf_n*100/len(sampled_ids):.1f}%)")

    return df[df['cattle_id'].isin(sampled_ids)]


def prepare_nlme_data(df_adg: pd.DataFrame, df_feed: Optional[pd.DataFrame] = None) -> Optional[Dict]:
    """准备 NLME 建模数据，拐点优先采样"""
    df = df_adg.copy()
    df = df[(df['current_weight'] > 0) & df['cattle_id'].notna()]
    print(f"初始数据规模: {len(df)} 条记录, {df['cattle_id'].nunique()} 头牛")

    # 时间维度
    age_coverage = df['age_days'].notna().mean()
    entry_coverage = df['days_since_entry'].notna().mean()
    if age_coverage > 0.5:
        df['time_variable'] = df['age_days']
        time_source = 'age_days'
        print(f"使用age_days作为时间变量，覆盖率: {age_coverage:.1%}")
    elif entry_coverage > 0.5:
        df['time_variable'] = df['days_since_entry']
        time_source = 'days_since_entry'
        print(f"使用days_since_entry替代，覆盖率: {entry_coverage:.1%}")
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

    # 近似单调性过滤
    def is_approx_monotonic(g: pd.DataFrame) -> bool:
        w = g.sort_values('time_variable')['current_weight'].values
        return bool(np.all(np.diff(w) >= -MONO_TOLERANCE_KG))

    monotonic_cattle = df.groupby('cattle_id').apply(is_approx_monotonic).pipe(lambda s: s[s].index)
    df = df[df['cattle_id'].isin(monotonic_cattle)]
    print(f"排除体重非单调递增的牛只后（容差{MONO_TOLERANCE_KG}kg）: {df['cattle_id'].nunique()} 头")

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

    if len(df) == 0:
        print("错误：过滤后没有剩余数据")
        return None

    # ====== v2 核心改动：拐点优先采样 ======
    if df['cattle_id'].nunique() > MAX_CATTLE_FOR_MODELING:
        print(f"[v2] 拐点优先采样（从 {df['cattle_id'].nunique()} 头中选 {MAX_CATTLE_FOR_MODELING} 头）:")
        df = _inflection_priority_sample(df, MAX_CATTLE_FOR_MODELING)
        print(f"[v2] 采样完成: {df['cattle_id'].nunique()} 头牛，覆盖 {df['sku_name'].nunique()} 品种 × {df['ranch_name'].nunique()} 牧场")
    else:
        print(f"保留全部 {df['cattle_id'].nunique()} 头牛")

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
            print(f"警告：merge 后行数变化 {before_merge} -> {len(df)}，执行去重")
            df = df.drop_duplicates(subset=['cattle_id', 'stats_date'])
        print(f"关联饲料数据: {before_merge} -> {len(df)} 条记录")
        available_features = [c for c in FEED_FEATURES if c in df.columns]
        for c in available_features:
            df[c] = df[c].fillna(0)
        feed_info = {'available': True, 'features': available_features, 'scaling': {}}
        print(f"  饲料特征维度: {', '.join(available_features)}")
    else:
        print("  无饲料数据，固定效应仅包含品种+牧场")

    # 固定效应设计矩阵
    sku_dummies = pd.get_dummies(df['sku_name'], prefix='sku', drop_first=True).astype(int)
    ranch_dummies = pd.get_dummies(df['ranch_name'], prefix='ranch', drop_first=True).astype(int)
    X_parts = [pd.DataFrame({'intercept': 1}, index=df.index), sku_dummies, ranch_dummies]
    available_feed_features = [c for c in FEED_FEATURES if c in df.columns]
    if available_feed_features:
        feed_df = df[available_feed_features].astype(float)
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
    print(f"  固定效应：品种({len(sku_dummies.columns)}) + 牧场({len(ranch_dummies.columns)}) + 饲料({len(available_feed_features)})")

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


def fit_gompertz_nlme_pymc(data: Dict, n_draws: int = N_DRAWS, n_tune: int = N_TUNE, target_accept: float = TARGET_ACCEPT, chains: int = CHAINS) -> Dict:
    """使用 PyMC 拟合 Gompertz NLME 模型（v2: C 紧约束先验）"""
    with pm.Model() as nlme_model:
        n_fixed = data['X'].shape[1]

        # 固定效应先验
        mu_A = np.zeros(n_fixed); mu_A[0] = PRIOR_A_MU
        beta_A = pm.Normal('beta_log_A', mu=mu_A, sigma=PRIOR_A_SIGMA, shape=n_fixed)

        mu_B = np.zeros(n_fixed); mu_B[0] = PRIOR_B_MU
        beta_B = pm.Normal('beta_log_B', mu=mu_B, sigma=PRIOR_B_SIGMA, shape=n_fixed)

        mu_C = np.zeros(n_fixed); mu_C[0] = PRIOR_C_MU
        beta_C = pm.Normal('beta_C', mu=mu_C, sigma=PRIOR_C_SIGMA, shape=n_fixed)

        # 随机效应（非中心参数化）
        # v2: C 的 sd 紧约束到 ±30 天，防止方差失控
        chol, _, _ = pm.LKJCholeskyCov('chol_cov', n=3, eta=LKJ_ETA,
                                       sd_dist=pm.HalfNormal.dist(sigma=RE_SD_SIGMA, shape=3))
        Sigma = pm.Deterministic('Sigma', chol @ chol.T)
        z = pm.Normal('z', mu=0, sigma=1, shape=(data['n_cattle'], 3))
        u = pm.Deterministic('u', z @ chol.T)

        # 参数组合
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

        trace = pm.sample(
            draws=n_draws, tune=n_tune, chains=chains, cores=N_JOBS,
            target_accept=target_accept, return_inferencedata=True,
            progressbar=True, max_treedepth=MAX_TREE_DEPTH,
        )

    return {'trace': trace, 'data': data, 'model_type': 'pymc_v2'}


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
        description="Gompertz NLME v2: 拐点优先采样 + C紧约束先验 + 三参数随机效应",
        tags=["ranch", "ads", "model", "nlme", "gompertz", "growth_curve", "python", "feed", "pymc", "v2"]
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
        results = fit_gompertz_nlme_pymc(nlme_data, n_draws=config['n_draws'], n_tune=config['n_tune'], chains=config['chains'])
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
