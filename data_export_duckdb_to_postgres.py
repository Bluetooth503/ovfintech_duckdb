"""DuckDB到PostgreSQL数据同步脚本"""

import duckdb
import pandas as pd
from sqlalchemy import create_engine
from sqlalchemy.types import TypeDecorator
from sqlalchemy.dialects.postgresql import insert

# ============ 入参配置 ============
DUCKDB_PATH = '/Users/enlai/ovfintech_duckdb/dev.duckdb'
POSTGRES_URL = 'postgresql://ovfintech:xRzcErWS7j7Z6nGc@111.228.40.184:5432/postgresql_jdyun02_ovfintech'
TABLE_PREFIX = 'ads_'
BATCH_SIZE = 10000  # 批量插入大小
# =================================


def get_duckdb_tables(conn, prefix=''):
    """获取DuckDB中指定前缀的表列表"""
    return [t[0] for t in conn.execute(f"SELECT table_name FROM information_schema.tables WHERE table_name LIKE '{prefix}%'").fetchall()]


def get_table_schema(conn, table_name):
    """获取DuckDB表结构"""
    return conn.execute(f"DESCRIBE {table_name}").fetchall()


def create_postgres_table(pg_conn, table_name, schema):
    """在PostgreSQL中创建表"""
    columns = []
    for col in schema:
        col_name, col_type = col[0], col[1]
        pg_type = col_type.upper()
        if 'VARCHAR' in pg_type or 'TEXT' in pg_type:
            pg_type = 'VARCHAR'
        elif 'BIGINT' in pg_type or 'INT8' in pg_type:
            pg_type = 'BIGINT'
        elif 'INTEGER' in pg_type or 'INT4' in pg_type or 'INT' in pg_type:
            pg_type = 'INTEGER'
        elif 'DOUBLE' in pg_type or 'FLOAT' in pg_type:
            pg_type = 'DOUBLE PRECISION'
        elif 'BOOLEAN' in pg_type or 'BOOL' in pg_type:
            pg_type = 'BOOLEAN'
        elif 'DATE' in pg_type:
            pg_type = 'DATE'
        elif 'TIMESTAMP' in pg_type:
            pg_type = 'TIMESTAMP'
        elif 'DECIMAL' in pg_type:
            pg_type = 'DECIMAL'
        columns.append(f"{col_name} {pg_type}")
    pg_conn.execute(f"CREATE TABLE IF NOT EXISTS {table_name} ({', '.join(columns)})")


def sync_table(duck_conn, pg_engine, table_name):
    """同步单个表数据"""
    df = duck_conn.execute(f"SELECT * FROM {table_name}").fetchdf()
    if df.empty:
        return
    df.to_sql(table_name, pg_engine, if_exists='replace', index=False, chunksize=BATCH_SIZE)


def main():
    """主函数：同步所有ads_开头的表"""
    duck_conn = duckdb.connect(DUCKDB_PATH)
    pg_engine = create_engine(POSTGRES_URL)
    pg_conn = pg_engine.connect()

    tables = get_duckdb_tables(duck_conn, TABLE_PREFIX)
    print(f"找到 {len(tables)} 个 {TABLE_PREFIX} 开头的表")

    for table in tables:
        print(f"正在同步表: {table}")
        try:
            schema = get_table_schema(duck_conn, table)
            create_postgres_table(pg_conn, table, schema)
            sync_table(duck_conn, pg_engine, table)
            print(f"✓ {table} 同步完成")
        except Exception as e:
            print(f"✗ {table} 同步失败: {e}")

    pg_conn.close()
    duck_conn.close()
    print("所有表同步完成!")


if __name__ == '__main__':
    main()
