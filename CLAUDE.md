# OVFinTech DuckDB 数仓项目规范

dbt + DuckDB，覆盖 ranch(牧场)、fund(资金)、customer(客户)、wms(仓储) 四大业务域。

## 模型命名

**格式：** `{layer}_{domain}_{subject}[_{process}]_{table_type}_{update_mode}.sql`

- `update_mode` 编码粒度+更新策略：首字母粒度（`d`=日/`w`=周/`m`=月）+ 尾字母策略（`i`=增量/`f`=全量）
- 无固定粒度的事件级表用 `_i`（省略粒度前缀）
- 快照表用 `_snap_{df|mf}`（显式标注粒度+全量）

### 命名后缀说明

| 层(layer) | 表类型(type) | 更新模式(update_mode) | 含义 | 示例 |
|-----------|-------------|---------------------|------|------|
| `dim` 维度层 | — | — | 全量/拉链，无后缀 | `dim_ranch_cattle.sql` |
| `dwd` 明细层 | `fact` 事实表 | `_i` 增量 | 事件驱动增量 | `dwd_ranch_cattle_sell_fact_i.sql` |
| `dws` 汇总层 | `agg` 聚合 | `_di` 日增量 | 按日期追加 | `dws_ranch_cattle_balance_agg_di.sql` |
| | | `_df` 日全量 | 按日期全量刷新 | `dws_ranch_cattle_return_agg_df.sql` |
| | | `_mi` 月增量 | 按月份追加 | `dws_ranch_cattle_growth_agg_mi.sql` |
| | | `_mf` 月全量 | 按月份全量刷新 | `dws_ranch_cattle_install_agg_mf.sql` |
| | | `_wi` 周增量 | 按周追加 | `dws_ranch_cattle_growth_agg_wi.sql` |
| | | `_i` 事件增量 | 无固定粒度的事件级 | `dws_ranch_cattle_adg_fcr_agg_i.sql` |
| | `snap` 快照 | `_snap_df` 日快照 | 日度全量快照 | `dws_ranch_cattle_snap_df.sql` |
| | | `_snap_mf` 月快照 | 月度全量快照 | `dws_ranch_cattle_inventory_snap_mf.sql` |
| `ads` 应用层 | `agg`/`dist` 聚合/分布 | `_di`/`_df`/`_mi`/`_mf`/`_wi` | 同DWS | `ads_rpt_cattle_weight_dist_wi.sql` |
| | `profile` 画像 | — | 全量快照 | `ads_ranch_cattle_asset_profile.sql` |
| | `hist` 历史 | — | 完整历史记录 | `ads_ranch_cattle_fatten_cycle_hist.sql` |
| | `dashboard` 看板 | `_mf` 等 | 同DWS后缀 | `ads_ranch_asset_dashboard_mf.sql` |
| | — | `_cum_d` 累计日 | 累计至当日 | `ads_ranch_cattle_asset_profile_cum_d.sql` |
| | — | `_cum_m` 累计月 | 累计至当月 | `ads_ranch_cattle_loan_cum_m.sql` |

**命名规则说明：**
- 更新模式：`_di`=日增量，`_df`=日全量，`_mi`=月增量，`_mf`=月全量，`_wi`=周增量，`_i`=事件级增量
- 粒度信息已编码在更新模式中，无需额外粒度后缀（不再使用 `_mi_m`、`_wi_w`）
- 特殊后缀：`_snap_df`=日快照，`_snap_mf`=月快照，`_profile`=画像，`_hist`=历史，`_cum_d`=累计日，`_cum_m`=累计月
- 子域前缀：`ads_ranch`（牧场应用）、`ads_rpt`（报表应用）、`ads_fund`（资金应用）等

**主体(subject):** cattle stall region recipe feed member market customer loan billing warehouse inventory inbound outbound asset rfm ai sku

**过程(process):** purchase sell return install onstall outstall weight price growth fatten balance adg

