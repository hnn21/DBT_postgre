"""EL: load 4 bảng MySQL (tiktok_dashboard) -> schema `raw` trên PostgreSQL.

Mọi cột nạp dạng text (raw thật), việc làm sạch/ép kiểu thuộc về tầng staging của dbt.
Chạy TRƯỚC `dbt run`. Load kiểu replace-full (thay toàn bộ bảng).

Cách chạy (PowerShell, sau khi . .\env.mva.ps1):
    ..\venv\Scripts\python.exe el\load_raw.py
"""
import os
import pandas as pd
import pymysql  # noqa: F401  (đảm bảo driver có mặt)
from sqlalchemy import create_engine, text
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
# URL.create tự escape ký tự đặc biệt trong mật khẩu (@ ; ~ } ...)
PG_URL = URL.create(
    "postgresql+psycopg2",
    username=os.environ["DEST_USER"],
    password=os.environ["DEST_PASSWORD"],
    host=os.environ["DEST_HOST"],
    port=int(os.getenv("DEST_PORT", "5432")),
    database=os.environ["DEST_DB"],
)
RAW = os.getenv("PG_RAW_SCHEMA", "raw")

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


def main():
    myconn = pymysql.connect(**MY)
    pg = create_engine(PG_URL)
    with pg.begin() as c:
        c.execute(text(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"'))
    for tbl, q in QUERIES.items():
        df = pd.read_sql(q, myconn)
        # Ép mọi cột về text NHƯNG giữ NULL thật (không biến NaN/NaT thành chuỗi 'nan').
        # Thứ tự quan trọng: mask NA -> None TRƯỚC, rồi mới astype(object).
        df = df.astype(object).where(df.notna(), None)
        df.to_sql(tbl, pg, schema=RAW, if_exists="replace", index=False, chunksize=5000)
        print(f"{RAW}.{tbl}: {len(df)} rows")
    myconn.close()


if __name__ == "__main__":
    main()
