"""
ads_ranch_cattle_gompertz_nlme_simplified - Gompertz NLME 多维度生长曲线混合效应模型（简化两阶段版）

基于 dws_ranch_cattle_adg_agg_i 数据
固定效应：品种(sku_name)、牧场(ranch_name)、饲料结构特征；随机效应：个体层面 A/B/C 参数偏差
方法：第一阶段 curve_fit 个体拟合，第二阶段 OLS 固定效应估计
"""
import warnings
from typing import Dict, Optional
import numpy as np
import pandas as pd
from scipy.optimize import curve_fit

warnings.filterwarnings("ignore")

# ---------- 数据质量控制 ----------
MIN_CATTLE_PER_STALL = 10              # 栏位最小样本数
MIN_OBS_PER_CATTLE = 5                 # 单头牛最小观测数（3参数模型数学要求，≥4避免过拟合）

# ---------- 性能控制 ----------
MAX_CATTLE_FOR_MODELING = 1000         # 最大建模牛只数，simplified 版计算快可适当放宽

# ---------- 饲料特征列 ----------
FEED_FEATURES = [
    'concentrate_ratio',
    'roughage_ratio',
    'period_avg_feed_intake',
    'feed_cost_per_kg_gain',
]


def gompertz(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    """Gompertz 生长曲线: W(t) = A * exp(-exp(-B*(t-C)))"""
    return A * np.exp(-np.exp(-B * (t - C)))


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
        print(f"关联饲料数据: {before_merge} -> {len(df)} 条记录")
        available_features = [c for c in FEED_FEATURES if c in df.columns]
        for c in available_features:
            df[c] = df[c].fillna(0)
        feed_info = {'available': True, 'features': available_features}
        print(f"✅ 饲料特征维度: {', '.join(available_features)}")
    else:
        print("⚠️ 无饲料数据，固定效应仅包含品种+牧场")

    # 固定效应设计矩阵：品种 + 牧场 + 饲料特征
    sku_dummies = pd.get_dummies(df['sku_name'], prefix='sku', drop_first=True).astype(int)
    ranch_dummies = pd.get_dummies(df['ranch_name'], prefix='ranch', drop_first=True).astype(int)
    X_parts = [pd.DataFrame({'intercept': 1}, index=df.index), sku_dummies, ranch_dummies]
    available_feed_features = [c for c in FEED_FEATURES if c in df.columns]
    if available_feed_features:
        feed_df = df[available_feed_features].astype(float)
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


def fit_gompertz_nlme_simplified(data: Dict) -> Dict:
    """简化两阶段 NLME：个体 curve_fit 拟合 + OLS 固定效应估计"""
    df = data['df']
    individual_params = {}

    for cattle_id, group in df.groupby('cattle_id'):
        if len(group) < MIN_OBS_PER_CATTLE:
            continue
        t, y = group['time_variable'].values.astype(float), group['current_weight'].values.astype(float)
        b_init = max(0.001, min(0.1, group['period_adg'].mean() / max(y.max(), 1))) if data['performance_info'].get('adg_available') else 0.01
        a_upper = group['stage_end_weight'].max() * 1.5 if group['stage_end_weight'].notna().any() else max(y) * 1.5
        try:
            popt, _ = curve_fit(gompertz, t, y, p0=[max(y) * 1.2, b_init, 200], bounds=([0, 0, 50], [a_upper, 0.1, 500]), maxfev=10000)
            individual_params[cattle_id] = {
                'A': popt[0], 'B': popt[1], 'C': popt[2],
                'log_A': np.log(popt[0]), 'log_B': np.log(popt[1]),
                'sku': group['sku_name'].iloc[0], 'ranch': group['ranch_name'].iloc[0],
                'customer': group['customer_id'].iloc[0], 'stage': group['stage_name'].iloc[0],
                'n_observations': len(group)
            }
            # 附加饲料特征（取个体均值）
            available_feed_features = data['feed_info'].get('features', [])
            for feat in available_feed_features:
                individual_params[cattle_id][feat] = float(group[feat].mean())
        except Exception:
            continue

    n_fitted = len(individual_params)
    print(f"个体拟合完成: {n_fitted} 成功")
    if n_fitted < 10:
        return {'error': 'Insufficient data for modeling'}

    # OLS 固定效应估计
    params_df = pd.DataFrame(individual_params).T
    sku_dummies = pd.get_dummies(params_df['sku'], prefix='sku', drop_first=True).astype(int)
    ranch_dummies = pd.get_dummies(params_df['ranch'], prefix='ranch', drop_first=True).astype(int)
    X_parts = [pd.DataFrame({'intercept': 1}, index=params_df.index), sku_dummies, ranch_dummies]
    available_feed_features = data['feed_info'].get('features', [])
    if available_feed_features:
        feed_df = params_df[available_feed_features].astype(float)
        X_parts.append(feed_df)
    X = pd.concat(X_parts, axis=1)

    def ols_fit(y, X_mat):
        """OLS 回归"""
        X_np = X_mat.values.astype(float)
        y = y.astype(float)
        beta = np.linalg.solve(X_np.T @ X_np + 0.001 * np.eye(X_np.shape[1]), X_np.T @ y)
        return beta, y - X_np @ beta, X_mat.columns.tolist()

    beta_A, resid_A, cols_A = ols_fit(params_df['log_A'].values, X)
    beta_B, resid_B, cols_B = ols_fit(params_df['log_B'].values, X)
    beta_C, resid_C, cols_C = ols_fit(params_df['C'].values, X)

    return {
        'model_type': 'simplified',
        'fixed_effects': {'log_A': {'beta': beta_A, 'cols': cols_A}, 'log_B': {'beta': beta_B, 'cols': cols_B}, 'C': {'beta': beta_C, 'cols': cols_C}},
        'random_effects_variance': {'u_log_A': np.var(resid_A), 'u_log_B': np.var(resid_B), 'u_C': np.var(resid_C)},
        'individual_residuals': {'log_A': dict(zip(params_df.index, resid_A)), 'log_B': dict(zip(params_df.index, resid_B)), 'C': dict(zip(params_df.index, resid_C))},
        'n_individuals': n_fitted
    }


def extract_nlme_results(results: Dict) -> pd.DataFrame:
    """从 NLME 拟合结果中提取结构化 DataFrame"""
    if 'error' in results:
        return pd.DataFrame([{'result_type': 'error', 'parameter': results['error'], 'estimate': None}])

    rows = []
    fe = results['fixed_effects']
    for param in ['log_A', 'log_B', 'C']:
        beta, cols = fe[param]['beta'], fe[param]['cols']
        for i, col in enumerate(cols):
            rows.append({'result_type': 'fixed_effect', 'parameter': param, 'level': col, 'estimate': float(beta[i]), 'std_error': None, 'ci_lower': None, 'ci_upper': None})
    for param, val in results['random_effects_variance'].items():
        rows.append({'result_type': 'variance', 'parameter': param, 'estimate': float(val)})
    for cattle_id, val in list(results['individual_residuals']['log_A'].items())[:100]:
        rows.append({'result_type': 'random_effect', 'parameter': 'u_log_A', 'cattle_id': cattle_id, 'estimate': float(val), 'std_error': None})

    return pd.DataFrame(rows)


def model(dbt, session):
    """DBT Python 模型主入口"""
    dbt.config(
        materialized="table",
        description="Gompertz NLME 多维度生长曲线混合效应模型结果（简化两阶段版，含饲料维度）",
        tags=["ranch", "ads", "model", "nlme", "gompertz", "growth_curve", "python", "feed", "simplified"]
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

    results = fit_gompertz_nlme_simplified(nlme_data)
    print("简化两阶段模型拟合成功")

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

    print(f"模型结果生成完毕: {len(df_results)} 条记录")
    return df_results
