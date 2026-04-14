-- =============================================
-- 模型名称：dim_customer_value_label
-- 模型描述：客户价值标签维度表 - 支持RFM客户分群和价值分析
-- 作者：dbt
-- 创建时间：2026-04-10
-- =============================================
{{ config(
    materialized='table',
    description='客户价值标签维度表，记录客户RFM分群标签和价值等级',
    tags=['fund', 'dim', 'customer', 'value_label', 'rfm']
) }}

WITH rfm_scoring_rules AS (
    -- RFM评分规则配置
    SELECT
        1 AS rule_id,
        'R_Scoring' AS rule_type,
        '最近活跃度评分' AS rule_name,
        '最近天数越小，评分越高（1-5分）' AS rule_description,
        '0-7天:5分, 8-30天:4分, 31-90天:3分, 91-180天:2分, >180天:1分' AS scoring_rule
    UNION ALL
    SELECT
        2 AS rule_id,
        'F_Scoring' AS rule_type,
        '购买频次评分' AS rule_name,
        '购买次数越多，评分越高（1-5分）' AS rule_description,
        '>100次:5分, 50-99次:4分, 20-49次:3分, 5-19次:2分, 1-4次:1分' AS scoring_rule
    UNION ALL
    SELECT
        3 AS rule_id,
        'M_Scoring' AS rule_type,
        '消费金额评分' AS rule_name,
        '消费金额越高，评分越高（1-5分）' AS rule_description,
        '>=100万:5分, 50-99.9万:4分, 10-49.9万:3分, 1-9.9万:2分, <1万:1分' AS scoring_rule
),

customer_segments AS (
    -- 客户分群定义
    SELECT
        1 AS segment_id,
        '核心价值客户' AS segment_name,
        '高消费+高活跃+高忠诚' AS segment_desc,
        15 AS max_rfm_score,
        12 AS min_rfm_score,
        'R>=4 AND F>=4 AND M>=4' AS segment_rule,
        '需要重点维护和营销，提供VIP服务' AS strategy
    UNION ALL
    SELECT
        2 AS segment_id,
        '大额消费客户' AS segment_name,
        '高消费+低活跃+低忠诚' AS segment_desc,
        11 AS max_rfm_score,
        9 AS min_rfm_score,
        'M=5 AND (R<=3 OR F<=3)' AS segment_rule,
        '需关注业务模式和需求，避免流失' AS strategy
    UNION ALL
    SELECT
        3 AS segment_id,
        '潜力价值客户' AS segment_name,
        '高消费+低活跃+高忠诚' AS segment_desc,
        11 AS max_rfm_score,
        9 AS min_rfm_score,
        'M=5 AND R<=3 AND F>=4' AS segment_rule,
        '通过营销活动唤醒，提升活跃度' AS strategy
    UNION ALL
    SELECT
        4 AS segment_id,
        '高消费客户' AS segment_name,
        '高消费+高活跃+低忠诚' AS segment_desc,
        11 AS max_rfm_score,
        8 AS min_rfm_score,
        'M=5 AND R>=4 AND F<=3' AS segment_rule,
        '通过会员体系提升忠诚度' AS strategy
    UNION ALL
    SELECT
        5 AS segment_id,
        '潜力流失客户' AS segment_name,
        '高消费+低活跃+低忠诚' AS segment_desc,
        11 AS max_rfm_score,
        7 AS min_rfm_score,
        'M=5 AND R<=3 AND F<=3' AS segment_rule,
        '通过营销活动挽回，防止流失' AS strategy
    UNION ALL
    SELECT
        6 AS segment_id,
        '新客户' AS segment_name,
        '低消费+低活跃+高忠诚' AS segment_desc,
        8 AS max_rfm_score,
        5 AS min_rfm_score,
        'M<=3 AND R<=3 AND F>=4' AS segment_rule,
        '通过营销活动提升活跃度和消费金额' AS strategy
    UNION ALL
    SELECT
        7 AS segment_id,
        '沉睡客户' AS segment_name,
        '低消费+高活跃+低忠诚' AS segment_desc,
        8 AS max_rfm_score,
        6 AS min_rfm_score,
        'M<=3 AND R>=4 AND F<=3' AS segment_rule,
        '通过营销活动唤醒，防止流失' AS strategy
    UNION ALL
    SELECT
        8 AS segment_id,
        '流失客户' AS segment_name,
        '低消费+低活跃+低忠诚' AS segment_desc,
        7 AS max_rfm_score,
        3 AS min_rfm_score,
        'R<=3 AND F<=3 AND M<=3' AS segment_rule,
        '各指标均较低，属于低价值客户，维持基础服务' AS strategy
),

value_levels AS (
    -- 客户价值等级定义
    SELECT
        1 AS level_id,
        'S级' AS level_name,
        '核心价值客户' AS level_desc,
        '前20%高价值客户' AS criteria,
        '红色' AS color,
        '需要重点维护' AS priority
    UNION ALL
    SELECT
        2 AS level_id,
        'A级' AS level_name,
        '重要价值客户' AS level_desc,
        '前20%-40%价值客户' AS criteria,
        '橙色' AS color,
        '需要重点关注' AS priority
    UNION ALL
    SELECT
        3 AS level_id,
        'B级' AS level_name,
        '一般价值客户' AS level_desc,
        '前40%-70%价值客户' AS criteria,
        '黄色' AS color,
        '需要保持关注' AS priority
    UNION ALL
    SELECT
        4 AS level_id,
        'C级' AS level_name,
        '低价值客户' AS level_desc,
        '后30%价值客户' AS criteria,
        '灰色' AS color,
        '基础服务' AS priority
)

SELECT
    -- RFM评分规则
    rs.rule_id,                    -- 规则ID
    rs.rule_type,                  -- 规则类型
    rs.rule_name,                  -- 规则名称
    rs.rule_description,           -- 规则描述
    rs.scoring_rule,               -- 评分规则

    -- 客户分群信息
    cs.segment_id,                 -- 分群ID
    cs.segment_name,               -- 分群名称
    cs.segment_desc,               -- 分群描述
    cs.min_rfm_score,              -- 最小RFM分数
    cs.max_rfm_score,              -- 最大RFM分数
    cs.segment_rule,               -- 分群规则
    cs.strategy,                   -- 营销策略

    -- 客户价值等级
    vl.level_id,                   -- 等级ID
    vl.level_name,                 -- 等级名称
    vl.level_desc,                 -- 等级描述
    vl.criteria,                   -- 等级标准
    vl.color,                      -- 显示颜色
    vl.priority,                   -- 优先级

    -- SCD Type 2 字段
    CURRENT_TIMESTAMP AS dw_effective_date,   -- 生效日期
    CAST('9999-12-31 23:59:59' AS TIMESTAMP) AS dw_expiry_date,  -- 失效日期
    '1' AS is_current             -- 是否当前记录

FROM rfm_scoring_rules rs
CROSS JOIN customer_segments cs
CROSS JOIN value_levels vl
ORDER BY cs.segment_id, vl.level_id, rs.rule_id