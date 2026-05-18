# IoT 业务主题域分析

> 基于数据库抽样数据的业务架构梳理
>
> 分析时间: 2026-04-27
>
> 数据源: `/orchid_iot`、`/orchid_iot_camera`、`/orchid_iot_weighbridge`
>
> 补充数据源: 海豚调度生产工作流（`wms_workflow`、`ranch_workflow`、`platform_workflow`）

---

## 🔗 IoT 设备与业务实体关系全景（核心发现）

> 以下关系链路从生产环境海豚调度工作流 SQL 中逆向提取，反映了 IoT 设备如何与客户、仓库、物品建立关联。

### 关系总览图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            IoT 设备关系全景                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  【仓储场景】orchid_iot / orchid_wms                                        │
│                                                                             │
│  客户(member_prd.dwd_mem_company_f_d)                                       │
│    │ org_id = mem_company_id                                                │
│    ▼                                                                        │
│  仓库(wms_prd.dwd_warehouse_f_d)  ←── org_id, warehouse_id, warehouse_name │
│    │ warehouse_id                                                           │
│    ├──► 摄像头(wms_prd.dwd_camera_f_d)    via warehouse_device.bridge       │
│    │         device_type = 1                                                │
│    ├──► 地磅(wms_prd.dwd_weightbridge)     via warehouse_device.bridge      │
│    │         device_type = ?                                                │
│    ├──► 电子锁(wms_prd.dwd_electronic_lock) via warehouse_device.bridge     │
│    │         device_type = ?                                                │
│    ├──► 道闸(wms_prd.dwd_road_gate)        via warehouse_device.bridge     │
│    └──► 库存(wms_prd.dwd_inventory_i_d)                                     │
│              member_id, warehouse_id, goods_id, charge_num                  │
│                                                                             │
│  关键桥接表: orchid_wms.warehouse_device                                     │
│    (warehouse_id, device_id, device_type, device_usage)                     │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  【牧场场景】orchid_iot_camera / jeecg-boot                                  │
│                                                                             │
│  客户(customer表)                                                           │
│    │ customer_id                                                            │
│    ▼                                                                        │
│  猪场(piggery表) ←── customer_id, piggery_id, loan_amount                  │
│    │ piggery_id                                                             │
│    ├──► 摄像头(piggery_device, type=0)                                      │
│    │         device_id → capture_camera → AI 车牌识别                       │
│    └──► 地磅(piggery_device, type=1)                                        │
│                                                                             │
│  牧场(jeecg-boot.psi_monitor_device)                                        │
│    │ tenant_id, stall_id, region_id                                         │
│    ├──► 摄像头(monitor_device)                                              │
│    │         device_serial_no, stall_id, region_id                          │
│    └──► 关联: tenant → member_prd.dws_warehouse_scene (warehouse_type=2)   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 一、仓储场景：设备 ↔ 仓库 ↔ 客户 ↔ 物品

#### 1.1 核心桥接表：`orchid_wms.warehouse_device`

这是 IoT 设备与仓库建立关联的**核心枢纽表**，存在于 `orchid_wms` 数据库（非 IoT 库），在海豚调度 `wms_workflow` 中被同步到 `wms_prd.ods_warehouse_device_f_d` → `wms_prd.dwd_warehouse_device_f_d`。

```sql
-- 来源: orchid_wms.warehouse_device
-- 同步: ods_dwd_warehouse_device_f_d 工作流
select warehouse_id, device_id, device_type, device_usage
from warehouse_device where is_deleted = 0
```

| 字段 | 说明 |
|------|------|
| `warehouse_id` | 仓库ID，关联 `dwd_warehouse_f_d` |
| `device_id` | 设备ID，关联 `dwd_camera_f_d.camera_id` 等 |
| `device_type` | 设备类型（1=摄像头） |
| `device_usage` | 设备用途 |

#### 1.2 设备 → 仓库：完整关联链路

```
orchid_iot.camera (id, org_id)
    ↓ DataX同步 (orchid_iot → wms_prd.ods_camera_f_d)
wms_prd.ods_camera_f_d (camera_id, org_id, ...)
    ↓ DWD清洗 (过滤 is_blocked=0, is_deleted=0, org_id∈会员企业)
wms_prd.dwd_camera_f_d (camera_id, org_id, ...)
    ↓ 通过桥接表关联
wms_prd.dwd_warehouse_device_f_d (warehouse_id, device_id=camera_id, device_type=1)
    ↓ JOIN
wms_prd.dwd_warehouse_f_d (warehouse_id, warehouse_name, org_id)
```

**关键 SQL（从 wms_workflow 生产任务提取）：**

```sql
-- 摄像头在线/离线统计（按仓库维度）
SELECT d.warehouse_id,
    SUM(CASE WHEN c.is_online = 1 THEN 1 ELSE 0 END) AS camera_online_qty,
    SUM(CASE WHEN c.is_online <> 1 THEN 1 ELSE 0 END) AS camera_offline_qty
FROM wms_prd.dwd_warehouse_device_f_d d
LEFT JOIN wms_prd.dwd_camera_f_d c ON d.device_id = c.camera_id
WHERE d.device_type = 1
GROUP BY d.warehouse_id
```

#### 1.3 仓库 → 客户：归属关系

```
wms_prd.dwd_warehouse_f_d
    ├── org_id → member_prd.dws_customer_scene.member_id  (客户名称)
    └── org_id → member_prd.dwd_mem_company_f_d.mem_company_id  (企业会员)
```

