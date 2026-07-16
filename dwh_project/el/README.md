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

## Chạy (PowerShell)
```powershell
cd D:\PTDL\DBT_postgre\dwh_project
..\venv\Scripts\python.exe el\load_raw.py
```
Script tự đọc `connections.env` ở thư mục project. Kỳ vọng in ra 4 dòng
`raw.<tbl>: N rows` với N > 0.

## Thông tin cần có (trong connections.env)
`MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD, MYSQL_DB`,
`DEST_HOST, DEST_PORT, DEST_USER, DEST_PASSWORD, DEST_DB`.
(`PG_RAW_SCHEMA` mặc định `raw` nếu không đặt.)
