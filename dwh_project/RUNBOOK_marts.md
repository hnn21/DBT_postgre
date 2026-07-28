# RUNBOOK — build 3 bảng marts (`mart_data`, `mart_data_agg`, `mart_new_video`)

Các lệnh chạy cho 2 trường hợp: **incremental** (thường ngày) và **full-refresh** (định kỳ).

- `mart_data`: materialized = **incremental** (delete+insert theo `video_id, date_file_excel`).
  Cửa sổ nạp lại mặc định **90 ngày** gần nhất (`date_file_excel >= current_date - N`).
- `mart_data_agg`: materialized = **table** → LUÔN dựng lại toàn bộ từ `mart_data` hiện có.
  Cờ `--full-refresh` KHÔNG đổi hành vi của nó; nó "mới" hay "full" tùy `mart_data`.
- `mart_new_video`: materialized = **table** → 1 dòng / `video_id`, dựng lại toàn bộ từ `mart_data`.
  Tái tạo calculated table `table_new_video` của Power BI (đã dedupe, không cộng đôi số đơn/view).
  Không dùng incremental vì `so_don`/`View` là tổng theo video trên toàn lịch sử.

## 0. Chuẩn bị (1 lần cho mỗi cửa sổ PowerShell)
```powershell
# từ D:\PTDL\DBT_postgre
.\venv\Scripts\Activate.ps1
cd dwh_project
. .\load_connections.ps1        # nạp connections.env -> DBT_PROFILES_DIR, SRC_*, DEST_*, PYTHONUTF8
```
> (Tùy chọn) nạp dữ liệu raw mới trước khi build:
> ```powershell
> python el\load_raw.py --days 90     # incremental theo date_file_excel; bỏ --days = full
> ```

---

## 1. INCREMENTAL — chạy THƯỜNG NGÀY (chỉ nạp lại ~cửa sổ ngày gần nhất)

Build cả 3 bảng đúng thứ tự:
```powershell
dbt build -s mart_data+
```
> `mart_data+` = `mart_data` và **mọi model hạ nguồn** (`mart_data_agg`, `mart_new_video`) — dbt tự xếp thứ tự.

Đổi độ dài cửa sổ khi chạy (mặc định 90; ví dụ 120 ngày):
```powershell
dbt build -s mart_data+ --vars '{incr_days: 120}'
```
> ⚠️ Không đặt `incr_days` < 60 — sẽ bỏ sót các dòng `duration_date` còn "trôi" ở mốc `<= 60` ngày.

Nếu muốn tách từng lệnh (phải chạy `mart_data` TRƯỚC vì 2 bảng kia đọc từ nó):
```powershell
dbt build -s mart_data
dbt build -s mart_data_agg
dbt build -s mart_new_video
```

---

## 2. FULL-REFRESH — chạy ĐỊNH KỲ (vd hằng tuần, dựng lại TOÀN BỘ 5M dòng)

Bắt buộc để bắt các thay đổi hồi tố của `send_sample` cho dòng cũ (ngoài cửa sổ incremental):
```powershell
dbt build -s mart_data+ --full-refresh
```
> `--full-refresh` chỉ tác động lên `mart_data` (bỏ qua filter cửa sổ, dựng lại từ đầu).
> `mart_data_agg` và `mart_new_video` luôn dựng lại nên không cần cờ; thêm cờ cũng vô hại.

---

## Ghi chú
- `dbt build` = chạy model + unit test `ut_mart_*`. Chỉ muốn dựng bảng (bỏ test) thì dùng `dbt run` thay `dbt build`.
- Chạy cả pipeline (staging → intermediate → marts): bỏ `-s ...`, chỉ `dbt build` (hoặc kèm `--full-refresh`).
- Nút thắt tốc độ còn lại là disk I/O + `shared_buffers` của server đích (bảng ~2GB), không sửa được bằng SQL — xem lịch sử tối ưu trong git.