**摄像头 DWD 层过滤条件：**
```sql
-- 仅保留有效企业的摄像头
WHERE is_blocked = 0 AND is_deleted = 0
  AND org_id IN (SELECT mem_company_id FROM member_prd.dwd_mem_company_f_d)
```

**仓库日统计中关联客户：**
```sql
-- 仓库日报关联客户名称
LEFT JOIN member_prd.dws_customer_scene cus ON cus.member_id = result_r.org_id
```

#### 1.4 仓库 → 物品（库存）

```
wms_prd.dwd_inventory_i_d
    ├── warehouse_id → 仓库
    ├── member_id → 货主客户
    ├── goods_id → 物品
    ├── remain_charge_num → 剩余数量
    └── latest_price → 最新单价
```

#### 1.5 仓储场景设备关系汇总

| 关系 | 关联键 | 来源表 | 说明 |
|------|--------|--------|------|
| 摄像头 → 仓库 | `warehouse_device.warehouse_id` + `device_id=camera_id` + `device_type=1` | orchid_wms.warehouse_device | 摄像头挂载到仓库 |
| 摄像头 → 客户 | `camera.org_id` = `mem_company_id` | orchid_iot.camera | 摄像头所属机构 |
| 仓库 → 客户 | `warehouse.org_id` = `customer.member_id` | orchid_wms.warehouse | 仓库归属客户 |
| 仓库 → 物品 | `inventory.warehouse_id` + `goods_id` | orchid_wms.inventory | 仓库存放物品 |
| 地磅 → 仓库 | `weightbridge.org_id` → `warehouse` | orchid_iot.weightbridge | 地磅所属机构 |
| 称重 → 物品 | `weight_record.product_name` + `bridge_id` | orchid_iot.weight_record | 称重关联物品 |
| 电子锁 → 客户 | `electronic_lock.org_id` | orchid_iot.electronic_lock | 电子锁所属机构 |

### 二、牧场场景：设备 → 猪场/租户 → 客户

#### 2.1 猪场摄像头场景（orchid_iot_camera）

```
customer (customer_id, customer_name, member_ids)
    │ customer_id
    ▼
piggery (piggery_id, piggery_name, piggery_code, loan_amount)
    │ piggery_id
    ├──► piggery_device (type=0, no=设备序列号)  → 摄像头
    │        └──► capture_camera → cap_strategy(JSON抓拍策略)
    │              └──► device_event (car_no, type=0入栏/1出栏)
    └──► piggery_device (type=1)  → 地磅
```

**关系链路：**
- **customer → piggery**: `piggery.customer_id = customer.id`
- **piggery → device**: `piggery_device.piggery_id = piggery.id`, `type` 区分摄像头(0)/地磅(1)
- **device → event**: `device_event.device_id = piggery_device.id`, 车辆进出栏事件
- **piggery → loan**: `piggery.loan_amount` 直接记录关联贷款金额

#### 2.2 牧场监控设备场景（jeecg-boot.psi_monitor_device）

这是牧场系统中独立的监控设备管理，数据从 `jeecg-boot.psi_monitor_device` 同步到 `ranch_prd.dwd_monitor_device_f_d`。

```
牧场租户(jeecg-boot)
    │ tenant_id
    ▼
psi_monitor_device
    ├── monitor_device_id: 设备ID
    ├── tenant_id: 租户ID → dwd_ranch_tenant_f_d (tenant_name)
    ├── stall_id: 栏舍ID → dwd_ranch_stall_f_d (stall_name)
    ├── region_id: 区域ID
    ├── device_serial_no: 设备序列号
    ├── device_type / device_type_name: 设备类型
    ├── device_status: 设备状态 (1在线/-1离线)
    └── latest_ping_time: 最近心跳时间
```

**关键 SQL（从 ranch_workflow 生产任务提取）：**

```sql
-- 牧场监控设备同步
SELECT tenant_id, id monitor_device_id, device_name, device_serial_no,
       stall_id, device_type_name, device_type, device_id, region_id,
       latest_ping_time, status device_status
FROM psi_monitor_device
```

**租户与仓库场景的映射（从 platform_workflow 摄像头掉线任务提取）：**

```sql
-- 牧场离线设备 → 仓库场景标签
SELECT mon.tenant_id, COUNT(monitor_device_id) camera_offline_qty
FROM ranch_prd.dwd_monitor_device_f_d WHERE device_status = -1
GROUP BY tenant_id
) mon
LEFT JOIN ranch_prd.dwd_ranch_tenant_f_d tent ON mon.tenant_id = tent.tenant_id
LEFT JOIN member_prd.dws_warehouse_scene tag ON tag.warehouse_name = tent.tenant_name
WHERE tag.warehouse_type = 2   -- warehouse_type=2 表示牧场
```

#### 2.3 牧场场景设备关系汇总

| 关系 | 关联键 | 来源表 | 说明 |
|------|--------|--------|------|
| 客户 → 猪场 | `piggery.customer_id = customer.id` | orchid_iot_camera | 客户拥有猪场 |
| 猪场 → 摄像头 | `piggery_device.piggery_id`, `type=0` | orchid_iot_camera | 猪场安装摄像头 |
| 猪场 → 地磅 | `piggery_device.piggery_id`, `type=1` | orchid_iot_camera | 猪场安装地磅 |
| 摄像头 → 事件 | `device_event.device_id` | orchid_iot_camera | AI 车辆识别事件 |
| 租户 → 监控设备 | `monitor_device.tenant_id` | jeecg-boot.psi_monitor_device | 租户安装摄像头 |
| 栏舍 → 监控设备 | `monitor_device.stall_id` | jeecg-boot.psi_monitor_device | 栏舍安装摄像头 |
| 租户 → 仓库场景 | `tenant_name = warehouse_name`, `warehouse_type=2` | member_prd.dws_warehouse_scene | 牧场映射为仓库场景 |
| 猪场 → 贷款 | `piggery.loan_amount` | orchid_iot_camera | 猪场关联贷款金额 |

