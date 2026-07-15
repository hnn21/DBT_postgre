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

## Cấu hình nguồn/đích
1. Copy `env.example.ps1` -> `env.AtoB.ps1`, điền IP/DB/user/mật khẩu.
2. (Chỉ nếu dùng FDW) Chạy `setup_fdw.example.sql` trên server đích để tạo bảng ảo.

## Chạy
```powershell
. .\env.AtoB.ps1        # nạp tổ hợp nguồn->đích (cũng set DBT_PROFILES_DIR)
dbt debug               # kiểm tra kết nối đích
dbt run                 # build models -> ghi kết quả lên đích 'dev'
dbt test                # chạy test
dbt docs generate; dbt docs serve   # xem lineage
```

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
