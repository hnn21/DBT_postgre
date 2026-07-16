# Incremental `load_raw.py` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cho `el/load_raw.py` 3 chế độ nạp `performance_list`: full / khoảng `--from --to` / `--days N` (lùi N ngày từ hôm nay), mirror cơ chế xóa+ghi-lại theo `date_file_excel` của nguồn.

**Architecture:** Tách logic chọn chế độ thành hàm thuần `resolve_mode(from_, to_, days, today)` (unit-test không cần DB). `main()` áp dụng: 3 bảng nhỏ luôn full; `performance_list` theo chế độ (full = drop+create+copy; range = delete khoảng + copy khoảng vào bảng đã có).

**Tech Stack:** Python 3.11 (venv), pymysql (SSCursor), psycopg2 (copy_expert), argparse, pytest (unit test).

## Global Constraints

- File duy nhất thay đổi: `dwh_project/el/load_raw.py` (+ test + docs). KHÔNG đổi dbt models.
- Cột phân vùng khoảng ngày: `date_file_excel`. So sánh `date_file_excel::date` ở Postgres (raw lưu text ISO 'YYYY-MM-DD'); MySQL dùng cột `date` gốc.
- `--from` và `--to` bắt buộc đi cùng cặp; KHÔNG cho `--days` chung với `--from/--to`; `--days` > 0.
- `--days N` → khoảng `[today - N, today]` với `today = datetime.date.today()`.
- Không tham số → full reload.
- 3 bảng nhỏ (`send_sample`, `product_name_map`, `pic_team`) LUÔN full reload mọi chế độ.
- Chế độ range/days: nếu `raw.performance_list` chưa tồn tại → thoát với thông báo yêu cầu chạy full trước.
- Nạp raw: mọi cột kiểu text; COPY `FORMAT csv, NULL ''`; lô 50k (BATCH).
- Idempotent: delete-rồi-insert cùng khoảng.

---

## Task 1: 3-mode load_raw.py + unit tests + docs

**Files:**
- Modify: `dwh_project/el/load_raw.py`
- Create: `dwh_project/el/test_load_raw.py`
- Modify: `dwh_project/el/README.md`
- Modify: `dwh_project/README.md`

**Interfaces:**
- Produces: `resolve_mode(from_: str|None, to_: str|None, days: int|None, today: datetime.date) -> tuple[str, datetime.date|None, datetime.date|None]` — trả `("full", None, None)` hoặc `("range", d_from, d_to)`; raise `ValueError` khi tham số mâu thuẫn.
- Produces: `parse_args(argv=None)` (argparse Namespace với `.from_`, `.to`, `.days`), `main(argv=None)`.
- Giữ nguyên: `MY`, `PG`, `PG_URL`, `RAW`, `QUERIES`, `_load_env_file` (check_conn.py / compare.py vẫn import được).

- [ ] **Step 1: Cài pytest vào venv**

Run (từ `D:\PTDL\DBT_postgre`):
```bash
./venv/Scripts/python.exe -m pip install pytest -q
```
Expected: cài xong không lỗi.

- [ ] **Step 2: Viết test thất bại cho `resolve_mode`**

Tạo `dwh_project/el/test_load_raw.py`:
```python
import datetime
import pytest
from load_raw import resolve_mode

TODAY = datetime.date(2026, 7, 16)

def test_full_when_no_args():
    assert resolve_mode(None, None, None, TODAY) == ("full", None, None)

def test_days_window_from_today():
    assert resolve_mode(None, None, 7, TODAY) == (
        "range", datetime.date(2026, 7, 9), datetime.date(2026, 7, 16))

def test_explicit_range():
    assert resolve_mode("2026-07-01", "2026-07-14", None, TODAY) == (
        "range", datetime.date(2026, 7, 1), datetime.date(2026, 7, 14))

def test_days_with_range_rejected():
    with pytest.raises(ValueError):
        resolve_mode("2026-07-01", "2026-07-14", 7, TODAY)

def test_from_without_to_rejected():
    with pytest.raises(ValueError):
        resolve_mode("2026-07-01", None, None, TODAY)

def test_to_without_from_rejected():
    with pytest.raises(ValueError):
        resolve_mode(None, "2026-07-14", None, TODAY)

def test_from_after_to_rejected():
    with pytest.raises(ValueError):
        resolve_mode("2026-07-14", "2026-07-01", None, TODAY)

def test_days_non_positive_rejected():
    with pytest.raises(ValueError):
        resolve_mode(None, None, 0, TODAY)
```

- [ ] **Step 3: Chạy test — kỳ vọng FAIL**

Run (từ `dwh_project/el`):
```bash
cd /d/PTDL/DBT_postgre/dwh_project/el && PYTHONUTF8=1 ../../venv/Scripts/python.exe -m pytest test_load_raw.py -q
```
Expected: FAIL — `ImportError: cannot import name 'resolve_mode'` (hoặc collection error).

