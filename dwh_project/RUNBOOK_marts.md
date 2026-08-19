# RUNBOOK — build 3 bảng marts (`mart_data`, `mart_data_agg`, `mart_new_video`)

Các lệnh chạy cho 2 trường hợp: **incremental** (thường ngày) và **full-refresh** (định kỳ).

- `mart_data`: materialized = **incremental** (delete+insert theo `video_id, date_file_excel`).
  Cửa sổ nạp lại mặc định **90 ngày** (`incr_days`). LƯU Ý: `duration_date`/`range_date` nay
  TĨNH (không còn "trôi" theo run_date) → cửa sổ có thể hạ **14** (kể cả 7) an toàn; window daily
  giờ chỉ để bắt thay đổi `send_sample` gần đây.
- `mart_data_agg`: materialized = **incremental** (delete+insert theo `thang`). 3 mode:
  full (`--full-refresh`), **truyền tháng** (`--vars '{agg_months:["YYYY-MM",...]}'`), và mặc định
  (không truyền) = **tháng hiện tại + tháng trước**. An toàn vì mart_data bất biến → tháng cũ không đổi.
- `mart_new_video`: materialized = **table** → 1 dòng / `video_id`, dựng lại toàn bộ từ `mart_data`.
  Tái tạo calculated table `table_new_video` của Power BI (đã dedupe, không cộng đôi số đơn/view).
  Còn là table (chưa incremental) vì `so_don`/`View`/`gmv` là tổng theo video trên toàn lịch sử.

## 0. Chuẩn bị (1 lần cho mỗi cửa sổ PowerShell)
```powershell
# từ D:\PTDL\DBT_postgre
.\venv\Scripts\Activate.ps1
cd dwh_project
. .\load_connections.ps1        # nạp connections.env -> DBT_PROFILES_DIR, SRC_*, DEST_*, PYTHONUTF8
```
> Nạp dữ liệu raw mới trước khi build (daily):
> ```powershell
> python el\load_raw.py --tables performance_list send_sample --days 14
> ```
> Cờ `load_raw.py`: `--tables` chọn bảng nạp (mặc định tất cả 4 bảng); `--days N`/`--from/--to`
> giới hạn performance_list; `--chunk-days N` nạp performance_list theo lô N ngày (an toàn cho
> full-refresh cả lịch sử, tránh stream dài bị MySQL đóng kết nối).

---

## 1. INCREMENTAL — chạy THƯỜNG NGÀY (chỉ nạp lại ~cửa sổ ngày gần nhất)

Build cả 3 bảng đúng thứ tự:
```powershell
dbt build -s mart_data+
```
> `mart_data+` = `mart_data` và **mọi model hạ nguồn** (`mart_data_agg`, `mart_new_video`) — dbt tự xếp thứ tự.

Đổi độ dài cửa sổ khi chạy (mặc định 90; daily NÊN dùng 14 vì drift đã hết):
```powershell
dbt build -s mart_data+ --vars '{incr_days: 14}'
```
> `duration_date`/`range_date` nay TĨNH → KHÔNG còn mốc sàn 60 ngày (cảnh báo cũ đã lỗi thời);
> 14 (hoặc 7) an toàn. Window daily chỉ còn để bắt `send_sample` gần đây; backdate xa → full-refresh định kỳ.
> Khi hạ `incr_days`, `mart_data_agg` mặc định vẫn phủ tháng hiện tại + tháng trước (≥ 14 ngày) nên khớp.

Nếu muốn tách từng lệnh (phải chạy `mart_data` TRƯỚC vì 2 bảng kia đọc từ nó):
```powershell
dbt build -s mart_data --vars '{incr_days: 14}'
dbt build -s mart_data_agg                                  # mặc định: tháng này + tháng trước
dbt build -s mart_new_video
```
Backfill `mart_data_agg` cho (các) tháng cụ thể mà không đụng tháng khác:
```powershell
dbt build -s mart_data_agg --vars '{agg_months: ["2026-06","2026-07"]}'
```

---

## 2. FULL-REFRESH — chạy ĐỊNH KỲ (vd hằng tuần, dựng lại TOÀN BỘ 5M dòng)

Bắt buộc để bắt các thay đổi hồi tố của `send_sample` cho dòng cũ (ngoài cửa sổ incremental):
```powershell
dbt build -s mart_data+ --full-refresh
```
> `--full-refresh` dựng lại `mart_data` (bỏ filter cửa sổ) VÀ `mart_data_agg` (toàn bộ tháng,
> bỏ qua mode incremental). `mart_new_video` là table nên luôn dựng lại. Dùng full-refresh để bắt
> thay đổi hồi tố `send_sample` cho dòng/tháng cũ ngoài cửa sổ daily.

---

## Ghi chú
- `dbt build` = chạy model + unit test `ut_mart_*`. Chỉ muốn dựng bảng (bỏ test) thì dùng `dbt run` thay `dbt build`.
- Chạy cả pipeline (staging → intermediate → marts): bỏ `-s ...`, chỉ `dbt build` (hoặc kèm `--full-refresh`).
- Nút thắt tốc độ còn lại là disk I/O + `shared_buffers` của server đích (bảng ~2GB), không sửa được bằng SQL — xem lịch sử tối ưu trong git.
