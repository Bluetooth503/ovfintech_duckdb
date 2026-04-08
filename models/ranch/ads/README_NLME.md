# Gompertz NLME 模型使用说明

## 模型文件

| 文件 | 说明 |
|------|------|
| `ads_ranch_cattle_gompertz_nlme.py` | **核心NLME模型**，使用PyMC拟合Gompertz混合效应模型 |
| `ads_ranch_nlme_effects_pivot.sql` | 固定效应透视表，展示品种/牧场对生长参数的影响 |
| `ads_ranch_nlme_variance_analysis.sql` | 方差分解分析表 |
| `ads_ranch_nlme_ranch_efficiency.sql` | 牧场效率排名与改进潜力分析 |

## 快速开始

### 1. 安装依赖

```bash
pip install pymc arviz pandas
```

### 2. 运行模型

```bash
cd /Users/enlai/ovfintech_duckdb

# 运行核心NLME模型（需要几分钟）
dbt run -s ads_ranch_cattle_gompertz_nlme

# 运行下游分析表
dbt run -s ads_ranch_nlme_effects_pivot
dbt run -s ads_ranch_nlme_variance_analysis
dbt run -s ads_ranch_nlme_ranch_efficiency
```

## 模型输出说明

### ads_ranch_cattle_gompertz_nlme

NLME 模型原始结果，包含：
- `fixed_effect`: 固定效应（品种、牧场的系统影响）
- `random_effect`: 随机效应（个体差异）
- `variance`: 方差分量

### ads_ranch_nlme_effects_pivot

业务友好的固定效应表：

| 字段 | 说明 |
|------|------|
| effect_type | 效应类型（品种/牧场） |
| dimension_value | 品种名/牧场名 |
| growth_parameter | 生长参数（log_A=成熟体重, log_B=生长速率, C=拐点日龄） |
| fixed_effect_estimate | 效应估计值（相对于基准的偏差） |
| adjusted_parameter | 调整后的实际参数值 |

**示例解读**：
```
effect_type=dimension_value=growth_parameter=fixed_effect_estimate=adjusted_parameter
品种        =西门塔尔公牛  =log_A          =0.28              =920kg
牧场        =源里牧场      =log_A          =0.07              =780kg
```

### ads_ranch_nlme_variance_analysis

方差分解结果：

| parameter_group | contribution_percentage | importance_level |
|----------------|------------------------|------------------|
| log_A (成熟体重) | 45.2% | 主导因素 |
| log_B (生长速率) | 32.1% | 重要因素 |
| C (拐点日龄) | 22.7% | 重要因素 |

### ads_ranch_nlme_ranch_efficiency

牧场效率排名：

| ranch_name | efficiency_grade | gap_to_benchmark_kg | total_improvement_potential_kg |
|-----------|------------------|--------------------|-------------------------------|
| 源里牧场 | 优秀 | 0 | 0 |
| 八里罕牧场 | 需改进 | -85 | 127,500 |

**解读**：八里罕牧场如果达到标杆水平，1000头牛可多产出127,500kg

## 注意事项

1. **运行时间**：PyMC MCMC采样需要10-30分钟，取决于数据量
2. **内存需求**：建议至少16GB内存
3. **模型收敛**：如果PyMC不收敛，会自动回退到简化两阶段法
4. **样本要求**：品种≥30头牛，牧场≥20头牛，单头牛≥3次观测
