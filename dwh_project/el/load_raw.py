"""EL: load 5 bảng nguồn -> schema `raw` trên PostgreSQL.

Hai nguồn:
  • MySQL (tiktok_dashboard): performance_list, send_sample, product_name_map, pic_team
  • Postgres `krm` (hệ thống KOC): users — bảng nhân sự, dùng để gắn PIC theo user_id.
    Phải hạ cánh về raw vì Postgres KHÔNG join cross-database được.

3 chế độ cho `performance_list`:
  full  : python el/load_raw.py                          (drop + create + copy toàn bộ)
  range : python el/load_raw.py --from 2026-07-01 --to 2026-07-14
  days  : python el/load_raw.py --days 30                (date_file_excel >= today - 30)
4 bảng nhỏ (send_sample, product_name_map, pic_team, users) LUÔN full reload.

Kỹ thuật: đọc theo lô -> COPY vào Postgres. Nhẹ RAM (MySQL dùng SSCursor).
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
# Nguồn thứ 2: Postgres `krm` (hệ thống KOC). KHÁC server với đích -> Postgres không
# join cross-database được, nên phải hạ cánh về raw trước.
# CẢNH BÁO: đặt tên biến phải là KRM_*, KHÔNG được trùng DEST_*. Nếu trùng, tuỳ cách
# nạp env mà DEST_* bị ghi đè -> dbt dựng marts thẳng vào DB sản xuất `krm`.
KRM = dict(
    host=os.environ["KRM_HOST"],
    port=int(os.getenv("KRM_PORT", "5432")),
    user=os.environ["KRM_USER"],
    password=os.environ["KRM_PASSWORD"],
    dbname=os.environ["KRM_DB"],
)
RAW = os.getenv("PG_RAW_SCHEMA", "raw")
BATCH = 50000
SMALL_TABLES = ("send_sample", "product_name_map", "pic_team")
PG_TABLES = ("users",)          # nguồn Postgres krm — luôn full (bảng nhỏ)
ALL_TABLES = SMALL_TABLES + ("performance_list",) + PG_TABLES

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
               `cost`, `SDT` AS sdt, `campaign_id`, `user_id`, `koc_booking_content_id`, `agency_id`
        FROM MVA_KOC_KOL_send_sample""",
    "product_name_map": """
        SELECT video_id, product_contain, product_contain_combo
        FROM get_product_name_from_video_tiktok""",
    "pic_team": """
        SELECT Raw_name AS raw_name, Change_name AS doi_ten, Team AS team
        FROM PIC_Team""",
}

