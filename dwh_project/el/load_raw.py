"""EL: load 4 bảng MySQL (tiktok_dashboard) -> schema `raw` trên PostgreSQL.

Mọi cột nạp dạng text (raw thật), việc làm sạch/ép kiểu thuộc về tầng staging của dbt.
Chạy TRƯỚC `dbt build`. Load kiểu replace-full (drop + create + COPY).

Kỹ thuật: đọc MySQL bằng server-side cursor (SSCursor) theo lô -> ghi Postgres bằng
COPY (FORMAT csv). Nhẹ RAM (không nạp cả bảng vào bộ nhớ) và nhanh với bảng lớn.

Cách chạy (tự đọc connections.env):
    ..\venv\Scripts\python.exe el\load_raw.py
"""
import csv
import io
import os

import psycopg2
import pymysql
import pymysql.cursors
from sqlalchemy.engine import URL


def _load_env_file(path):
    """Nạp connections.env vào os.environ (không ghi đè biến đã set sẵn).

    Hỗ trợ cả giá trị có/không bọc dấu ngoặc: MYSQL_USER="abc" hoặc MYSQL_USER=abc.
    """
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                v = v[1:-1]  # bỏ dấu ngoặc bao ngoài
            os.environ.setdefault(k.strip(), v)


_load_env_file(os.path.join(os.path.dirname(__file__), "..", "connections.env"))

MY = dict(
    host=os.environ["MYSQL_HOST"],
    port=int(os.getenv("MYSQL_PORT", "3306")),
    user=os.environ["MYSQL_USER"],
    password=os.environ["MYSQL_PASSWORD"],
    database=os.environ["MYSQL_DB"],
    charset="utf8mb4",
)
PG = dict(
    host=os.environ["DEST_HOST"],
    port=int(os.getenv("DEST_PORT", "5432")),
    user=os.environ["DEST_USER"],
    password=os.environ["DEST_PASSWORD"],
    dbname=os.environ["DEST_DB"],
)
# URL.create dùng cho các script phụ trợ (vd check_conn.py) — escape ký tự đặc biệt.
PG_URL = URL.create(
    "postgresql+psycopg2",
    username=PG["user"], password=PG["password"],
    host=PG["host"], port=PG["port"], database=PG["dbname"],
)
RAW = os.getenv("PG_RAW_SCHEMA", "raw")
BATCH = 50000

QUERIES = {
    "performance_list": """
        SELECT creator_id, video_id, `time`, creator_name, product_name, vv, comment, share,
               new_follower, clicks_from_view_to_like, product_impressions, click_on_the_product,
               customer, count_order, unit_sales, video_revenue, gpm, gmv, ctr,
               view_to_like_ratio, video_viewing_rate, co_ratio, date_file_excel, brand
        FROM tiktok_dashboard.performance_list""",
    "send_sample": """
        SELECT `Ngày duyệt mẫu` AS ngay_duyet_mau, `KOC/KOL` AS koc_kol, `PIC` AS pic,
               `Phân loại Creator` AS phan_loai_creator, `Nguồn yêu cầu` AS nguon_yeu_cau,
               `Tên sản phẩm` AS ten_san_pham, `SL` AS sl, `sheet`, `Số video` AS so_video,
               `MST/CCCD` AS mst_cccd, `Mã đơn hàng` AS ma_don_hang, `Vị trí` AS vi_tri,
               `cost`, `SDT` AS sdt
        FROM MVA_KOC_KOL_send_sample""",
    "product_name_map": """
        SELECT video_id, product_contain, product_contain_combo
        FROM get_product_name_from_video_tiktok""",
    "pic_team": """
        SELECT Raw_name AS raw_name, Change_name AS doi_ten, Team AS team
        FROM PIC_Team""",
}


def copy_table(myconn, pgconn, tbl, query):
    """Stream MySQL -> Postgres bằng COPY. Trả về số dòng."""
    cur = myconn.cursor(pymysql.cursors.SSCursor)  # streaming, không nạp cả bảng vào RAM
    cur.execute(query)
    cols = [d[0] for d in cur.description]

    pg = pgconn.cursor()
    pg.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"')
    pg.execute(f'DROP TABLE IF EXISTS "{RAW}"."{tbl}"')
    coldefs = ", ".join(f'"{c}" text' for c in cols)
    pg.execute(f'CREATE TABLE "{RAW}"."{tbl}" ({coldefs})')

    collist = ", ".join(f'"{c}"' for c in cols)
    # NULL '' : ô rỗng -> NULL (khớp với nullif(x,'') ở tầng staging).
    copy_sql = f"COPY \"{RAW}\".\"{tbl}\" ({collist}) FROM STDIN WITH (FORMAT csv, NULL '')"

    total = 0
    while True:
        rows = cur.fetchmany(BATCH)
        if not rows:
            break
        buf = io.StringIO()
        w = csv.writer(buf)
        for r in rows:
            w.writerow(["" if v is None else str(v) for v in r])
        buf.seek(0)
        pg.copy_expert(copy_sql, buf)
        total += len(rows)
        print(f"  {tbl}: {total:,}...", flush=True)

    pgconn.commit()
    cur.close()
    pg.close()
    print(f"{RAW}.{tbl}: {total:,} rows", flush=True)
    return total


def main():
    myconn = pymysql.connect(**MY)
    pgconn = psycopg2.connect(**PG)
    try:
        for tbl, q in QUERIES.items():
            copy_table(myconn, pgconn, tbl, q)
    finally:
        myconn.close()
        pgconn.close()


if __name__ == "__main__":
    main()
