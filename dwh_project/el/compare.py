"""So khớp phân phối mart_data (Postgres) — in ra để đối chiếu với Power BI."""
import psycopg2
from load_raw import PG  # đọc connections.env

SCHEMA = "marts"  # target schema 'staging' + custom schema 'marts' -> staging_marts? kiểm tra
QUERIES = {
    "total": 'select count(*) from {t}',
    "Loai video": 'select "Loại video", count(*) from {t} group by 1 order by 2 desc',
    "Phan loai Creator": 'select "Phân loại Creator", count(*) from {t} group by 1 order by 2 desc',
    "duration_date": 'select duration_date, count(*) from {t} group by 1 order by 1',
    "non-null Ngay gui mau": 'select count("Ngày gửi mẫu") from {t}',
    "non-null PIC": 'select count("PIC") from {t}',
}

pg = psycopg2.connect(**PG)
cur = pg.cursor()
# tìm schema thật của mart_data
cur.execute("select table_schema from information_schema.tables where table_name='mart_data'")
schemas = [r[0] for r in cur.fetchall()]
print("mart_data schema(s):", schemas)
tbl = f'"{schemas[0]}".mart_data'

for name, q in QUERIES.items():
    cur.execute(q.format(t=tbl))
    rows = cur.fetchall()
    print(f"\n== {name} ==")
    for r in rows:
        print("  ", r)
pg.close()