### 三、产融风控场景：设备监控 → 风控预警

生产环境海豚调度在 `platform_workflow` 中有一个 **「预警日报」** 工作流（id=2158），整合了 IoT 设备数据进行风控预警：

#### 3.1 摄像头掉线预警（仓储+牧场双通道）

```sql
-- 通道1: 仓储摄像头掉线
SELECT dt, '摄像头掉线' early_warn, wparw.warehouse_name, wparw.camera_offline_qty
FROM wms_prd.ads_rpt_warehouse_1d_d     -- 仓库日报（含摄像头在线数）
LEFT JOIN member_prd.dws_warehouse_scene ON warehouse_id
WHERE camera_offline_qty > 0 AND goods_value > 0   -- 有库存且摄像头掉线

UNION ALL

-- 通道2: 牧场摄像头掉线
SELECT '$[yyyy-MM-dd]' dt, '摄像头掉线' early_warn, tent.tenant_name, mon.camera_offline_qty
FROM ranch_prd.dwd_monitor_device_f_d WHERE device_status = -1  -- 牧场离线设备
LEFT JOIN ranch_prd.dwd_ranch_tenant_f_d tent
LEFT JOIN member_prd.dws_warehouse_scene tag WHERE tag.warehouse_type = 2
```

#### 3.2 AI 告警预警（牛只盘点 + 安防监控）

```sql
-- 牛只盘点预警（type=1）+ 安防监控预警（type=2）
FROM ranch_prd.dwd_ai_alert_record   -- AI 告警记录
JOIN ranch_prd.dwd_work_order        -- 工单
WHERE type IN (1, 2)                  -- 1=牛只盘点预警, 2=安防监控预警
```

### 四、生产环境 Doris 数仓已有 IoT 相关表

从海豚调度工作流中逆向提取的已建 Doris 表：

| Doris 表名 | 来源数据库 | 来源表 | 同步方式 | 说明 |
|------------|-----------|--------|----------|------|
| `wms_prd.ods_camera_f_d` | orchid_iot | camera | DataX 全量 | 摄像头 ODS |
| `wms_prd.dwd_camera_f_d` | ods_camera_f_d | — | SQL 清洗 | 摄像头 DWD（过滤有效企业） |
| `wms_prd.ods_warehouse_device_f_d` | orchid_wms | warehouse_device | DataX 全量 | 仓库设备桥接 ODS |
| `wms_prd.dwd_warehouse_device_f_d` | ods_warehouse_device_f_d | — | SQL 清洗 | 仓库设备桥接 DWD |
| `wms_prd.dws_warehouse_daily` | 多表聚合 | — | SQL 聚合 | 仓库日报（含摄像头在线数） |
| `wms_prd.ads_rpt_warehouse_1d_d` | dws_warehouse_daily | — | SQL 聚合 | 仓库报表（含摄像头在线/离线数） |
| `ranch_prd.ods_monitor_device_i_d` | jeecg-boot | psi_monitor_device | DataX 增量 | 牧场监控设备 ODS |
| `ranch_prd.dwd_monitor_device_f_d` | ods_monitor_device_i_d | — | SQL 清洗 | 牧场监控设备 DWD |
| `ranch_prd.dwd_ai_alert_record` | — | — | — | AI 告警记录 |
| `ranch_prd.dwd_work_order` | — | — | — | 工单表 |
| `platform_prd.ads_rpt_early_warn_1d_d` | 多表聚合 | — | SQL 聚合 | 预警日报（含摄像头掉线） |

### 五、关系链路速查表

| 我想知道... | 关联路径 |
|------------|---------|
| 某仓库有哪些摄像头？ | `dwd_warehouse_device_f_d` (device_type=1) → `dwd_camera_f_d` (device_id=camera_id) |
| 某仓库的摄像头在线率？ | `dws_warehouse_daily.camera_online_qty / (camera_online_qty + camera_offline_qty)` |
| 某客户的仓库摄像头状态？ | `dwd_warehouse_f_d.org_id` → `member_prd.dws_customer_scene.member_id` → 仓库 → 摄像头 |
| 某猪场有多少摄像头？ | `piggery_device` (piggery_id, type=0) |
| 牧场租户的设备离线情况？ | `dwd_monitor_device_f_d` (tenant_id, device_status) → `dwd_ranch_tenant_f_d` |
| 称重数据关联哪个仓库？ | `weight_record.bridge_id` → `weightbridge.id` → `weightbridge.org_id` → 仓库 |
| AI 盘点关联哪个仓库？ | `camera_make_inventory.business_id` → `camera_make_inventory_info.warehouse_id` |
| 电子锁归属哪个客户？ | `electronic_lock.org_id` → 客户 |
| 预警日报中摄像头掉线？ | `ads_rpt_early_warn_1d_d` (early_warn='摄像头掉线') |

## 📊 IoT 主题域全景概览

