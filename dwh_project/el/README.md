# EL — load raw MySQL → PostgreSQL

`load_raw.py` đổ 4 bảng từ MySQL `tiktok_dashboard` vào schema `raw` trên Postgres đích.

## Nguyên tắc
- Nạp **raw thật**: mọi cột dạng `text`, chỉ đổi tên cột sang snake_case. Không biến đổi nghiệp vụ (đó là việc của tầng `staging` trong dbt).
- **Replace-full**: mỗi lần chạy thay toàn bộ bảng (`if_exists="replace"`).
- Chạy **trước** `dbt run`.

## 4 bảng nạp
| raw.<table> | Nguồn MySQL |
|---|---|
| `raw.performance_list` | `performance_list` |
| `raw.send_sample` | `MVA_KOC_KOL_send_sample` |
| `raw.product_name_map` | `get_product_name_from_video_tiktok` |
| `raw.pic_team` | `PIC_Team` |

## Chạy (PowerShell) — 3 chế độ cho `performance_list`
```powershell
cd D:\PTDL\DBT_postgre\dwh_project
..\venv\Scripts\python.exe el\load_raw.py                              # FULL: nạp lại toàn bộ
..\venv\Scripts\python.exe el\load_raw.py --days 30                    # date_file_excel >= hôm nay - 30
..\venv\Scripts\python.exe el\load_raw.py --from 2026-07-01 --to 2026-07-14   # khoảng cụ thể
```
- Script tự đọc `connections.env` ở thư mục project.
- Chế độ `--days` / `--from --to` chỉ nạp lại `performance_list` theo `date_file_excel`
  (DELETE khoảng + COPY lại đúng khoảng — idempotent); **3 bảng nhỏ luôn full**.
- Phải chạy **FULL** ít nhất một lần trước khi dùng chế độ khoảng (nếu chưa có bảng sẽ báo lỗi).
- Nên **định kỳ (vd hằng tuần) chạy FULL** để self-heal nếu nguồn sửa dữ liệu cũ ngoài cửa sổ.

## Thông tin cần có (trong connections.env)
`MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB`,
`DEST_HOST, DEST_PORT, DEST_USER, DEST_PASSWORD, DEST_DB`.
(`PG_RAW_SCHEMA` mặc định `raw` nếu không đặt.)
