# 资金域模型变更日志

## 2025-04-22

### 新增模型

- **dws_fund_customer_loan_state_df**：客户贷款当前状态表
  - 替代：dws_fund_customer_loan_balance_state_df
  - 改进：添加授信、交易、累计等完整指标

- **dws_fund_customer_loan_snap_df**：客户贷款历史快照表
  - 替代：dws_fund_customer_fund_snap_df
  - 改进：复用 state 逻辑，扩展历史时间范围

- **dws_fund_customer_loan_agg_df**：客户贷款汇总聚合表
  - 替代：dws_fund_customer_agg_df
  - 改进：从 snap + 交易事实聚合，职责更清晰

### 废弃模型

- ~~dws_fund_customer_loan_balance_state_df~~（2025-05-22 删除）
- ~~dws_fund_customer_fund_snap_df~~（2025-05-22 删除）
- ~~dws_fund_customer_agg_df~~（2025-05-22 删除）

### 架构改进

- **三层架构**：state（当前状态）→ snap（历史快照）→ agg（聚合汇总）
- **命名统一**：统一使用 customer_loan 主体
- **依赖优化**：层级依赖，减少重复计算
