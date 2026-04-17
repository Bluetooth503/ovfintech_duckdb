"""ads_ranch_cattle_gompertz_nlme_simplified_v2 - 肉牛生长曲线简化模型（按品种×牧场共享拐点版）

【这个模型是干嘛的？】
我们想根据牛的历史称重记录，画出每头牛的"长重曲线"，看看：
- 这头牛最终能长到多重？
- 它什么时候进入生长最快的阶段？
- 不同品种、不同牧场、不同饲料对长重有没有影响？

【为什么叫"按品种×牧场共享拐点"？】
牛的生长曲线像个 S：先慢、再快、再慢。中间那个"开始猛长"的点叫"拐点"。
我们发现：
- 如果让每头牛自己估拐点，数据太稀疏，经常会算出"拐点在出生前"这种荒谬结果；
- 但如果让所有牛共享同一个拐点，又忽略了西门塔尔和安格斯、北方育肥和南方放牧的生长节奏本来就不同。

所以折中方案是：**同一个品种、同一个牧场的牛共享一个拐点日龄**。
大组合（≥50头）用自己的数据单独算拐点，小组合回退到文献先验值 225 天。

【建模三步走】
1. 按品种×牧场估拐点：比如"西门塔尔×八里罕"一起画条曲线，"西门塔尔×甘肃迅驰"一起画条曲线，分别算拐点
2. 逐头画曲线：每头牛固定用自己"品种+牧场"组合的 C，只看自己的称重记录，算出成年体重 A 和长速 B
3. 找差异原因：用线性回归分析，为什么这些 A 和 B 不一样？品种、牧场、饲料有没有影响？

【结果怎么看？】
- "固定效应" = 群体规律。比如"源里牧场的牛成年体重比基准牧场低 20%"
- "随机效应" = 个体差异。比如"这头牛比同牧场同品种的牛预计还要大 100kg"
- "方差" = 个体之间差异有多大

【注意】
饲料系数目前因为数据内部变化太小，参考价值有限，主要用来看品种和牧场差异。
"""
import warnings
from typing import Dict, Optional
import numpy as np
import pandas as pd
from scipy.optimize import curve_fit

warnings.filterwarnings("ignore")

# ---------- 数据门槛 ----------
MIN_CATTLE_PER_STALL = 0               # 不限制栏位最小牛只数，让更多数据进入模型
MIN_OBS_PER_CATTLE = 3                 # 一头牛至少要有 3 条称重记录（降低门槛让更多牛进入模型，simplified 版有过滤机制兜底）

# ---------- 性能控制 ----------
MAX_CATTLE_FOR_MODELING = 100000       # 最多分析 10 万头牛，simplified 版计算快，支撑全量分析

# ---------- 共享拐点参数 ----------
C_GLOBAL_BOUNDS = (100, 300)           # 拐点日龄只能在 100~300 天之间
C_GLOBAL_FALLBACK = 180.0              # 如果数据算不出来合理的拐点，就默认用 180 天（中国肉牛常见拐点）
PRIOR_C_MU = 225.0                     # 拐点日龄文献先验均值（225天，文献[1]194天/文献[2]254天均值）
MIN_CATTLE_PER_GROUP_FOR_C = 50        # 一个品种×牧场组合至少要有 50 头牛才单独估计拐点 C，否则回退
MIN_CATTLE_PER_RANCH = 50              # 一个牧场至少要有 50 头牛才进入 OLS 固定效应回归，小牧场合并到基准

# ---------- 饲料特征列 ----------
FEED_FEATURES = [
    'concentrate_ratio',        # 精料占比
    'roughage_ratio',           # 粗料占比
    'period_avg_feed_intake',   # 平均采食量
    'feed_cost_per_kg_gain',    # 每公斤增重的饲料成本
]


