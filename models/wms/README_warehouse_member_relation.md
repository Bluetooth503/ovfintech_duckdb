# 仓储主题域 - 仓库-货主-人员关联模型

## 模型概述

本模型用于管理仓库、仓库所有者、货主、人员四者之间的复杂关联关系，完全对齐生产环境的实际使用方式，解决仓库所有者、存货所有者、管理人员可能不是同一个实体的业务场景。

## 生产环境分析总结

### 生产环境的核心发现

1. **仓库表中的三层关系**：
   - `org_id`：仓库所有者（组织）
   - `manager_member_id`：**仓库管理员**（运营管理）
   - `contact_name/phone`：业务联系人

2. **货主表中的人员关系**：
   - `member_id`：货主ID（客户/组织）
   - `responsible_person`：**金信负责人**（业务经理）
   - `handl_org_name`：**落地机构**（业务分支机构）

3. **实际使用的核心表**：
   - `dws_warehouse_daily`：仓库-货主日汇总（粒度：dt + warehouse_id + member_id）
   - `ads_rpt_warehouse_member_1d_d`：仓库-会员报表
   - `dws_customer_scene`：客户场景汇总（包含负责人、落地机构）

## 模型列表

### 维度表（DIM层）

#### 1. dim_wms_warehouse.sql
- **描述**：仓库维度表，包含仓库基本信息、所有者信息、管理员信息、业务分类
- **粒度**：warehouse_id
- **核心字段**：
  - `warehouse_id` - 仓库ID
  - `warehouse_name` - 仓库名称
  - `warehouse_owner_id` - 仓库所有者ID
  - `warehouse_owner_name` - 仓库所有者名称
  - `owner_type` - 仓库所有者类型
  - `manager_member_id` - 仓库管理员ID
  - `manager_org_id` - 仓库管理员所属组织
  - `manager_type` - 管理员类型
  - `permission_level` - 管理权限
  - `supervise_type` - 监管类型
  - `ownership_type` - 所有权类型
  - `warehouse_business_type` - 业务分类
  - `contact_name` - 联系人姓名
  - `contact_phone` - 联系人电话

#### 2. dim_wms_member.sql
- **描述**：货主/会员维度表，统一组织和客户两种货主类型
- **粒度**：member_id
- **核心字段**：
  - `member_id` - 货主ID
  - `member_name` - 货主名称
  - `member_type` - 货主类型（组织/客户）
  - `company_type` - 企业类型
  - `industry_type` - 行业类型
  - `contact_name` - 联系人姓名
  - `contact_phone` - 联系人电话
  - `credit_level` - 信用等级

### 明细表（DWD层）

#### 3. dwd_wms_warehouse_member_rel_f_d.sql
- **描述**：仓库-货主关系事实表，记录实际业务关联
- **粒度**：warehouse_id + member_id + snap_date
- **核心字段**：
  - `snap_date` - 快照日期
  - `warehouse_id` - 仓库ID
  - `member_id` - 货主ID
  - `relation_type` - 关系类型（有货/无货/历史）
  - `relation_status` - 关系状态（活跃/锁定/历史）
  - `sku_cnt` - SKU数量
  - `total_charge_num` - 总件数
  - `total_weight_num` - 总重量
  - `total_goods_value` - 总货值
  - `goods_value_warehouse_rate` - 货主货值占仓库总货值比例
  - `goods_value_member_rate` - 该仓库货值占货主总货值比例

#### 4. dwd_wms_member_manager_rel_f_d.sql
- **描述**：货主-负责人关系表，记录货主与业务经理的关联关系
- **粒度**：member_id + 负责人
- **核心字段**：
  - `snap_date` - 快照日期
  - `member_id` - 货主ID
  - `member_name` - 货主名称
  - `manager_name` - 金信负责人
  - `branch_org` - 落地机构
  - `sub_branch_org` - 落地子机构
  - `business_category` - 业务分类
  - `business_sub_type` - 业务子类
  - `manager_type` - 管理员类型
  - `management_type` - 管理方式
  - `relation_status` - 关系状态

### 汇总表（DWS层）

