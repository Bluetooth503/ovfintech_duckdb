#!/usr/bin/env python3
"""Doris ODS层数据导出到CSV脚本"""

import csv, logging, time
from pathlib import Path
import pymysql

# ==================== 配置参数 ====================
DORIS_HOST = '172.16.17.176'    # Doris数据库主机
DORIS_PORT = 9030               # Doris数据库端口
DORIS_USER = 'root'             # Doris数据库用户名
DORIS_PASSWORD = 'ggjx2024_qa'  # Doris数据库密码
DORIS_DATABASE = 'ods'          # Doris数据库名
SEEDS_DIR = './seeds'           # 数据导出目录
TABLE_MAPPING = {
    # 已全量提取
    # 'ods_mem_company': 'ods_mem_company',
    # 'ods_mem_member': 'ods_mem_member',
    # 'ods_customer_tag_assign': 'ods_customer_tag_assign',

    # 尚未提取
}

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


class DorisCSVExporter:
    """Doris数据库到CSV的数据导出器"""

    def __init__(self):
        """初始化导出器，建立数据库连接"""
        self.connection = pymysql.connect(host=DORIS_HOST, port=DORIS_PORT, user=DORIS_USER, password=DORIS_PASSWORD, database=DORIS_DATABASE, charset='utf8mb4', cursorclass=pymysql.cursors.DictCursor, connect_timeout=300, read_timeout=600, write_timeout=300)
        self.ss_connection = pymysql.connect(host=DORIS_HOST, port=DORIS_PORT, user=DORIS_USER, password=DORIS_PASSWORD, database=DORIS_DATABASE, charset='utf8mb4', cursorclass=pymysql.cursors.SSDictCursor, connect_timeout=300, read_timeout=600, write_timeout=300)
        self.seeds_dir = Path(SEEDS_DIR)
        logger.info(f"成功连接到Doris数据库: {DORIS_HOST}:{DORIS_PORT}/{DORIS_DATABASE}")

    def close(self):
        """关闭数据库连接"""
        if self.connection: self.connection.close()
        if self.ss_connection: self.ss_connection.close()

    def find_matching_tables(self):
        """根据TABLE_MAPPING配置直接处理指定的表"""
        matches = [(self.seeds_dir / f"{csv_name}.csv", table_name) for csv_name, table_name in TABLE_MAPPING.items()]
        for csv_file, table_name in matches: logger.info(f"配置: {csv_file.name} -> {table_name}")
        return matches

    def get_csv_columns(self, csv_file):
        """获取CSV文件的列名和顺序"""
        with open(csv_file, 'r', encoding='utf-8') as f: return next(csv.reader(f))

    def get_table_columns(self, table_name):
        """获取数据库表的列名和顺序"""
        cursor = self.connection.cursor()
        cursor.execute(f"DESCRIBE {table_name}")
        columns = [row['Field'] for row in cursor.fetchall()]
        cursor.close()
        return columns

    def validate_columns(self, csv_columns, table_columns):
        """验证CSV和数据库表的列是否匹配"""
        missing_in_table = set(csv_columns) - set(table_columns)
        if missing_in_table:
            logger.warning(f"表中缺少CSV中的列: {missing_in_table}")
            return False, []
        return True, csv_columns

    def export_table_to_csv(self, csv_file, table_name):
        """从Doris表导出数据到CSV文件（分页处理，避免超时和内存溢出）"""
        csv_columns = self.get_csv_columns(csv_file)
        table_columns = self.get_table_columns(table_name)
        is_valid, select_columns = self.validate_columns(csv_columns, table_columns)
        if not is_valid:
            logger.error(f"列不匹配，跳过 {csv_file.name}")
            return False
        columns_str = ', '.join([f"`{col}`" for col in select_columns])
        with open(csv_file, 'w', encoding='utf-8', newline='') as f:
            csv.DictWriter(f, fieldnames=select_columns).writeheader()
        row_count = 0
        page_size = 50000
        with open(csv_file, 'a', encoding='utf-8', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=select_columns)
            if 'id' in table_columns and 'up_dt' in table_columns:
                offset = 0
                while True:
                    sql = f"""
                        SELECT {columns_str}
                        FROM (
                            SELECT {columns_str},
                                   ROW_NUMBER() OVER (PARTITION BY `id` ORDER BY `up_dt` DESC) as rn
                            FROM {table_name}
                        ) t
                        WHERE rn = 1
                        LIMIT {page_size} OFFSET {offset}
                    """
                    rows = self._execute_query(sql)
                    if not rows: break
                    for row in rows:
                        ordered_row = {col: row.get(col, '') for col in select_columns}
                        writer.writerow(ordered_row)
                        row_count += 1
                    logger.info(f"  {csv_file.name}: 已导出 {row_count} 条 (OFFSET {offset})...")
                    offset += page_size
            else:
                offset = 0
                while True:
                    sql = f"SELECT {columns_str} FROM {table_name} LIMIT {page_size} OFFSET {offset}"
                    rows = self._execute_query(sql)
                    if not rows: break
                    for row in rows:
                        ordered_row = {col: row.get(col, '') for col in select_columns}
                        writer.writerow(ordered_row)
                        row_count += 1
                    logger.info(f"  {csv_file.name}: 已导出 {row_count} 条 (OFFSET {offset})...")
                    offset += page_size
        if row_count == 0:
            logger.warning(f"表 {table_name} 中没有数据")
            return False
        logger.info(f"成功覆盖 {row_count} 条数据到 {csv_file.name}")
        return True

    def _execute_query(self, sql):
        """执行SQL查询，带重试机制"""
        max_retries = 3
        for attempt in range(max_retries):
            cursor = self.connection.cursor()
            try:
                cursor.execute(sql)
                rows = cursor.fetchall()
                cursor.close()
                return rows
            except Exception as e:
                cursor.close()
                if attempt < max_retries - 1:
                    logger.warning(f"查询失败，第{attempt + 1}次重试: {e}")
                    time.sleep(2)
                else:
                    raise
        return []

    def run(self):
        """执行导出流程"""
        matches = self.find_matching_tables()
        if not matches:
            logger.warning("没有找到匹配的表")
            return
        logger.info(f"共找到 {len(matches)} 个匹配的表-CSV对")
        success_count = sum(1 for csv_file, table_name in matches if self.export_table_to_csv(csv_file, table_name))
        fail_count = len(matches) - success_count
        logger.info(f"\n导出完成: 成功 {success_count}, 失败 {fail_count}")
        self.close()


if __name__ == '__main__':
    logger.info("=" * 60)
    logger.info("Doris ODS层数据导出到CSV脚本")
    logger.info("=" * 60)
    DorisCSVExporter().run()