IoT 平台围绕**仓储物流场景**，通过摄像头、地磅、电子锁、道闸、读卡器、自助机、盘料仪等物联设备，实现远程监控、车辆通行管控、称重计量、AI 盘点、电子锁施封/解封等业务闭环。

| 数据库 | 表数量 | 核心业务 |
|--------|--------|----------|
| `orchid_iot` | 23 | 设备管理、视频监控、AI 盘点、称重过磅、电子锁、道闸通行、预警告警 |
| `orchid_iot_camera` | 5 | 牧场（猪场）摄像头监控、车辆识别事件 |
| `orchid_iot_weighbridge` | 2 | 地磅设备在线监控、应用密钥管理 |

---

## 📊 IoT 业务主题域划分

### 一、设备管理域

IoT 平台的基础能力层，管理所有物联设备的主数据，是所有业务域的共享维度。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `camera` | 摄像头设备表 | no(序列号), brand, model, type, is_online, is_blocked, org_id, edge_device_id |
| `weightbridge` | 地磅设备表 | name, no(磅号), serial_no, type(0无人值守/1简易), enabled, org_id |
| `electronic_lock` | 电子锁设备表 | no(序列号), type(1九通/2途泰), is_online, is_locked, status, electricity, lock_guid |
| `card_reader` | 读卡器设备表 | no(序列号), brand, model, is_online, is_blocked, org_id |
| `auto_machine` | 自助终端表 | code(业务编号), serial_no, status |
| `road_gate` | 道闸设备表 | gate_code, gate_type(1进/2出/3同进同出), enable_open, enable_warning |
| `device_info` | 盘料仪设备表 | device_type(1固定式/2手持式), device_code, ip_address, net_status, heartbeat_time |
| `camera_edge_device` | 边缘计算设备表 | edge_device_url, name |

#### 设备类型矩阵

| 设备 | 通信方式 | 核心状态 | 业务场景 |
|------|----------|----------|----------|
| 摄像头 | 萤石云/本地 | 在线/离线、加密、录像、移动侦测 | 视频监控、AI 盘点、OCR 识别 |
| 地磅 | 串口/网络 | 启用/禁用、无人值守/简易 | 称重计量、出入库 |
| 电子锁 | 蜂窝网络 | 上锁/开锁、电量、GPS | 货物施封、仓库安全 |
| 道闸 | 网络 | 允许开启/关闭 | 车辆进出管控 |
| 读卡器 | 网络 | 在线/离线 | 身份识别 |
| 自助终端 | 网络 | 启用/停用 | 自助业务办理 |
| 盘料仪 | 网络/IP | 网络/心跳 | 堆状物库存盘点 |
| 边缘设备 | 网络 | — | 本地 AI 计算 |

#### 设备维度属性

- **通用属性**: 设备编号(序列号)、品牌、型号、机构归属、创建人
- **状态属性**: 在线/离线、启用/停用、删除标记
- **流量属性**: 流量到期日(expiring_date)、剩余天数(residue_day)
- **摄像头特有**: 监控方式(monitor_source: 1萤石云/2本地)、通道号、所属权(camera_owner_ship: 1金信自有/2第三方托管)
- **电子锁特有**: 锁类型(1九通/2途泰)、远程密码、本地密码、GPS 经纬度、电量

---

### 二、视频监控与图像采集域

摄像头抓拍图片的采集、存储与调度管理，是 AI 盘点和视频监控的基础数据源。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `camera_pic` | 摄像头抓拍记录表 | camera_id, path, path2, warehouse_id, device_no, channel_no, create_time |
| `camera_pic20251208` | 抓拍记录归档表 | camera_id, path, path2, create_time |
| `camera_pic_capture_record` | 抓拍异常记录表 | camera_id, error_msg, create_time |
| `camera_snapshot_record` | 抓拍调度记录表 | current_snapshot_num, need_exce_analysis_num |
| `capture_camera` | 抓拍摄像头配置表 | device_id, channel, cap_strategy(JSON), is_enabled |

#### 业务流程

```
摄像头定时抓拍 → 图片存储(OSS) → 调度分析(异常检测) → AI 盘点/预警
```

#### 数据特点

- **camera_pic**: 核心流水表，数据量极大（AUTO_INCREMENT=2420972），按仓库+设备+通道号索引
- **camera_pic20251208**: 历史归档表（AUTO_INCREMENT=17459549），用于历史数据迁移
- **cap_strategy**: JSON 格式的抓拍策略配置（频率、时段等）
- **异常类型**: "子账户或萤石用户没有权限"、"设备不在线"等

#### 关键指标

- **抓拍量**: 按摄像头/仓库/时段的抓拍次数
- **抓拍异常率**: 异常记录占比
- **在线抓拍率**: 在线时段内实际抓拍比例

---

### 三、AI 盘点域

基于摄像头图片的 AI 视觉盘点，用于仓储和牧场场景的库存自动盘点。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `camera_make_inventory` | 摄像头盘点明细表 | business_id, business_type, camera_id, device_no, take_stock_number, take_stock_status, compare_picture_url |
| `camera_make_inventory_info` | AI 盘点任务表 | take_stock_id, business_type, warehouse_id, take_stock_total_number, camera_total_number, take_stock_status |
| `device_config` | 设备配置表 | warehouse_id, sys_code, sys_value |
| `device_info` | 盘料仪设备表 | device_type(1固定式/2手持式), device_code, heartbeat_time |

#### 业务流程

```
创建盘点任务 → 分配摄像头 → 定时抓拍 → AI 识别计数 → 结果比对 → 异常标记
```

#### 盘点业务模型