#### 7. dws_wms_warehouse_member_agg_df.sql
- **描述**：仓库-货主汇总表，支持多维度分析（包含人员关系）
- **粒度**：warehouse_id + member_id + snap_date
- **核心字段**：
  - 包含所有维度和指标字段
  - **仓库管理员信息**：`warehouse_manager_id`, `warehouse_manager_name`, `warehouse_manager_phone`
  - **货主负责人信息**：`member_business_manager`, `member_branch_org`, `business_category`
  - `warehouse_member_cnt` - 仓库货主数量
  - `member_warehouse_cnt` - 货主仓库数量
  - `member_rank_in_warehouse` - 货主在仓库中的货值排名
  - `warehouse_rank_in_member` - 仓库在货主中的货值排名
  - `main_business_type` - 主营业务类型
  - `concentration_risk_level` - 集中度风险等级

## 数据血缘

```
ods_warehouse
    ↓
dim_wms_warehouse

ods_member_company
    ↓
    ├─→ dim_wms_member ←─┐
    ↓                   │
ods_member_member       │
    ↓                   │
dwd_wms_inventory_snap_df
    ↓
dwd_wms_warehouse_member_rel_f_d
    ↓
dws_wms_warehouse_member_agg_df

customer_tag + scene_cfg
    ↓
dwd_wms_member_manager_rel_f_d
    ↓
dws_wms_warehouse_member_agg_df
```

## 核心关联关系

### 1. 仓库与所有者的关系
- **关联键**：`warehouse.org_id`
- **关系类型**：1:1（一个仓库属于一个所有者）
- **来源**：dim_wms_warehouse.warehouse_owner_id

### 2. 仓库与管理员的关系
- **关联键**：`warehouse.manager_member_id`
- **关系类型**：1:1（一个仓库对应一个管理员）
- **来源**：dim_wms_warehouse.manager_member_id
- **用途**：仓库运营管理、日常沟通

### 3. 仓库与货主的关系
- **关联键**：`inventory.warehouse_id` 和 `inventory.customer_id`
- **关系类型**：N:M（一个仓库可以有多个货主，一个货主可以使用多个仓库）
- **来源**：dwd_wms_warehouse_member_rel_f_d

### 4. 货主与负责人的关系
- **关联键**：`customer_tag.member_id` 和 `customer_tag.responsible_person`
- **关系类型**：N:1（一个货主对应一个主要负责人）
- **来源**：dwd_wms_member_manager_rel_f_d
- **用途**：客户业务管理、业务分类、风控管理

### 5. 货主类型统一
- **规则**：当 `customer_id = 0` 时，货主是组织（org_id）；当 `customer_id != 0` 时，货主是客户（customer_id）
- **实现**：在dim_wms_member表中通过UNION ALL统一

## 使用场景

### 1. 按仓库分析（包含管理员信息）
```sql
-- 查询某仓库的所有货主、货值分布、管理员信息
SELECT
    warehouse_name,
    warehouse_owner_name,
    warehouse_manager_name AS manager,
    member_name,
    member_business_manager AS business_manager,
    member_branch_org,
    total_goods_value,
    goods_value_warehouse_rate
FROM dws_wms_warehouse_member_agg_df
WHERE snap_date = CURRENT_DATE
  AND warehouse_name = '某某仓库'
ORDER BY total_goods_value DESC
```

### 2. 按货主分析（包含负责人信息）
```sql
-- 查询某货主在哪些仓库有货、货值分布、负责人信息
SELECT
    member_name,
    member_business_manager AS responsible_person,
    member_branch_org,
    warehouse_name,
    warehouse_manager_name AS warehouse_manager,
    total_goods_value,
    goods_value_member_rate,
    member_rank_in_warehouse
FROM dws_wms_warehouse_member_agg_df
WHERE snap_date = CURRENT_DATE
  AND member_name = '某某公司'
ORDER BY total_goods_value DESC
```

