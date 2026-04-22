import os, glob, csv

# 入参配置
SEEDS_DIR = "seeds"           # seeds 文件夹路径
LIMIT = 200                   # 每条 CSV 保留的最大行数（不含表头）

def main():
    """截取 seeds 目录下所有 CSV 文件的前 LIMIT 条数据（保留表头），不足则全部保留。"""
    for path in glob.glob(os.path.join(SEEDS_DIR, "*.csv")):
        with open(path, "r", newline="", encoding="utf-8") as f:
            reader = csv.reader(f)
            header = next(reader)
            rows = [row for _, row in zip(range(LIMIT), reader)]
        with open(path, "w", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(header)
            writer.writerows(rows)

if __name__ == "__main__":
    main()