**命名示例：**
```
# 维度层
dim_ranch_cattle.sql                      dim_customer_member_ranch_rel.sql

# 明细层（DWD）
dwd_ranch_cattle_sell_fact_i.sql          dwd_fund_online_loan_fact_i.sql

# 汇总层（DWS）
dws_ranch_cattle_balance_agg_di.sql       # 日增量
dws_ranch_cattle_return_agg_df.sql        # 日全量
dws_ranch_cattle_growth_agg_mi.sql        # 月增量
dws_ranch_cattle_install_agg_mf.sql       # 月全量
dws_ranch_cattle_snap_df.sql              # 日快照
dws_ranch_cattle_inventory_snap_mf.sql    # 月快照
dws_ranch_cattle_adg_fcr_agg_i.sql        # 事件级
dws_ranch_cattle_price_snap_df.sql        # 最新价格快照

# 应用层（ADS）
ads_rpt_cattle_weight_dist_wi.sql         # 周增量分布
ads_ranch_cattle_asset_profile_cum_d.sql  # 累计日画像
ads_ranch_cattle_asset_profile.sql        # 全量画像
ads_ranch_asset_dashboard_mf.sql          # 月全量看板
ads_ranch_cattle_fatten_cycle_hist.sql    # 历史记录
```

**字段：** 主键 `{entity}_id` | 数量 `_cnt` | 金额 `_amt` | 比率 `_rate` | 均值 `_avg` | 布尔 `is_xxx` | 日期 `_date` | 时间戳 `_at` | 分区 `dt`(yyyy-mm-dd)

## 代码风格

- 每个模型文件必须以标准化注释头开头，格式如下：
  ```sql
  -- =============================================
  -- 模型名称：{与文件名一致，不含.sql}
  -- 模型描述：{一句话描述表的业务含义}
  -- Dbt更新方式：{增量（按日期）| 增量（按月）| 全量 | 增量（事件级）}
  -- 粒度：{表的粒度，如 牧场 + 栏舍 + 日期}
  -- 说明：
  --   - 数据源：{上游表及用途}
  --   - 增量策略：{具体增量逻辑}
  --   - 统计指标：{主要指标列表}
  --   - 聚合逻辑：{关键计算逻辑}
  -- =============================================
  ```
  DIM 层省略 `Dbt更新方式` 字段（默认全量）。字段按需增减，但 `模型名称`、`模型描述`、`粒度` 为必填。
- `LEFT JOIN ... ON ...` 写成一行
- `CASE WHEN ... THEN ... ELSE ... END` 写成一行，注释写在代码上方
- `LEAD(...)` / `SUM(...)` / `AVG(...)` / `OVER (... )` 等窗口函数写成一行，注释写在代码上方
- 最终 SELECT 的字段注释需对齐
- 字段命名必须参考 `glossary/` 术语库收录的标准命名
- `is_current` 等布尔字段统一使用字符串 `'0'`/`'1'`，不使用 BOOLEAN 类型

## 规则

- 全小写 + 下划线，同一含义统一词根不混用（映射统一 `rel`）
- 不冗余（`monthly` 与 `_m` 不同时出现，`daily` 与 `_d` 不同时出现）
- 数据流向：`ODS → DWD → DWS → ADS`，DIM 可被任意层引用，禁止反向依赖，ODS 只被 DWD 引用
- 增量模型需在最后保留注释形式的增量条件，方便离线调试：
  ```sql
  -- {% if is_incremental() %}
  -- AND stats_date > (SELECT COALESCE(MAX(stats_date), '1900-01-01'::DATE) FROM {{ this }})
  -- {% endif %}
  ```
- `_snap_df` 日度全量快照，`_snap_mf` 月度全量快照（含最新记录场景，如价格/称重当前值）
- `_hist` 后缀表示完整历史记录，不按时间截断
- `_cum_d` 累计至当日，`_cum_m` 累计至当月