```
camera_make_inventory_info (盘点任务/汇总)
    ├── take_stock_id: 盘点单号
    ├── business_type: 1.仓储 2.牧场
    ├── take_stock_total_number: 盘点总件数
    ├── camera_total_number: 摄像头总数
    └── take_stock_status: 1进行中/2正常/3异常
        │
        └── camera_make_inventory (盘点明细, 按摄像头)
             ├── camera_id: 摄像头
             ├── take_stock_number: 该摄像头盘点数量
             ├── picture_url: 盘点图片
             └── compare_picture_url: 对比图片
```

#### 盘点设备

- **固定式盘料仪** (device_type=1): 固定安装在仓库内，自动定时盘点
- **手持盘料仪** (device_type=2): 手持移动盘点设备
- **AI 差异阈值**: `AI_MAKE_INVENTORY_DIFF_RATE = 3`（差异率超过 3% 触发异常）

#### 关键指标

- **盘点数量**: take_stock_number / take_stock_total_number
- **盘点状态**: 进行中/正常/异常
- **摄像头覆盖率**: 参与盘点的摄像头数 / 总摄像头数
- **盘点差异率**: AI 盘点数与系统记录的差异百分比

---

### 四、称重/过磅域

地磅称重的完整业务流程，覆盖车辆出入库的重量计量。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `weightbridge` | 地磅设备表 | name, no, serial_no, type(0无人值守/1简易), enabled |
| `weight_record` | 称重记录表 | weight_record_no, car_no, type(0入库/1出库), bridge_id, gross_weight, tare_weight, net_weight, product_name, amount |
| `weight_record_log` | 称重日志表 | weight_record_no, car_no, type, receiver, sender, weight_type, processed |
| `app_key` | 地磅应用密钥表 | app_key, access_key, warehouse_ids |
| `device_on_line` | 设备在线状态表 | sn, state(0离线/1在线), device_type(1道闸/2地磅) |

#### 业务流程

```
车辆入厂 → 毛重称重(满载) → 卸货/装货 → 皮重称重(空载) → 计算净重 → 打磅单 → 出厂
```

#### 称重模式

| 称重方式 | weight_type | 说明 |
|----------|-------------|------|
| 手动称重 | 0 | 人工操作 |
| 一次称重 | 1 | 仅称一次，皮重手动输入 |
| 二次称重 | 2 | 毛重+皮重各称一次 |

#### 重量计算

```
净重 = 毛重(gross_weight) - 皮重(tare_weight) - 扣重(buckle_weight)
总价 = 净重 × 单价(price)
盈亏 = 实际净重 - 预期净重
```

#### 关键指标

- **净重**: net_weight — 实际货物重量
- **方数**: squares — 体积计量
- **扣重**: buckle_weight — 水分/杂质扣减
- **盈亏**: profit_loss — 实际与预期差异
- **过磅次数**: 按地磅/车辆/日期统计

---

### 五、电子锁/安全管控域

电子锁的施封解封管理，用于仓库货物安全监控。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `electronic_lock` | 电子锁设备表 | no, type(1九通/2途泰), is_locked, status, electricity, longitude, latitude, remote_password, local_password |
| `lock_password` | 电子锁密码表 | lock_id, password, short_password |
| `lock_state` | 电子锁实时状态表 | code, online, gpstime, lat, lng, posinfo, electricity, state, states |

#### 业务流程

```
施封(远程/本地) → 上锁确认 → GPS定位记录 → 在线状态监控 → 异常告警 → 解封
```

#### 电子锁类型

| 类型 | type | 通信方式 | 特点 |
|------|------|----------|------|
| 九通锁 | 1 | — | — |
| 途泰锁 | 2 | 蜂窝网络 | 支持远程施封、GPS定位、电量监控 |

#### 锁状态

- **设备状态**: 0正常、1低电量异常、2绳索异常、3异常开锁
- **锁定状态**: 0开锁、1上锁
- **在线状态**: 在线/离线

#### 关键指标

- **在线率**: 在线锁数 / 总锁数
- **异常率**: 异常锁数 / 总锁数（低电量、绳索异常、异常开锁）
- **电量水平**: 锁的电池电量监控
- **定位准确率**: GPS 定位可用率

---

### 六、道闸/车辆通行域

仓库出入口的车辆通行管控。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `road_gate` | 道闸设备表 | gate_code, gate_type(1进/2出/3同进同出), enable_open, enable_warning |
| `road_gate_record` | 道闸通行记录表 | road_gate_id, car_number, business_type(1入库/2出库), record_time |

#### 业务流程

```
车辆到达 → 车牌识别 → 道闸判断(是否允许通行) → 闸机开启 → 通行记录 → 闸机关闭
```

#### 道闸类型

| 类型 | gate_type | 说明 |
|------|-----------|------|
| 进闸 | 1 | 仅进库方向 |
| 出闸 | 2 | 仅出库方向 |
| 同进同出 | 3 | 双向通行 |

#### 控制策略

- **enable_open**: 是否允许道闸开启（远程控制开关）
- **enable_warning**: 是否开启道闸预警（异常通行告警）

#### 关键指标

- **通行次数**: 按道闸/车辆/日期的通行记录数
- **进出比**: 入库次数 vs 出库次数
- **高峰时段**: 通行频率分析

---

### 七、预警/告警域

所有 IoT 设备的异常预警管理。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `warn_detail` | 预警明细表 | device_id, device_type(1摄像头/2电子锁), device_no, warn_msg, warn_time, alarm_pic_url, is_readed |

