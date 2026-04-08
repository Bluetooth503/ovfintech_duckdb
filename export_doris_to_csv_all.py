#!/usr/bin/env python3
"""Doris ODS层数据导出到CSV脚本"""

import csv
import pymysql
from pathlib import Path
import logging

# ==================== 配置参数 ====================
# Doris数据库连接配置（从profiles.yml读取）
DORIS_HOST = '172.16.17.176'
DORIS_PORT = 9030
DORIS_USER = 'root'
DORIS_PASSWORD = 'ggjx2024_qa'
DORIS_DATABASE = 'ods'

# 数据导出配置
SEEDS_DIR = './seeds'

# CSV文件名到Doris表名的手工映射配置（去掉.csv扩展名）
TABLE_MAPPING = {
    'ods_ranch': 'ods_ranch_ranch',
    'ods_ranch_stall': 'ods_ranch_ranch_stall',
    'ods_ranch_onstall': 'ods_ranch_ranch_onstall',
    'ods_psi_cattle_purchase': 'ods_ranch_psi_cattle_purchase',
    'ods_psi_cattle_sell': 'ods_ranch_psi_cattle_sell',
    'ods_psi_cattle_return': 'ods_ranch_psi_cattle_return',
    'ods_psi_cattle_price': 'ods_ranch_psi_cattle_price',
    'ods_psi_sample_weight': 'ods_ranch_psi_sample_weight',
    'ods_psi_stall_daily_report': 'ods_ranch_psi_stall_daily_report',
    'ods_psi_livestock_consume': 'ods_ranch_psi_livestock_consume',
    'ods_psi_recipe': 'ods_ranch_psi_recipe',
    'ods_psi_cattle_grow_config': 'ods_ranch_psi_cattle_grow_config',
    'ods_psi_commodity': 'ods_ranch_psi_commodity',
    'ods_psi_feed_formula': 'ods_ranch_psi_feed_formula',
    'ods_psi_cattle_hth_daily_rpt': 'ods_ranch_psi_cattle_hth_daily_rpt',
    'ods_psi_cattle_feed_detail': 'ods_ranch_psi_cattle_feed_detail',

    # 'ods_ranch_onstall_history': 'ods_ranch_ranch_onstall_history',
    # 'ods_psi_ranch_synthesize': 'ods_psi_ranch_synthesize',
    # 'ods_psi_in_out_warehouse': 'ods_psi_in_out_warehouse',
    # 'ods_psi_inventory': 'ods_psi_inventory',
    # 'ods_psi_inventory_detail': 'ods_psi_inventory_detail',
    # 'ods_psi_warehouse': 'ods_psi_warehouse',
    # 'ods_psi_warehouse_stock_history': 'ods_psi_warehouse_stock_history',
}

# 日志配置
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


class DorisCSVExporter:
    """Doris数据库到CSV的数据导出器"""

    def __init__(self):
        """初始化导出器"""
        self.connection = pymysql.connect(host=DORIS_HOST, port=DORIS_PORT, user=DORIS_USER, password=DORIS_PASSWORD, database=DORIS_DATABASE, charset='utf8mb4', cursorclass=pymysql.cursors.DictCursor)
        self.seeds_dir = Path(SEEDS_DIR)
        logger.info(f"成功连接到Doris数据库: {DORIS_HOST}:{DORIS_PORT}/{DORIS_DATABASE}")

    def close(self):
        """关闭数据库连接"""
        if self.connection: self.connection.close()

    def get_csv_files(self):
        """获取seeds目录下所有CSV文件"""
        return list(self.seeds_dir.glob("*.csv"))

    def find_matching_tables(self):
        """根据手工映射查找CSV文件与数据库表的对应关系"""
        matches = []
        for csv_file in self.get_csv_files():
            csv_name = csv_file.stem
            if csv_name in TABLE_MAPPING:
                matches.append((csv_file, TABLE_MAPPING[csv_name]))
                logger.info(f"映射: {csv_file.name} -> {TABLE_MAPPING[csv_name]}")
            else:
                logger.warning(f"未配置映射: {csv_file.name}，请在TABLE_MAPPING中添加")
        return matches

    def get_csv_columns(self, csv_file):
        """获取CSV文件的列名和顺序"""
        with open(csv_file, 'r', encoding='utf-8') as f:
            return next(csv.reader(f))

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
        """从Doris表导出数据到CSV文件"""
        csv_columns = self.get_csv_columns(csv_file)
        table_columns = self.get_table_columns(table_name)
        # logger.info(f"CSV列: {csv_columns}")
        # logger.info(f"表列: {table_columns}")

        is_valid, select_columns = self.validate_columns(csv_columns, table_columns)
        if not is_valid:
            logger.error(f"列不匹配，跳过 {csv_file.name}")
            return False

        columns_str = ', '.join([f"`{col}`" for col in select_columns])

        # 检查表是否有 id 和 up_dt 列，有则去重取最新记录
        if 'id' in table_columns and 'up_dt' in table_columns:
            sql = f"""
                SELECT {columns_str}
                FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY `id` ORDER BY `up_dt` DESC) as rn FROM {table_name}) t
                WHERE rn = 1
            """
        else:
            sql = f"""
                SELECT {columns_str}
                FROM {table_name}
            """
        # logger.info(f"执行SQL: {sql.replace(chr(10), ' ').replace(chr(13), ' ')}")

        cursor = self.connection.cursor()
        cursor.execute(sql)
        rows = cursor.fetchall()

        if not rows:
            logger.warning(f"表 {table_name} 中没有数据")
            cursor.close()
            return False

        # 先清空文件，只保留表头
        with open(csv_file, 'w', encoding='utf-8', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=select_columns)
            writer.writeheader()

        # 追加Doris数据
        with open(csv_file, 'a', encoding='utf-8', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=select_columns)
            for row in rows:
                ordered_row = {col: row.get(col, '') for col in select_columns}
                writer.writerow(ordered_row)

        cursor.close()
        logger.info(f"成功覆盖 {len(rows)} 条数据到 {csv_file.name}")
        return True

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