### 3. 按业务经理分析
```sql
-- 查询某个业务经理负责的所有货主和仓库
SELECT
    member_business_manager AS manager_name,
    member_branch_org AS branch_org,
    COUNT(DISTINCT member_id) AS member_cnt,
    COUNT(DISTINCT warehouse_id) AS warehouse_cnt,
    SUM(total_goods_value) AS total_goods_value
FROM dws_wms_warehouse_member_agg_df
WHERE snap_date = CURRENT_DATE
  AND member_business_manager = '某某经理'
GROUP BY member_business_manager, member_branch_org
```

### 4. 按落地机构分析
```sql
-- 查询某个落地机构下的所有仓库和货主
SELECT
    member_branch_org,
    COUNT(DISTINCT warehouse_id) AS warehouse_cnt,
    COUNT(DISTINCT member_id) AS member_cnt,
    SUM(total_goods_value) AS total_goods_value,
    COUNT(CASE WHEN concentration_risk_level = '高风险' THEN 1 END) AS high_risk_cnt
FROM dws_wms_warehouse_member_agg_df
WHERE snap_date = CURRENT_DATE
  AND member_branch_org = '某某支行'
GROUP BY member_branch_org
```

### 5. 关系分析（四角关系）
```sql
-- 分析仓库所有者、仓库管理员、货主、货主负责人的四角关系
SELECT
    w.warehouse_name,
    w.warehouse_owner_name AS owner,
    w.contact_name AS warehouse_manager,
    r.member_name,
    mm.manager_name AS member_manager,
    r.total_goods_value,
    r.relation_status
FROM dim_wms_warehouse w
LEFT JOIN dwd_wms_warehouse_member_rel_f_d r ON w.warehouse_id = r.warehouse_id
    AND r.snap_date = CURRENT_DATE
LEFT JOIN dwd_wms_member_manager_rel_f_d mm ON r.member_id = mm.member_id
    AND mm.snap_date = CURRENT_DATE
WHERE w.is_deleted = '0' OR w.is_deleted = 'false'
ORDER BY r.total_goods_value DESC
```

### 6. 风控分析（集中度风险）
```sql
-- 识别货值集中度风险（结合业务分类和负责人）
SELECT
    warehouse_name,
    member_name,
    member_business_manager,
    member_branch_org,
    business_category,
    total_goods_value,
    goods_value_warehouse_rate,
    concentration_risk_level,
    CASE
        WHEN concentration_risk_level = '高风险' THEN '立即关注'
        WHEN concentration_risk_level = '中风险' THEN '定期检查'
        ELSE '正常监控'
    END AS risk_action
FROM dws_wms_warehouse_member_agg_df
WHERE snap_date = CURRENT_DATE
  AND concentration_risk_level IN ('高风险', '中风险')
ORDER BY goods_value_warehouse_rate DESC
```

## 设计原则

1. **完全对齐生产环境**：字段命名、数据来源、关联方式与生产环境保持一致
2. **维度与事实分离**：DIM表存储维度属性，DWD表存储关系事实
3. **粒度清晰**：每个模型都有明确的粒度定义
4. **人员关系完整**：包含仓库管理员、货主负责人、业务联系人等多层人员关系
5. **可追溯性**：通过snap_date支持历史追溯
6. **灵活扩展**：可以轻松添加新的关系类型和指标
7. **性能优化**：DWS层预计算聚合指标，提升查询性能

## 注意事项

1. **货主ID统一**：在DWD层通过`member_id`字段统一标识货主
2. **所有者与货主区分**：`owner_id`是仓库的所有者，`member_id`是存货的所有者
3. **管理员与负责人区分**：`warehouse_manager`是仓库管理员（运营），`member_business_manager`是货主负责人（业务）
4. **关系类型**：仓库-货主关系是动态的，基于实际库存情况生成
5. **更新策略**：DWD层支持增量更新，DWS层支持全量刷新
6. **数据质量**：需要定期检查关联完整性，确保没有孤儿记录
7. **人员信息时效性**：负责人和管理员信息可能变更，需要关注snap_date字段

## 更新日志

- 2026-04-23 v2.1: 仓库-所有者关系、仓库-管理员关系整合到 dim_wms_warehouse
- 2026-04-23 v2.0: 新增仓库-管理员关系、货主-负责人关系，完全对齐生产环境
- 2026-04-23 v1.0: 初始版本，创建仓库-货主关联模型
