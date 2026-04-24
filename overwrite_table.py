#!/usr/bin/env python3
import duckdb
import pandas as pd

csv_path = "/Users/enlai/ovfintech_duckdb/dim_wms_warehouse_goods_owner_rel.csv"
db_path = "/Users/enlai/ovfintech_duckdb/dev.duckdb"
table_name = "dim_wms_warehouse_goods_owner_rel"

print(f"读取CSV文件: {csv_path}")
df = pd.read_csv(csv_path)
print(f"CSV行数: {len(df)}")

print(f"连接到DuckDB数据库: {db_path}")
conn = duckdb.connect(db_path)

try:
    # 删除表中的现有数据
    print(f"清空表 {table_name} 的现有数据...")
    conn.execute(f"DELETE FROM {table_name}")
    print("数据已清空")

    # 插入CSV数据
    print("插入CSV数据到表中...")
    conn.register("temp_data", df)
    conn.execute(f"INSERT INTO {table_name} SELECT * FROM temp_data")
    conn.unregister("temp_data")
    print("数据插入完成")

    # 验证数据
    result = conn.execute(f"SELECT COUNT(*) FROM {table_name}").fetchone()
    print(f"表中当前行数: {result[0]}")

except Exception as e:
    print(f"错误: {e}")
    raise
finally:
    conn.close()
    print("数据库连接已关闭")

print("操作完成")
