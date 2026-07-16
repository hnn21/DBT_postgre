"""EL: load 4 bảng MySQL (tiktok_dashboard) -> schema `raw` trên PostgreSQL.

3 chế độ cho `performance_list`:
  full  : python el/load_raw.py                          (drop + create + copy toàn bộ)
  range : python el/load_raw.py --from 2026-07-01 --to 2026-07-14
  days  : python el/load_raw.py --days 30                (date_file_excel >= today - 30)
3 bảng nhỏ (send_sample, product_name_map, pic_team) LUÔN full reload.

Kỹ thuật: đọc MySQL bằng SSCursor theo lô -> COPY vào Postgres. Nhẹ RAM.
Tự đọc connections.env.
"""
import argparse
import csv
import datetime
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
                v = v[1:-1]
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
PG_URL = URL.create(
    "postgresql+psycopg2",
    username=PG["user"], password=PG["password"],
    host=PG["host"], port=PG["port"], database=PG["dbname"],
)
RAW = os.getenv("PG_RAW_SCHEMA", "raw")
BATCH = 50000
SMALL_TABLES = ("send_sample", "product_name_map", "pic_team")

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


def resolve_mode(from_, to_, days, today):
    """Trả ('full', None, None) hoặc ('range', date_from, date_to). Raise ValueError khi mâu thuẫn."""
    if days is not None and (from_ or to_):
        raise ValueError("Không dùng --days cùng --from/--to")
    if (from_ is None) != (to_ is None):
        raise ValueError("--from và --to phải đi cùng nhau")
    if from_ is not None:
        d_from = datetime.date.fromisoformat(from_)
        d_to = datetime.date.fromisoformat(to_)
        if d_from > d_to:
            raise ValueError("--from phải <= --to")
        return ("range", d_from, d_to)
    if days is not None:
        if days <= 0:
            raise ValueError("--days phải > 0")
        return ("range", today - datetime.timedelta(days=days), today)
    return ("full", None, None)


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Load MySQL -> Postgres raw (full / range / days)")
    p.add_argument("--from", dest="from_", metavar="YYYY-MM-DD", help="đầu khoảng date_file_excel")
    p.add_argument("--to", dest="to", metavar="YYYY-MM-DD", help="cuối khoảng date_file_excel")
    p.add_argument("--days", type=int, metavar="N", help="date_file_excel >= today - N")
    return p.parse_args(argv)


def _copy_rows(cur, pg, tbl, cols):
    collist = ", ".join(f'"{c}"' for c in cols)
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
    print(f"{RAW}.{tbl}: {total:,} rows copied", flush=True)


def full_load(myconn, pgconn, tbl, query):
    pg = pgconn.cursor()
    cur = myconn.cursor(pymysql.cursors.SSCursor)
    cur.execute(query)
    cols = [d[0] for d in cur.description]
    pg.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"')
    pg.execute(f'DROP TABLE IF EXISTS "{RAW}"."{tbl}"')
    pg.execute(f'CREATE TABLE "{RAW}"."{tbl}" (' + ", ".join(f'"{c}" text' for c in cols) + ')')
    _copy_rows(cur, pg, tbl, cols)
    pgconn.commit()
    cur.close()
    pg.close()


def range_load(myconn, pgconn, tbl, d_from, d_to):
    pg = pgconn.cursor()
    pg.execute(
        "select 1 from information_schema.tables where table_schema=%s and table_name=%s",
        (RAW, tbl),
    )
    if pg.fetchone() is None:
        raise SystemExit(
            f"Bảng {RAW}.{tbl} chưa tồn tại — chạy full trước: python el/load_raw.py"
        )
    pg.execute(
        f'DELETE FROM "{RAW}"."{tbl}" WHERE date_file_excel::date BETWEEN %s AND %s',
        (d_from, d_to),
    )
    print(f"  {tbl}: deleted {pg.rowcount:,} rows in [{d_from}..{d_to}]", flush=True)
    cur = myconn.cursor(pymysql.cursors.SSCursor)
    q = QUERIES[tbl].rstrip() + "\n        WHERE date_file_excel BETWEEN %s AND %s"
    cur.execute(q, (d_from, d_to))
    cols = [d[0] for d in cur.description]
    _copy_rows(cur, pg, tbl, cols)
    pgconn.commit()
    cur.close()
    pg.close()


def main(argv=None):
    args = parse_args(argv)
    mode, d_from, d_to = resolve_mode(args.from_, args.to, args.days, datetime.date.today())
    print(f"Mode: {mode}" + ("" if mode == "full" else f" [{d_from}..{d_to}]"), flush=True)

    myconn = pymysql.connect(**MY)
    pgconn = psycopg2.connect(**PG)
    try:
        for tbl in SMALL_TABLES:  # luôn full
            full_load(myconn, pgconn, tbl, QUERIES[tbl])
        if mode == "full":
            full_load(myconn, pgconn, "performance_list", QUERIES["performance_list"])
        else:
            range_load(myconn, pgconn, "performance_list", d_from, d_to)
    finally:
        myconn.close()
        pgconn.close()


if __name__ == "__main__":
    main()
