"""Kiểm tra kết nối MySQL + PostgreSQL, tạo schema raw, đếm số dòng nguồn.
Không chuyển dữ liệu. Chạy: ..\..\venv\Scripts\python.exe el\check_conn.py"""
import os
import pymysql
from sqlalchemy import create_engine, text

# tái dùng cấu hình đã nạp từ connections.env trong load_raw
from load_raw import MY, PG_URL, RAW, QUERIES  # noqa: E402

print("== MySQL ==")
try:
    conn = pymysql.connect(**MY, connect_timeout=10)
    with conn.cursor() as cur:
        for tbl, q in QUERIES.items():
            cur.execute(f"select count(*) from ({q}) t")
            print(f"  {tbl}: {cur.fetchone()[0]:,} rows")
    conn.close()
    print("  MySQL OK")
except Exception as e:
    print(f"  MySQL FAIL: {type(e).__name__}: {e}")

print("== PostgreSQL ==")
try:
    pg = create_engine(PG_URL, connect_args={"connect_timeout": 10})
    with pg.begin() as c:
        print("  version:", c.execute(text("select version()")).scalar()[:40])
        c.execute(text(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"'))
        print(f"  schema '{RAW}' ready")
    print("  PostgreSQL OK")
except Exception as e:
    print(f"  PostgreSQL FAIL: {type(e).__name__}: {e}")