# Truy vấn cho nguồn Postgres `krm`. CHỈ lấy cột cần cho pipeline —
# KHÔNG kéo password / email / reset_password_token về kho dữ liệu.
QUERIES_PG = {
    "users": """
        SELECT id, username, team::text AS team, status
        FROM public.users""",
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
    p.add_argument(
        "--tables", nargs="+", choices=ALL_TABLES, metavar="TABLE",
        help="Chỉ nạp các bảng chỉ định (mặc định: tất cả). VD: --tables send_sample",
    )
    p.add_argument(
        "--chunk-days", type=int, metavar="N", dest="chunk_days",
        help="Nạp performance_list theo lô N ngày (an toàn cho full-refresh, "
             "tránh stream quá dài bị đứt kết nối). VD: --chunk-days 30",
    )
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
    # SSCursor phải được đóng TRƯỚC khi connection đóng, kể cả khi lỗi giữa chừng —
    # nếu không, lúc GC pymysql sẽ cố đọc nốt query unbuffered trên socket đã đóng
    # và ném "Exception ignored ... settimeout on None". try/finally đảm bảo điều đó.
    cur = myconn.cursor(pymysql.cursors.SSCursor)
    try:
        cur.execute(query)
        cols = [d[0] for d in cur.description]
        pg.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"')
        # CREATE IF NOT EXISTS + TRUNCATE (không DROP) để không phá các view dbt phụ thuộc.
        # TRUNCATE có tính giao dịch -> thay dữ liệu nguyên tử khi commit.
        pg.execute(f'CREATE TABLE IF NOT EXISTS "{RAW}"."{tbl}" (' + ", ".join(f'"{c}" text' for c in cols) + ')')
        # Bảng có thể đã tồn tại từ trước với ÍT cột hơn (nguồn MySQL vừa thêm cột mới).
        # CREATE IF NOT EXISTS KHÔNG thêm cột -> COPY sẽ lỗi
        # 'column "..." of relation "..." does not exist'. Nên đồng bộ trước:
        # thêm mọi cột còn thiếu. CHỈ THÊM — không xoá, không đổi kiểu.
        pg.execute(
            "select column_name from information_schema.columns "
            "where table_schema = %s and table_name = %s",
            (RAW, tbl),
        )
        have = {r[0] for r in pg.fetchall()}
        for c in cols:
            if c not in have:
                pg.execute(f'ALTER TABLE "{RAW}"."{tbl}" ADD COLUMN "{c}" text')
                print(f"  {tbl}: + thêm cột mới '{c}'", flush=True)
        pg.execute(f'TRUNCATE "{RAW}"."{tbl}"')
        _copy_rows(cur, pg, tbl, cols)
        pgconn.commit()
    finally:
        try:
            cur.close()  # nuốt lỗi close để không che lỗi gốc (vd stream đứt giữa chừng)
        except Exception:
            pass
        pg.close()


def full_load_pg(pgsrc, pgconn, tbl, query):
    """Full reload từ Postgres nguồn (`krm`) -> raw. Cùng khuôn với full_load().

    Dùng cho bảng nhỏ (users ~79 dòng) nên không cần server-side cursor.
    Giống full_load: CREATE IF NOT EXISTS + đồng bộ cột thiếu + TRUNCATE (không DROP,
    để không phá các view dbt phụ thuộc), tất cả trong 1 giao dịch.
    """
    pg = pgconn.cursor()
    src = pgsrc.cursor()
    try:
        src.execute(query)
        cols = [d[0] for d in src.description]
        pg.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"')
        pg.execute(f'CREATE TABLE IF NOT EXISTS "{RAW}"."{tbl}" (' + ", ".join(f'"{c}" text' for c in cols) + ')')
        pg.execute(
            "select column_name from information_schema.columns "
            "where table_schema = %s and table_name = %s",
            (RAW, tbl),
        )
        have = {r[0] for r in pg.fetchall()}
        for c in cols:
            if c not in have:
                pg.execute(f'ALTER TABLE "{RAW}"."{tbl}" ADD COLUMN "{c}" text')
                print(f"  {tbl}: + thêm cột mới '{c}'", flush=True)
        pg.execute(f'TRUNCATE "{RAW}"."{tbl}"')
        _copy_rows(src, pg, tbl, cols)
        pgconn.commit()
    finally:
        try:
            src.close()
        except Exception:
            pass
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
    # try/finally: đóng SSCursor trước connection, tránh noise lúc GC (xem full_load).
    cur = myconn.cursor(pymysql.cursors.SSCursor)
    try:
        q = QUERIES[tbl].rstrip() + "\n        WHERE date_file_excel BETWEEN %s AND %s"
        cur.execute(q, (d_from, d_to))
        cols = [d[0] for d in cur.description]
        _copy_rows(cur, pg, tbl, cols)
        pgconn.commit()
    finally:
        try:
            cur.close()  # nuốt lỗi close để không che lỗi gốc (vd stream đứt giữa chừng)
        except Exception:
            pass
    pg.close()


def _iter_chunks(d_from, d_to, chunk_days):
    """Chia [d_from..d_to] thành các lô liên tiếp, mỗi lô tối đa chunk_days ngày."""
    cur = d_from
    while cur <= d_to:
        end = min(cur + datetime.timedelta(days=chunk_days - 1), d_to)
        yield cur, end
        cur = end + datetime.timedelta(days=1)


def _mysql_date_span(myconn, tbl):
    """min/max date_file_excel trong MySQL (dùng khi full-refresh cần biết toàn dải)."""
    c = myconn.cursor()
    try:
        c.execute(f"select min(date_file_excel), max(date_file_excel) from {tbl}")
        return c.fetchone()  # (date, date) hoặc (None, None) nếu rỗng
    finally:
        c.close()


def _ensure_table(myconn, pgconn, tbl, query):
    """Tạo bảng raw rỗng nếu chưa có, để range_load (DELETE+insert) chạy được lô đầu."""
    pg = pgconn.cursor()
    try:
        pg.execute(
            "select 1 from information_schema.tables where table_schema=%s and table_name=%s",
            (RAW, tbl),
        )
        if pg.fetchone() is not None:
            return
        my = myconn.cursor()
        try:
            my.execute(query.rstrip() + "\n        LIMIT 0")  # chỉ lấy tên cột
            cols = [d[0] for d in my.description]
        finally:
            my.close()
        pg.execute(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"')
        pg.execute(f'CREATE TABLE IF NOT EXISTS "{RAW}"."{tbl}" (' + ", ".join(f'"{c}" text' for c in cols) + ')')
        pgconn.commit()
    finally:
        pg.close()


def chunked_load(myconn, pgconn, tbl, mode, d_from, d_to, chunk_days):
    """Full-refresh AN TOÀN: nạp theo lô nhỏ, mỗi lô là 1 range_load (transactional, resumable)."""
    _ensure_table(myconn, pgconn, tbl, QUERIES[tbl])
    if mode == "full":  # full = toàn dải trong MySQL
        d_from, d_to = _mysql_date_span(myconn, tbl)
        if d_from is None:
            print(f"  {tbl}: nguồn MySQL rỗng, bỏ qua", flush=True)
            return
    chunks = list(_iter_chunks(d_from, d_to, chunk_days))
    print(f"  {tbl}: full-safe {len(chunks)} lô x {chunk_days} ngày [{d_from}..{d_to}]", flush=True)
    for i, (cf, ct) in enumerate(chunks, 1):
        print(f"  [lô {i}/{len(chunks)}] {cf}..{ct}", flush=True)
        range_load(myconn, pgconn, tbl, cf, ct)


def main(argv=None):
    args = parse_args(argv)
    if args.chunk_days is not None and args.chunk_days <= 0:
        raise SystemExit("--chunk-days phải > 0")
    mode, d_from, d_to = resolve_mode(args.from_, args.to, args.days, datetime.date.today())
    targets = args.tables if args.tables else list(ALL_TABLES)  # không chọn -> tất cả
    print(f"Mode: {mode}" + ("" if mode == "full" else f" [{d_from}..{d_to}]")
          + f" | tables: {', '.join(targets)}", flush=True)

    myconn = pymysql.connect(**MY)
    pgconn = psycopg2.connect(**PG)
    try:
        for tbl in SMALL_TABLES:  # bảng nhỏ luôn full
            if tbl in targets:
                full_load(myconn, pgconn, tbl, QUERIES[tbl])
        if "performance_list" in targets:
            if args.chunk_days:
                chunked_load(myconn, pgconn, "performance_list", mode, d_from, d_to, args.chunk_days)
            elif mode == "full":
                full_load(myconn, pgconn, "performance_list", QUERIES["performance_list"])
            else:
                range_load(myconn, pgconn, "performance_list", d_from, d_to)
        # Nguồn Postgres krm — chỉ mở kết nối khi thực sự cần.
        pg_targets = [t for t in PG_TABLES if t in targets]
        if pg_targets:
            pgsrc = psycopg2.connect(**KRM)
            try:
                for tbl in pg_targets:
                    full_load_pg(pgsrc, pgconn, tbl, QUERIES_PG[tbl])
            finally:
                pgsrc.close()
    finally:
        myconn.close()
        pgconn.close()


if __name__ == "__main__":
    main()