def gompertz(t: np.ndarray, A: float, B: float, C: float) -> np.ndarray:
    """
    Gompertz 生长曲线公式：W(t) = A * exp(-exp(-B*(t-C)))

    通俗解释：
    - A：这头牛最终能长到多重（天花板体重）
    - B：长得有多快（B 越大，猛长期越陡）
    - C：哪天进入猛长期（拐点日龄）
    - t：当前日龄
    """
    return A * np.exp(-np.exp(-B * (t - C)))


def prepare_nlme_data(df_adg: pd.DataFrame, df_feed: Optional[pd.DataFrame] = None) -> Optional[Dict]:
    """
    数据清洗和准备。
    把原始称重记录整理成模型能用的格式，去掉太少的牛、太小的栏位。
    """
    df = df_adg.copy()
    df = df[(df['current_weight'] > 0) & df['cattle_id'].notna()]
    print(f"初始数据规模: {len(df)} 条记录, {df['cattle_id'].nunique()} 头牛")

    # 时间维度：优先用实际日龄 age_days，没有的话用进场天数
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

    # 只保留称重记录够多的牛（至少 4 次，否则拟合曲线就是瞎猜）
    valid_cattle = df.groupby('cattle_id').size().pipe(lambda s: s[s >= MIN_OBS_PER_CATTLE]).index
    df = df[df['cattle_id'].isin(valid_cattle)]
    print(f"筛选观测数≥{MIN_OBS_PER_CATTLE}的牛只: {df['cattle_id'].nunique()} 头")

    # 填充分类字段（防止空值导致分组出错）
    for col, tag in [('stall_id', 'stall'), ('customer_id', 'customer'), ('sku_name', 'sku'), ('ranch_name', 'ranch')]:
        df[col] = df[col].fillna(f'unknown_{tag}').astype(str)

    # 生长阶段信息
    if df['stage_name'].notna().any():
        df['stage_name'] = df['stage_name'].fillna('unknown_stage').astype(str)
        stage_info = {'available': True, 'unique_stages': df['stage_name'].unique().tolist(), 'n_stages': df['stage_name'].nunique()}
        print(f"发现生长阶段信息: {stage_info['n_stages']} 个不同阶段")
    else:
        df['stage_name'] = 'unknown_stage'
        stage_info = {'available': False, 'n_stages': 0}

    # 栏位筛选（当前 MIN_CATTLE_PER_STALL=0，不限制）
    if MIN_CATTLE_PER_STALL > 0:
        valid_stalls = df.groupby('stall_id')['cattle_id'].nunique().pipe(lambda s: s[s >= MIN_CATTLE_PER_STALL]).index
        df = df[df['stall_id'].isin(valid_stalls)]
        print(f"筛选有效栏位(≥{MIN_CATTLE_PER_STALL}头): {len(valid_stalls)} 个栏位")
    else:
        print(f"不限制栏位最小牛只数，保留全部 {df['stall_id'].nunique()} 个栏位")

    if len(df) == 0:
        print("错误：过滤后没有剩余数据")
        return None

    # 如果牛太多，按品种×牧场组合分层抽样，保证各组合都有代表
    if df['cattle_id'].nunique() > MAX_CATTLE_FOR_MODELING:
        cattle_meta = df[['cattle_id', 'sku_name', 'ranch_name']].drop_duplicates()
        cattle_meta['group'] = cattle_meta['sku_name'] + ' x ' + cattle_meta['ranch_name']
        group_counts = cattle_meta['group'].value_counts()
        total = len(cattle_meta)
        # 按比例分配配额，每个组合至少留 1 头
        quotas = (group_counts / total * MAX_CATTLE_FOR_MODELING).round().astype(int).clip(lower=1)
        # 微调配额，确保总和刚好等于 MAX_CATTLE_FOR_MODELING
        diff = int(MAX_CATTLE_FOR_MODELING - quotas.sum())
        if diff > 0:
            idx = quotas.idxmax()
            quotas.loc[idx] += diff
        elif diff < 0:
            for _ in range(abs(diff)):
                eligible = quotas[quotas > 1]
                if len(eligible) == 0:
                    break
                idx = eligible.idxmax()
                quotas.loc[idx] -= 1
        sampled_ids = []
        for grp, quota in quotas.items():
            pool = cattle_meta[cattle_meta['group'] == grp]['cattle_id']
            n_sample = min(int(quota), len(pool))
            sampled_ids.extend(pool.sample(n=n_sample, random_state=42).tolist())
        df = df[df['cattle_id'].isin(sampled_ids)]
        print(f"按品种×牧场分层采样到 {len(sampled_ids)} 头牛，覆盖 {df['sku_name'].nunique()} 个品种 × {df['ranch_name'].nunique()} 个牧场")

    # 统计 ADG、FCR 等性能指标是否可用
    performance_info = {}
    for col, name in [('period_adg', 'adg'), ('period_fcr', 'fcr')]:
        if col in df.columns and df[col].notna().any():
            performance_info[f'{name}_available'] = True
            performance_info[f'{name}_stats'] = {'mean': float(df[col].mean()), 'median': float(df[col].median()), 'std': float(df[col].std())}
        else:
            performance_info[f'{name}_available'] = False

    # 关联饲料数据
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
        print(f"饲料特征维度: {', '.join(available_features)}")
    else:
        print("无饲料数据，固定效应仅包含品种+牧场")

    # 构建固定效应的设计矩阵（告诉模型哪些因素可能影响生长）
    sku_dummies = pd.get_dummies(df['sku_name'], prefix='sku', drop_first=True).astype(int)
    ranch_dummies = pd.get_dummies(df['ranch_name'], prefix='ranch', drop_first=True).astype(int)
    X_parts = [pd.DataFrame({'intercept': 1}, index=df.index), sku_dummies, ranch_dummies]
    available_feed_features = [c for c in FEED_FEATURES if c in df.columns]
    if available_feed_features:
        feed_df = df[available_feed_features].astype(float)
        X_parts.append(feed_df)
    X_fixed = pd.concat(X_parts, axis=1)
    print(f"固定效应：品种({len(sku_dummies.columns)}) + 牧场({len(ranch_dummies.columns)}) + 饲料({len(available_feed_features)})")

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