#### 预警类型

| 设备类型 | device_type | 预警场景 |
|----------|-------------|----------|
| 摄像头 | 1 | 移动侦测预警、监控下线预警、设备离线 |
| 电子锁 | 2 | 电子锁离线报警、异常开锁、低电量 |

#### 预警状态

- **is_readed**: 0未读、1已读
- **is_deleted**: 0有效、1已删除

#### 预警机制

- 摄像头离线预警: warn_count 累计预警次数（3次为止）
- 移动侦测预警: 可配置侦测时段(sense_start_time ~ sense_end_time)和周期(period)
- 电子锁预警: 异常开锁、低电量、绳索异常

#### 关键指标

- **预警次数**: 按设备/类型/日期统计
- **已读率**: 已读预警 / 总预警
- **设备离线率**: 离线设备数 / 总设备数
- **平均响应时间**: 预警产生到已读的时间

---

### 八、牧场监控域（摄像头 AI 识别）

基于摄像头 AI 的牧场（猪场）监控业务，主要用于贷款风控场景下的活体资产监控。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `customer` | 客户信息表 | customer_name, customer_code, member_ids |
| `piggery` | 猪场信息表 | customer_id, piggery_name, piggery_code, loan_amount |
| `piggery_device` | 猪场设备关联表 | piggery_id, type(0摄像头/1地磅), name, no |
| `capture_camera` | 抓拍摄像头配置表 | device_id, channel, cap_strategy(JSON) |
| `device_event` | 设备事件表 | serial_no, content, device_id, car_no, type(0入栏/1出栏), status(0未发布/1已发布/2取消) |

#### 业务流程

```
客户注册 → 绑定猪场 → 安装监控设备 → AI 抓拍识别 → 车辆进出事件 → 出栏/入栏统计 → 贷后风控
```

#### 业务架构

```
customer (客户/养殖企业)
    └── piggery (猪场)
         ├── piggery_device (关联设备: 摄像头/地磅)
         │    ├── capture_camera → 抓拍配置
         │    └── device_event → 车辆识别事件
         └── loan_amount: 关联贷款金额 (风控监控)
```

#### 事件类型

| 事件 | type | 说明 |
|------|------|------|
| 入栏 | 0 | 车辆运入牲畜 |
| 出栏 | 1 | 车辆运出牲畜 |

#### 事件状态

| 状态 | status | 说明 |
|------|--------|------|
| 未发布 | 0 | 事件产生但未推送 |
| 已发布 | 1 | 事件已推送到业务系统 |
| 取消 | 2 | 事件已取消 |

#### 关键指标

- **入栏/出栏次数**: 按猪场/日期统计
- **存栏变化**: 入栏 - 出栏 = 当前存栏
- **贷款覆盖率**: 有监控设备的猪场贷款额 / 总贷款额
- **设备在线率**: 在线监控设备 / 总设备

---

### 九、系统配置/操作审计域

系统级配置管理与用户操作日志。

#### 核心实体

| 表名 | 说明 | 关键字段 |
|------|------|----------|
| `base_properties` | 系统基础配置表 | prop_name, prop_value, modifiable, name, value_type |
| `device_config` | 设备配置表 | warehouse_id, sys_code, sys_value |
| `op_log` | 操作日志表 | device_id, device_type, operator_id, operator, operator_org_id, content, source |
| `app_key` | 地磅应用密钥表 | app_key, access_key, warehouse_ids |
| `device_on_line` | 设备在线状态表 | sn, state, device_type |

#### 配置项示例

| 配置项 | 说明 |
|--------|------|
| 仓库监控密钥 | 萤石云 API 密钥配置 |
| 短信发送间隔 | 预警短信发送频率控制 |
| 电子锁 API 配置 | 九通/途泰电子锁接口配置 |
| AI 盘点差异率 | AI_MAKE_INVENTORY_DIFF_RATE = 3 |

#### 操作日志类型

- 监控设备新增/更新/删除
- 门锁设备操作（施封/解封）
- 读卡器设备操作
- 监控设备配置变更

---

## 🎯 核心业务闭环

### 仓储出入库闭环

```
车辆到达 → 道闸识别放行 → 入库称重(毛重) → 卸货 → 电子锁施封 → AI 盘点确认 → 电子锁解封 → 装货 → 出库称重(净重) → 道闸放行出厂
```

### AI 盘点闭环

```
创建盘点任务 → 摄像头定时抓拍 → 边缘计算/AI 识别 → 结果汇总 → 差异分析 → 异常标记 → 人工复核
```

### 电子锁管控闭环

```
仓库装货完毕 → 远程施封 → GPS 定位记录 → 运输途中监控(在线状态/电量) → 到达目的地 → 远程解封/本地密码解封
```

### 牧场贷后监控闭环

```
客户授信 → 绑定猪场 → 安装监控设备 → AI 车辆识别 → 入栏/出栏统计 → 存栏量监控 → 贷后风控评估
```

---

## 📈 关键业务指标

| 类别 | 指标 | 说明 |
|------|------|------|
| **设备运营** | 设备在线率、离线预警数、设备故障率 | 设备健康度监控 |
| **称重计量** | 过磅次数、净重总量、盈亏量、扣重率 | 出入库计量 |
| **AI 盘点** | 盘点任务数、盘点准确率、差异率、异常率 | 库存管理 |
| **电子锁** | 在线率、异常开锁次数、低电量预警数 | 安全管控 |
| **道闸通行** | 通行次数、进出比、高峰时段 | 车辆管控 |
| **预警告警** | 预警总量、已读率、平均响应时间 | 运维效率 |
| **牧场监控** | 入栏/出栏数、存栏变化、设备覆盖率 | 贷后风控 |

