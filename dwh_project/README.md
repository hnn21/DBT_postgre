# dwh_project — khung dbt linh hoạt (PostgreSQL → PostgreSQL)

Nguồn raw và đích đều cấu hình qua **biến môi trường + vars**, đổi tùy ý mà không sửa model.

## Kiến trúc
```
SERVER NGUỒN (raw)  --postgres_fdw-->  SERVER ĐÍCH
                                        ├─ raw_ext   (bảng ảo trỏ về nguồn)
                                        ├─ staging   (dbt tạo, view)
                                        └─ marts     (dbt tạo, table = KẾT QUẢ)
dbt CHỈ kết nối vào SERVER ĐÍCH.
```

## Cài đặt (một lần)
```powershell
# từ D:\PTDL\DBT_postgre
.\venv\Scripts\Activate.ps1          # kích hoạt môi trường Python đã cài dbt
cd dwh_project
```
> Lưu ý Windows: script `env.*.ps1` đã set `PYTHONUTF8=1` để dbt đọc được comment
> tiếng Việt. Nếu chạy dbt mà KHÔNG qua script env, hãy tự set: `$env:PYTHONUTF8="1"`.

## Cấu hình kết nối (cách dùng cho MVA — khuyến nghị)
Mọi thông tin server nằm trong MỘT file `connections.env` (KHÔNG commit):
1. `copy connections.env.example connections.env`
2. Mở `connections.env`, điền `MYSQL_*` (nguồn) và `DEST_*` (Postgres đích).
3. Nạp vào phiên bằng: `. .\load_connections.ps1`

`connections.env` được cả dbt (qua `load_connections.ps1`) và script EL (`el/load_raw.py`) đọc.

## Chạy (MVA)
```powershell
. .\load_connections.ps1               # đọc connections.env -> đặt env (DBT_PROFILES_DIR, PYTHONUTF8...)
..\venv\Scripts\python.exe el\load_raw.py --days 30   # incremental theo date_file_excel (bỏ --days = full)
dbt seed                               # nạp seed videos_id_agency
dbt build                              # build models + chạy unit tests
dbt docs generate; dbt docs serve      # xem lineage
```
> Cách cũ dùng `env.*.ps1` (đặt secret thẳng trong script) vẫn hoạt động cho các
> dự án FDW khác, nhưng với MVA hãy dùng `connections.env` cho gọn và an toàn.

## Đổi nguồn / đích linh hoạt
```powershell
dbt run --target prod                     # đổi ĐÍCH sang server prod
dbt run --vars '{raw_schema: raw_ext_c}'  # đổi NGUỒN sang bảng ảo khác
dbt run --vars '{raw_database: other_db, raw_schema: public}'  # đổi hẳn DB nguồn
. .\env.CtoD.ps1 ; dbt run                # một tổ hợp nguồn->đích hoàn toàn khác
```

## Cấu trúc
```
dbt_project.yml          # cấu hình project + vars nguồn (SRC_*)
profiles.yml             # các đích dev/prod (DEST_*/PROD_*)
env.example.ps1          # mẫu tổ hợp nguồn->đích (copy & điền)
setup_fdw.example.sql    # SQL nối 2 server (chạy trên đích)
models/
  staging/  _sources.yml, stg_*.sql   # làm sạch, view
  marts/    fct_*.sql                 # kết quả cuối, table
```