def fit_gompertz_nlme_simplified_common_c(data: Dict) -> Dict:
    """
    模型核心：三步法估计生长曲线参数。

    第一步：按品种×牧场组合分别估计拐点日龄 C。大组合（≥50头）用自己的 C，小组合用文献先验 225 天。
    第二步：每头牛固定自己"品种+牧场"组合的 C，只看自己的记录，算出各自的成年体重 A 和长速 B。
    第三步：用线性回归分析，为什么这些 A 和 B 不一样？品种、牧场、饲料有没有影响？
    """
    df = data['df']

    # ---------- 第一步：按品种×牧场组合分别估计拐点 C ----------
    group_C_map = {}
    df['sku_ranch'] = df['sku_name'] + ' x ' + df['ranch_name']
    for group_name, group_df in df.groupby('sku_ranch'):
        n_group_cattle = group_df['cattle_id'].nunique()
        if n_group_cattle < MIN_CATTLE_PER_GROUP_FOR_C:
            # 组合内牛太少，单独估 C 不稳定，直接用文献先验
            group_C_map[group_name] = PRIOR_C_MU
            print(f"  组合 [{group_name}] 牛只太少 ({n_group_cattle} 头)，C 回退到先验值 {PRIOR_C_MU} 天")
            continue

        t_group = group_df['time_variable'].values.astype(float)
        y_group = group_df['current_weight'].values.astype(float)
        a_upper_group = max(y_group) * 2
        try:
            popt_group, _ = curve_fit(
                gompertz, t_group, y_group,
                p0=[max(y_group) * 1.2, 0.01, PRIOR_C_MU],
                bounds=([0, 0, C_GLOBAL_BOUNDS[0]], [a_upper_group, 0.1, C_GLOBAL_BOUNDS[1]]),
                maxfev=10000
            )
            C_group = float(popt_group[2])
            # 如果卡在边界，回退到先验值
            if C_group <= C_GLOBAL_BOUNDS[0] + 5 or C_group >= C_GLOBAL_BOUNDS[1] - 5:
                print(f"  组合 [{group_name}] C 估计落在边界 ({C_group:.1f} 天)，回退到先验值 {PRIOR_C_MU} 天")
                C_group = PRIOR_C_MU
            else:
                print(f"  组合 [{group_name}] C 估计完成: {C_group:.1f} 天 ({n_group_cattle} 头)")
            group_C_map[group_name] = C_group
        except Exception as e:
            print(f"  组合 [{group_name}] C 估计失败 ({e})，回退到先验值 {PRIOR_C_MU} 天")
            group_C_map[group_name] = PRIOR_C_MU

    # 计算一个全局回退 C（用于万一某头牛的组合不在映射里）
    C_global = np.median(list(group_C_map.values())) if group_C_map else PRIOR_C_MU
    print(f"各组合 C 值统计: min={min(group_C_map.values()):.1f}, max={max(group_C_map.values()):.1f}, median={C_global:.1f}")

    # ---------- 第二步：固定品种×牧场 C，逐头牛拟合 A 和 B ----------
    individual_params = {}
    for cattle_id, group in df.groupby('cattle_id'):
        if len(group) < MIN_OBS_PER_CATTLE:
            continue
        t, y = group['time_variable'].values.astype(float), group['current_weight'].values.astype(float)
        group_key = group['sku_name'].iloc[0] + ' x ' + group['ranch_name'].iloc[0]
        C_cattle = group_C_map.get(group_key, C_global)

        # 用平均日增重给一个 B 的初始猜测
        b_init = max(0.001, min(0.1, group['period_adg'].mean() / max(y.max(), 1))) if data['performance_info'].get('adg_available') else 0.01
        a_upper = group['stage_end_weight'].max() * 1.5 if group['stage_end_weight'].notna().any() else max(y) * 1.5
        try:
            # 固定该品种×牧场组合的 C，只让 A 和 B 变
            # B 上界收紧到 0.015（对应最大日增重约 4.5kg/天）
            popt, _ = curve_fit(
                lambda t_, A, B: gompertz(t_, A, B, C_cattle),
                t, y,
                p0=[max(y) * 1.2, b_init],
                bounds=([0, 0], [a_upper, 0.015]),
                maxfev=10000
            )
            individual_params[cattle_id] = {
                'A': popt[0], 'B': popt[1],
                'log_A': np.log(popt[0]), 'log_B': np.log(popt[1]),
                'sku': group['sku_name'].iloc[0], 'ranch': group['ranch_name'].iloc[0],
                'customer': group['customer_id'].iloc[0], 'stage': group['stage_name'].iloc[0],
                'n_observations': len(group)
            }
            # 把这头牛的饲料特征平均值也记录下来（后面回归要用）
            available_feed_features = data['feed_info'].get('features', [])
            for feat in available_feed_features:
                individual_params[cattle_id][feat] = float(group[feat].mean())
        except Exception:
            continue

    n_fitted = len(individual_params)
    print(f"个体 A/B 拟合完成: {n_fitted} 成功")
    if n_fitted < 10:
        return {'error': 'Insufficient data for modeling'}

    # ---------- 第三步：OLS 固定效应估计 ----------
    # 现在每头牛都有自己的 A 和 B 了。我们要回答：牧场能不能解释这些差异？
    params_df = pd.DataFrame(individual_params).T

    # 先去掉 B 极端异常的牛（B 边界收紧到 [1e-4, 0.015]）
    params_df = params_df[(params_df['B'] >= 1e-4) & (params_df['B'] <= 0.015)]
    print(f"过滤极端 B 值后保留: {len(params_df)} 头")
    if len(params_df) < 10:
        return {'error': 'Insufficient data after outlier removal'}

    # 再对 log_B 做一次 2σ 异常值过滤
    log_B_mean = params_df['log_B'].mean()
    log_B_std = params_df['log_B'].std()
    params_df = params_df[params_df['log_B'].between(log_B_mean - 2*log_B_std, log_B_mean + 2*log_B_std)]
    print(f"2σ 过滤 log_B 异常值后保留: {len(params_df)} 头")
    if len(params_df) < 10:
        return {'error': 'Insufficient data after 2-sigma filtering'}

    # 构建回归用的 X 矩阵：截距 + 品种 + 牧场 + 饲料
    sku_dummies = pd.get_dummies(params_df['sku'], prefix='sku', drop_first=True).astype(int)
    ranch_dummies = pd.get_dummies(params_df['ranch'], prefix='ranch', drop_first=True).astype(int)

    # 过滤小样本牧场：牛只数 < 50 的牧场不进入固定效应回归，其牛只并入基准牧场
    ranch_cols_to_keep = [col for col in ranch_dummies.columns if ranch_dummies[col].sum() >= MIN_CATTLE_PER_RANCH]
    dropped_ranches = [col for col in ranch_dummies.columns if col not in ranch_cols_to_keep]
    if dropped_ranches:
        print(f"  过滤小样本牧场（< {MIN_CATTLE_PER_RANCH} 头）: {len(dropped_ranches)} 个，保留 {len(ranch_cols_to_keep)} 个")
        ranch_dummies = ranch_dummies[ranch_cols_to_keep]

    X_parts = [pd.DataFrame({'intercept': 1}, index=params_df.index), sku_dummies, ranch_dummies]
    available_feed_features = data['feed_info'].get('features', [])
    if available_feed_features:
        feed_df = params_df[available_feed_features].astype(float)
        X_parts.append(feed_df)
    X = pd.concat(X_parts, axis=1)

    def ols_fit(y, X_mat):
        """普通最小二乘回归（带一点点正则化防止矩阵奇异）"""
        X_np = X_mat.values.astype(float)
        y = y.astype(float)
        beta = np.linalg.solve(X_np.T @ X_np + 0.001 * np.eye(X_np.shape[1]), X_np.T @ y)
        return beta, y - X_np @ beta, X_mat.columns.tolist()

    # 对 log_A（成年体重）和 log_B（生长速度）分别做回归
    beta_A, resid_A, cols_A = ols_fit(params_df['log_A'].values, X)
    beta_B, resid_B, cols_B = ols_fit(params_df['log_B'].values, X)

    return {
        'model_type': 'simplified_group_c',
        'C_global': C_global,
        'group_C_map': group_C_map,
        'fixed_effects': {
            'log_A': {'beta': beta_A, 'cols': cols_A},
            'log_B': {'beta': beta_B, 'cols': cols_B},
            'C': {'beta': np.array(list(group_C_map.values())), 'cols': list(group_C_map.keys())}
        },
        # 残差的方差 = 个体差异有多大（牧场、饲料解释不了的部分）
        'random_effects_variance': {'u_log_A': np.var(resid_A), 'u_log_B': np.var(resid_B)},
        'individual_residuals': {
            'log_A': dict(zip(params_df.index, resid_A)),
            'log_B': dict(zip(params_df.index, resid_B))
        },
        'n_individuals': n_fitted
    }


