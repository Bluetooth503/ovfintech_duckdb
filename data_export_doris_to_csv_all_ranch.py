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
    # 维度
    'ods_sys_tenant': 'ods_ranch_sys_tenant',
    'ods_ranch': 'ods_ranch_ranch',
    'ods_ranch_stall': 'ods_ranch_ranch_stall',
    'ods_psi_recipe': 'ods_ranch_psi_recipe',
    'ods_psi_commodity': 'ods_ranch_psi_commodity', 
    'ods_psi_feed_formula': 'ods_ranch_psi_feed_formula',
    'ods_psi_cattle_grow_config': 'ods_ranch_psi_cattle_grow_config', 

    # 入栏, 出栏, 在栏
    'ods_ranch_onstall': 'ods_ranch_ranch_onstall',
    # 'ods_ranch_onstall_history': 'ods_ranch_ranch_onstall_history',
    'ods_ranch_install': 'ods_ranch_ranch_install',
    'ods_ranch_outstall': 'ods_ranch_ranch_outstall',

    # 喂养
    # 'ods_psi_cattle_feed_detail_3': 'ods_ranch_psi_cattle_feed_detail_3',
    # 'ods_psi_cattle_feed_detail_4': 'ods_ranch_psi_cattle_feed_detail_4',
    # 'ods_psi_cattle_feed_detail_5': 'ods_ranch_psi_cattle_feed_detail_5',
    # 'ods_psi_cattle_feed_detail_6': 'ods_ranch_psi_cattle_feed_detail_6',
    # 'ods_psi_cattle_feed_detail_7': 'ods_ranch_psi_cattle_feed_detail_7',
    # 'ods_psi_cattle_feed_detail_8': 'ods_ranch_psi_cattle_feed_detail_8',
    # 'ods_psi_cattle_feed_detail_9': 'ods_ranch_psi_cattle_feed_detail_9',
    # 'ods_psi_cattle_feed_detail_10': 'ods_ranch_psi_cattle_feed_detail_10', 
    # 'ods_psi_cattle_feed_detail_11': 'ods_ranch_psi_cattle_feed_detail_11', 
    # 'ods_psi_cattle_feed_detail_12': 'ods_ranch_psi_cattle_feed_detail_12', 
    # 'ods_psi_cattle_feed_detail_13': 'ods_ranch_psi_cattle_feed_detail_13', 
    # 'ods_psi_cattle_feed_detail_14': 'ods_ranch_psi_cattle_feed_detail_14', 
    # 'ods_psi_cattle_feed_detail_15': 'ods_ranch_psi_cattle_feed_detail_15', 
    # 'ods_psi_cattle_feed_detail_16': 'ods_ranch_psi_cattle_feed_detail_16', 
    # 'ods_psi_cattle_feed_detail_17': 'ods_ranch_psi_cattle_feed_detail_17', 
    # 'ods_psi_cattle_feed_detail_18': 'ods_ranch_psi_cattle_feed_detail_18', 
    # 'ods_psi_cattle_feed_detail_19': 'ods_ranch_psi_cattle_feed_detail_19', 
    # 'ods_psi_cattle_feed_detail_20': 'ods_ranch_psi_cattle_feed_detail_20', 
    # 'ods_psi_cattle_feed_detail_21': 'ods_ranch_psi_cattle_feed_detail_21', 
    # 'ods_psi_cattle_feed_detail_22': 'ods_ranch_psi_cattle_feed_detail_22', 
    # 'ods_psi_cattle_feed_detail_23': 'ods_ranch_psi_cattle_feed_detail_23', 
    # 'ods_psi_cattle_feed_detail_24': 'ods_ranch_psi_cattle_feed_detail_24', 
    # 'ods_psi_cattle_feed_detail_25': 'ods_ranch_psi_cattle_feed_detail_25', 
    # 'ods_psi_cattle_feed_detail_26': 'ods_ranch_psi_cattle_feed_detail_26', 
    # 'ods_psi_cattle_feed_detail_27': 'ods_ranch_psi_cattle_feed_detail_27', 
    # 'ods_psi_cattle_feed_detail_28': 'ods_ranch_psi_cattle_feed_detail_28', 
    # 'ods_psi_cattle_feed_detail_29': 'ods_ranch_psi_cattle_feed_detail_29', 
    # 'ods_psi_cattle_feed_detail_30': 'ods_ranch_psi_cattle_feed_detail_30', 
    # 'ods_psi_cattle_feed_detail_31': 'ods_ranch_psi_cattle_feed_detail_31', 
    # 'ods_psi_cattle_feed_detail_32': 'ods_ranch_psi_cattle_feed_detail_32', 
    # 'ods_psi_cattle_feed_detail_33': 'ods_ranch_psi_cattle_feed_detail_33', 
    # 'ods_psi_cattle_feed_detail_34': 'ods_ranch_psi_cattle_feed_detail_34', 
    # 'ods_psi_cattle_feed_detail_35': 'ods_ranch_psi_cattle_feed_detail_35', 
    # 'ods_psi_cattle_feed_detail_36': 'ods_ranch_psi_cattle_feed_detail_36', 
    # 'ods_psi_cattle_feed_detail_37': 'ods_ranch_psi_cattle_feed_detail_37', 
    # 'ods_psi_cattle_feed_detail_38': 'ods_ranch_psi_cattle_feed_detail_38', 
    # 'ods_psi_cattle_feed_detail_39': 'ods_ranch_psi_cattle_feed_detail_39', 
    # 'ods_psi_cattle_feed_detail_40': 'ods_ranch_psi_cattle_feed_detail_40', 
    # 'ods_psi_cattle_feed_detail_41': 'ods_ranch_psi_cattle_feed_detail_41', 
    # 'ods_psi_cattle_feed_detail_42': 'ods_ranch_psi_cattle_feed_detail_42', 
    # 'ods_psi_cattle_feed_detail_43': 'ods_ranch_psi_cattle_feed_detail_43', 
    # 'ods_psi_cattle_feed_detail_44': 'ods_ranch_psi_cattle_feed_detail_44', 
    # 'ods_psi_cattle_feed_detail_45': 'ods_ranch_psi_cattle_feed_detail_45', 
    # 'ods_psi_cattle_feed_detail_46': 'ods_ranch_psi_cattle_feed_detail_46', 
    # 'ods_psi_cattle_feed_detail_47': 'ods_ranch_psi_cattle_feed_detail_47', 
    # 'ods_psi_livestock_consume': 'ods_ranch_psi_livestock_consume',         

    # 价格, 称重, 采购, 销售
    'ods_psi_cattle_price': 'ods_ranch_psi_cattle_price',
    'ods_psi_sample_weight': 'ods_ranch_psi_sample_weight',
    'ods_psi_cattle_purchase': 'ods_ranch_psi_cattle_purchase',
    'ods_psi_cattle_sell': 'ods_ranch_psi_cattle_sell',
    'ods_psi_cattle_return': 'ods_ranch_psi_cattle_return',

    # report
    'ods_psi_cattle_hth_daily_rpt': 'ods_ranch_psi_cattle_hth_daily_rpt',
    # 'ods_psi_stall_daily_report': 'ods_ranch_psi_stall_daily_report',

    # ai相关
    'ods_psi_cattle_ai_score_result': 'ods_ranch_psi_cattle_ai_score_result', 
    'ods_psi_region_ai_data': 'ods_ranch_psi_region_ai_data',
    'ods_psi_region': 'ods_ranch_psi_region',
    'ods_psi_stall_region': 'ods_ranch_psi_stall_region',
}

# 日志配置
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