---

## 🔍 业务架构特点

### 1. 仓储物流为核心场景

IoT 平台以**仓储物流**为核心场景，覆盖从车辆入厂到出厂的全流程：
- 道闸管控车辆进出
- 地磅计量货物重量
- 摄像头监控仓库安全
- 电子锁保证货物安全

### 2. AI 视觉赋能

- **AI 盘点**: 基于摄像头图片的自动库存盘点，减少人工盘点成本
- **边缘计算**: 边缘设备支持本地 AI 计算，降低云端依赖
- **OCR 识别**: 监管牌 OCR 识别坐标(license_ocr_area)

### 3. 多品牌设备适配

- **摄像头**: 海康威视，支持萤石云和本地两种监控方式
- **电子锁**: 九通、途泰两种品牌，适配不同通信协议
- **盘料仪**: 固定式、手持式两种形态

### 4. 产融结合风控

- **牧场监控**: 通过摄像头 AI 识别猪场车辆进出，监控活体资产
- **贷款关联**: 猪场绑定贷款金额(loan_amount)，实现贷后风控
- **数据闭环**: 设备事件 → 业务状态 → 风控评估

### 5. 设备全生命周期管理

- **注册**: 设备录入系统
- **监控**: 在线状态、电量、流量到期日
- **预警**: 离线、异常、低电量等告警
- **维护**: 启用/停用、删除

---

## 📋 与 dbt 项目映射建议

### 目录结构

```
models/
├── iot/              # IoT 业务域（待创建）
│   ├── dim/          # 维度表
│   ├── dwd/          # 明细层
│   ├── dws/          # 汇总层
│   └── ads/          # 应用层
```

### 业务主题域映射

| 业务主题域 | dbt 模型前缀 | 建议目录 | 状态 |
|------------|-------------|----------|------|
| 设备维度 | `dim_iot_device_*` | `models/iot/dim/` | 待创建 |
| 视频监控 | `dwd_iot_camera_*` | `models/iot/dwd/` | 待创建 |
| AI 盘点 | `dwd_iot_inventory_*` | `models/iot/dwd/` | 待创建 |
| 称重过磅 | `dwd_iot_weight_*` | `models/iot/dwd/` | 待创建 |
| 电子锁 | `dwd_iot_lock_*` | `models/iot/dwd/` | 待创建 |
| 道闸通行 | `dwd_iot_gate_*` | `models/iot/dwd/` | 待创建 |
| 预警告警 | `dwd_iot_warn_*` | `models/iot/dwd/` | 待创建 |
| 牧场监控 | `dwd_iot_ranch_*` | `models/iot/dwd/` | 待创建 |

### IoT 域模型规划

#### ODS 层（操作数据存储）

| 表名 | 说明 |
|------|------|
| `ods_iot_camera.csv` | 摄像头设备表 |
| `ods_iot_weightbridge.csv` | 地磅设备表 |
| `ods_iot_electronic_lock.csv` | 电子锁设备表 |
| `ods_iot_card_reader.csv` | 读卡器设备表 |
| `ods_iot_auto_machine.csv` | 自助终端表 |
| `ods_iot_road_gate.csv` | 道闸设备表 |
| `ods_iot_device_info.csv` | 盘料仪设备表 |
| `ods_iot_camera_pic.csv` | 摄像头抓拍记录表 |
| `ods_iot_camera_make_inventory.csv` | 摄像头盘点明细表 |
| `ods_iot_camera_make_inventory_info.csv` | AI 盘点任务表 |
| `ods_iot_weight_record.csv` | 称重记录表 |
| `ods_iot_weight_record_log.csv` | 称重日志表 |
| `ods_iot_lock_password.csv` | 电子锁密码表 |
| `ods_iot_lock_state.csv` | 电子锁状态表 |
| `ods_iot_road_gate_record.csv` | 道闸通行记录表 |
| `ods_iot_warn_detail.csv` | 预警明细表 |
| `ods_iot_device_event.csv` | 设备事件表（牧场） |
| `ods_iot_piggery.csv` | 猪场信息表 |
| `ods_iot_piggery_device.csv` | 猪场设备关联表 |
| `ods_iot_device_on_line.csv` | 设备在线状态表 |
| `ods_iot_op_log.csv` | 操作日志表 |

#### DIM 层（维度表）

| 表名 | 说明 |
|------|------|
| `dim_iot_device.sql` | 设备统一维度表（全量） |
| `dim_iot_camera.sql` | 摄像头维度表（全量） |
| `dim_iot_weightbridge.sql` | 地磅维度表（全量） |
| `dim_iot_electronic_lock.sql` | 电子锁维度表（全量） |
| `dim_iot_warehouse.sql` | 仓库维度表（关联 IoT 设备） |

#### DWD 层（数据仓库明细层）

| 表名 | 类型 | 说明 |
|------|------|------|
| `dwd_iot_camera_capture_fact_i.sql` | fact | 摄像头抓拍明细(增量) |
| `dwd_iot_weight_fact_i.sql` | fact | 称重过磅明细(增量) |
| `dwd_iot_lock_op_fact_i.sql` | fact | 电子锁操作明细(增量) |
| `dwd_iot_gate_access_fact_i.sql` | fact | 道闸通行明细(增量) |
| `dwd_iot_warn_fact_i.sql` | fact | 预警告警明细(增量) |
| `dwd_iot_inventory_fact_i.sql` | fact | AI 盘点明细(增量) |
| `dwd_iot_ranch_event_fact_i.sql` | fact | 牧场设备事件明细(增量) |
| `dwd_iot_device_op_log_fact_i.sql` | fact | 设备操作日志明细(增量) |