def extract_nlme_results(results: Dict) -> pd.DataFrame:
    """
    把模型结果整理成一张大表，方便存在数据库里。
    输出三行核心概念：
    - fixed_effect：群体规律（牧场、品种的平均水平差异）
    - variance：个体间差异有多大
    - random_effect：具体每头牛和群体规律的偏差
    """
    if 'error' in results:
        return pd.DataFrame([{'result_type': 'error', 'parameter': results['error'], 'estimate': None}])

    rows = []
    fe = results['fixed_effects']
    for param in ['log_A', 'log_B', 'C']:
        beta, cols = fe[param]['beta'], fe[param]['cols']
        for i, col in enumerate(cols):
            rows.append({
                'result_type': 'fixed_effect',
                'parameter': param,
                'level': col,
                'estimate': float(beta[i]),
                'std_error': None,
                'ci_lower': None,
                'ci_upper': None
            })
    for param, val in results['random_effects_variance'].items():
        rows.append({'result_type': 'variance', 'parameter': param, 'estimate': float(val)})
    for cattle_id, val in list(results['individual_residuals']['log_A'].items())[:100]:
        rows.append({
            'result_type': 'random_effect',
            'parameter': 'u_log_A',
            'cattle_id': cattle_id,
            'estimate': float(val),
            'std_error': None
        })

    return pd.DataFrame(rows)