- [ ] **Step 4: Viết lại `load_raw.py` (bản 3 chế độ)**

Ghi đè toàn bộ `dwh_project/el/load_raw.py`:
```python
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
```

- [ ] **Step 5: Chạy test — kỳ vọng PASS**

Run:
```bash
cd /d/PTDL/DBT_postgre/dwh_project/el && PYTHONUTF8=1 ../../venv/Scripts/python.exe -m pytest test_load_raw.py -q
```
Expected: `8 passed`.

- [ ] **Step 6: Cập nhật `el/README.md`**

Thay mục "Chạy" bằng:
```markdown
## Chạy (PowerShell)
```powershell
cd D:\PTDL\DBT_postgre\dwh_project
..\venv\Scripts\python.exe el\load_raw.py                 # FULL: nạp lại toàn bộ performance_list
..\venv\Scripts\python.exe el\load_raw.py --days 30       # INCREMENTAL: date_file_excel >= hôm nay - 30
..\venv\Scripts\python.exe el\load_raw.py --from 2026-07-01 --to 2026-07-14   # khoảng cụ thể
```
- Chế độ `--days`/`--from/--to` chỉ nạp lại `performance_list` theo `date_file_excel` (DELETE khoảng + COPY lại), 3 bảng nhỏ luôn full.
- Cần chạy FULL ít nhất một lần trước khi dùng chế độ khoảng.
- Nên định kỳ (vd hằng tuần) chạy FULL để self-heal nếu nguồn có sửa dữ liệu cũ ngoài cửa sổ.
```

- [ ] **Step 7: Cập nhật `README.md` (mục "Chạy (MVA)")**

Đổi dòng load trong khối lệnh định kỳ thành:
```powershell
..\venv\Scripts\python.exe el\load_raw.py --days 30    # incremental theo date_file_excel (full: bỏ --days)
```

- [ ] **Step 8: Commit**

```bash
cd /d/PTDL/DBT_postgre && git add dwh_project/el/load_raw.py dwh_project/el/test_load_raw.py dwh_project/el/README.md dwh_project/README.md && git commit -m "feat(el): 3-mode load_raw (full/range/days) incremental by date_file_excel"
```

---

## Task 2: Kiểm thử tích hợp trên DB thật (thủ công)

**Files:** (không đổi file — chỉ chạy & quan sát)

**Interfaces:**
- Consumes: `resolve_mode`, `main` từ Task 1; DB MySQL + Postgres đã cấu hình trong `connections.env`.

- [ ] **Step 1: Đếm mốc trước khi test**

Run (PowerShell):
```powershell
cd D:\PTDL\DBT_postgre\dwh_project; . .\load_connections.ps1
..\venv\Scripts\python.exe -c "import psycopg2; from el.load_raw import PG, RAW; c=psycopg2.connect(**PG).cursor(); c.execute(f'select count(*) from \"{RAW}\".performance_list'); print('before:', c.fetchone()[0])"
```
Expected: in ra tổng dòng hiện có (vd 4,938,468).

- [ ] **Step 2: Chạy `--days 7` (lần 1) và kiểm idempotent (lần 2)**

Run:
```powershell
..\venv\Scripts\python.exe el\load_raw.py --days 7
..\venv\Scripts\python.exe -c "import psycopg2; from el.load_raw import PG, RAW; c=psycopg2.connect(**PG).cursor(); c.execute(f'select count(*) from \"{RAW}\".performance_list'); print('after run1:', c.fetchone()[0])"
..\venv\Scripts\python.exe el\load_raw.py --days 7
..\venv\Scripts\python.exe -c "import psycopg2; from el.load_raw import PG, RAW; c=psycopg2.connect(**PG).cursor(); c.execute(f'select count(*) from \"{RAW}\".performance_list'); print('after run2:', c.fetchone()[0])"
```
Expected: `after run1` ≈ `after run2` (chênh 0 hoặc bằng đúng thay đổi nguồn); không tăng dồn mỗi lần → idempotent OK.

- [ ] **Step 3: Đối chiếu khoảng 7 ngày với MySQL**

Run:
```powershell
..\venv\Scripts\python.exe -c "import pymysql, psycopg2, datetime; from el.load_raw import MY, PG, RAW; cut=(datetime.date.today()-datetime.timedelta(days=7)); m=pymysql.connect(**MY).cursor(); m.execute('select count(*) from performance_list where date_file_excel >= %s',(cut,)); pgc=psycopg2.connect(**PG).cursor(); pgc.execute(f'select count(*) from \"{RAW}\".performance_list where date_file_excel::date >= %s',(cut,)); print('mysql:', m.fetchone()[0], 'pg:', pgc.fetchone()[0])"
```
Expected: `mysql` == `pg` cho khoảng 7 ngày.

- [ ] **Step 4: Ghi nhận kết quả**

Nếu 3 bước trên đạt → incremental hoạt động đúng. Không cần commit (không đổi file). Nếu lệch → dùng superpowers:systematic-debugging.