#### DWS 层（数据仓库汇总层）

**状态表（日全量覆盖）**

| 表名 | 说明 |
|------|------|
| `dws_iot_device_state_df.sql` | 设备当前状态(日全量) |
| `dws_iot_camera_state_df.sql` | 摄像头当前状态(日全量) |
| `dws_iot_lock_state_df.sql` | 电子锁当前状态(日全量) |

**聚合表（按日/月追加）**

| 表名 | 说明 |
|------|------|
| `dws_iot_camera_capture_agg_di.sql` | 摄像头抓拍日统计(日增量) |
| `dws_iot_weight_agg_di.sql` | 称重过磅日统计(日增量) |
| `dws_iot_gate_access_agg_di.sql` | 道闸通行日统计(日增量) |
| `dws_iot_warn_agg_di.sql` | 预警日统计(日增量) |
| `dws_iot_inventory_agg_di.sql` | AI 盘点日统计(日增量) |
| `dws_iot_device_online_agg_di.sql` | 设备在线率日统计(日增量) |
| `dws_iot_ranch_event_agg_di.sql` | 牧场事件日统计(日增量) |
| `dws_iot_weight_agg_mi.sql` | 称重过磅月统计(月增量) |
| `dws_iot_device_online_agg_mi.sql` | 设备在线率月统计(月增量) |

#### ADS 层（应用数据服务层）

| 表名 | 说明 |
|------|------|
| `ads_iot_device_dashboard_df.sql` | IoT 设备运营看板(日全量) |
| `ads_iot_weight_summary_di.sql` | 称重业务日报(日增量) |
| `ads_iot_warn_analysis_di.sql` | 预警分析报表(日增量) |
| `ads_iot_inventory_analysis_di.sql` | AI 盘点分析报表(日增量) |
| `ads_iot_ranch_monitor_di.sql` | 牧场监控日报(日增量) |
| `ads_iot_device_health_agg_mi.sql` | 设备健康月报(月增量) |
| `ads_iot_weight_monthly_agg_mi.sql` | 称重业务月报(月增量) |

---

## 🚀 数据仓库建设建议

### ODS 层

- 直接加载业务表数据，保持原结构
- 统一 `device_id` + `device_type` 作为设备主键
- 添加 `etl_time` 数据抽取时间戳

### DIM 层

- `dim_iot_device` — 设备统一维度表（整合摄像头/地磅/电子锁/道闸/读卡器）
- `dim_iot_camera` — 摄像头维度表（含品牌、型号、监控方式、所属权等属性）
- `dim_iot_weightbridge` — 地磅维度表（含类型、启用状态）
- `dim_iot_electronic_lock` — 电子锁维度表（含锁类型、密码、位置）
- `dim_iot_warehouse` — 仓库维度（含关联设备信息）

### DWD 层

核心事务事实表：
- `dwd_iot_camera_capture_fact_i` — 摄像头抓拍事实表
- `dwd_iot_weight_fact_i` — 称重过磅事实表
- `dwd_iot_lock_op_fact_i` — 电子锁操作事实表
- `dwd_iot_gate_access_fact_i` — 道闸通行事实表
- `dwd_iot_warn_fact_i` — 预警事实表
- `dwd_iot_inventory_fact_i` — AI 盘点事实表
- `dwd_iot_ranch_event_fact_i` — 牧场事件事实表

### DWS 层

核心汇总表：
- `dws_iot_device_state_df` — 设备状态日快照
- `dws_iot_device_online_agg_di` — 设备在线率日统计
- `dws_iot_weight_agg_di` — 称重日统计
- `dws_iot_warn_agg_di` — 预警日统计
- `dws_iot_inventory_agg_di` — AI 盘点日统计

### ADS 层

核心应用表：
- `ads_iot_device_dashboard_df` — IoT 运营看板
- `ads_iot_ranch_monitor_di` — 牧场监控日报
- `ads_iot_device_health_agg_mi` — 设备健康月报

---

## 📝 总结

IoT 业务是一个以**仓储物流 + AI 视觉 + 产融风控**为核心特色的物联网管理平台：

1. **设备多元化**: 摄像头、地磅、电子锁、道闸、读卡器、盘料仪、自助终端等 7+ 类设备
2. **场景全覆盖**: 从车辆入厂、称重计量、AI 盘点到电子锁施封的全流程 IoT 管控
3. **AI 赋能**: 基于摄像头图片的 AI 自动盘点，边缘计算支持本地化处理
4. **产融结合**: 牧场摄像头监控与贷款风控联动，实现活体资产远程监管
5. **安全管控**: 电子锁施封/解封 + GPS 定位，保障货物运输安全

建议在数据仓库建设时，重点突出：
- **设备运营效率**分析（在线率、故障率、预警响应时效）
- **称重计量**分析（过磅量趋势、盈亏率、扣重率）
- **AI 盘点准确率**分析（差异率、异常率、盘点效率提升）
- **牧场贷后风控**分析（存栏变化、出栏率、资产监控覆盖率）

---

*本分析基于数据库抽样数据生成，仅供数据仓库建设参考*