def model(dbt, session):
    """
    DBT Python 模型主入口。
    运行完成后会生成一张表，里面包含：
    1. 固定效应：各牧场相对于基准牧场的体重/长速差异
    2. 方差：牛群内部的个体差异程度
    3. 随机效应：前 100 头牛各自偏离群体规律的幅度
    """
    dbt.config(
        materialized="table",
        description="肉牛生长曲线简化模型（按品种×牧场共享拐点）：先给每个品种×牧场组合单独估拐点，再算个体生长参数，最后回归找品种/牧场/饲料影响",
        tags=["ranch", "ads", "model", "nlme", "gompertz", "growth_curve", "python", "feed", "simplified", "sku_c", "v2"]
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

    # ---------- ADS 层数据质量过滤（在 dws 输出基础上进一步清洗） ----------
    before_filter = len(df_input)

    # 1. 称重次数 >= 4
    cattle_obs = df_input.groupby('cattle_id').size()
    valid_cattle_obs = cattle_obs[cattle_obs >= 4].index
    df_input = df_input[df_input['cattle_id'].isin(valid_cattle_obs)]

    # 2. 称重跨度 >= 150 天（且 age_days > 0）
    if 'age_days' in df_input.columns:
        span_stats = df_input[df_input['age_days'] > 0].groupby('cattle_id')['age_days'].agg(['min', 'max'])
        valid_cattle_span = span_stats[span_stats['max'] - span_stats['min'] >= 150].index
        df_input = df_input[df_input['cattle_id'].isin(valid_cattle_span)]

    # 3. 100-300 天拐点区间至少有一次称重
    if 'age_days' in df_input.columns:
        inflection_stats = df_input.groupby('cattle_id')['age_days'].apply(lambda x: ((x >= 100) & (x <= 300)).any())
        valid_cattle_inflection = inflection_stats[inflection_stats].index
        df_input = df_input[df_input['cattle_id'].isin(valid_cattle_inflection)]

    # 4. 体重近似单调递增（容差 10kg）
    def is_approx_monotonic(g):
        w = g.sort_values('age_days')['current_weight'].values
        return bool(np.all(np.diff(w) >= -10))

    if 'age_days' in df_input.columns and df_input['age_days'].notna().any():
        monotonic_cattle = df_input.groupby('cattle_id').apply(is_approx_monotonic).pipe(lambda s: s[s].index)
        df_input = df_input[df_input['cattle_id'].isin(monotonic_cattle)]

    print(f"ADS层数据过滤: {before_filter} 条记录 -> {len(df_input)} 条记录, {df_input['cattle_id'].nunique()} 头牛")
    if len(df_input) == 0:
        return pd.DataFrame({'model_status': ['insufficient_data'], 'result_type': ['error'], 'message': ['All data filtered out by quality checks']})

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

    results = fit_gompertz_nlme_simplified_common_c(nlme_data)
    print("简化两阶段模型（共享 C）拟合成功")

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
