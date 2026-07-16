# Thiết kế: `load_raw.py` incremental theo khoảng ngày (date_file_excel)

**Ngày:** 2026-07-16
**Mục tiêu:** Giảm khối lượng tải MySQL→Postgres bằng cách nạp lại raw theo khoảng `date_file_excel` thay vì full 4,94M dòng mỗi lần, mirror đúng cơ chế "xóa + ghi lại theo khoảng ngày" của nguồn.

## 1. Bối cảnh
- `raw.performance_list` hiện full reload (drop + nạp 4,94M) mỗi lần chạy → nặng.
- Nguồn MySQL cập nhật dữ liệu bằng cách **xóa bản ghi trong một khoảng `date_file_excel` rồi insert bản ghi mới cho khoảng đó**; việc này chỉ động tới các ngày gần đây (≤ 7-14 ngày).
- Đo thực tế: 700 ngày snapshot; 30 ngày gần nhất ≈ 285k dòng (5,8% tổng).
- Nguồn không có cột `updated_at`; watermark append theo `id` KHÔNG dùng được (nguồn xóa+ghi lại). Cột phân vùng đúng là `date_file_excel`.

## 2. Phạm vi
- **Chỉ sửa `dwh_project/el/load_raw.py`** + tài liệu (`el/README.md`, `README.md`).
- **KHÔNG đổi** dbt models. Mart vẫn full-rebuild (~11 phút) vì các cột `duration_date`/`video_duoctinhPFM`/2 cột ĐK/`Phân loại Creator` phụ thuộc `current_date` → mọi dòng phải tính lại mỗi ngày (tối ưu mart là bài toán riêng, ngoài phạm vi).

## 3. Ba chế độ chạy `load_raw.py`

| Lệnh | Hành vi trên `performance_list` |
|---|---|
| `python el/load_raw.py` (không tham số) | **full**: `DROP TABLE` + `CREATE` + COPY toàn bộ (như hiện tại). |
| `python el/load_raw.py --from YYYY-MM-DD --to YYYY-MM-DD` | **range**: `DELETE WHERE date_file_excel::date BETWEEN from AND to` rồi COPY từ MySQL `WHERE date_file_excel BETWEEN from AND to`. |
| `python el/load_raw.py --days N` | **days**: khoảng `[current_date − N, current_date]`, tức DELETE/INSERT `WHERE date_file_excel::date >= current_date − N`. `current_date` = ngày hệ thống lúc chạy. |

Ràng buộc tham số:
- `--from` và `--to` đi cùng nhau; `--to` mặc định = hôm nay nếu chỉ có `--from` (tùy chọn, hoặc bắt buộc cả hai — chọn: **bắt buộc cả hai** cho rõ ràng).
- Không kết hợp `--from/--to` với `--days` (báo lỗi nếu truyền cả hai).
- `--days N`: N là số nguyên dương.

## 4. Hành vi 3 bảng nhỏ
`send_sample`, `product_name_map`, `pic_team`: **LUÔN full reload** (drop + create + COPY) ở MỌI chế độ. Lý do: rất nhỏ (≤ 40k), và `send_sample` không có cột `date_file_excel`. Bảo đảm luôn tươi.

## 5. Chi tiết kỹ thuật
- **performance_list ở chế độ range/days:**
  1. Nếu bảng `raw.performance_list` CHƯA tồn tại → **báo lỗi rõ**: "Bảng chưa có, chạy full trước (`python el/load_raw.py`)". Không tự tạo rỗng rồi nạp một phần (tránh dữ liệu thiếu âm thầm).
  2. `DELETE FROM raw.performance_list WHERE date_file_excel::date >= %s` (days) hoặc `BETWEEN %s AND %s` (range).
  3. Đọc MySQL `... WHERE date_file_excel >= %s`/`BETWEEN` bằng SSCursor, COPY theo lô 50k vào bảng (INSERT thêm, không drop).
  4. `COMMIT`.
- **Idempotent**: delete-rồi-insert cùng khoảng ⇒ chạy lại nhiều lần cho kết quả như nhau.
- So sánh ngày: `date_file_excel::date` (raw lưu text ISO 'YYYY-MM-DD') để BETWEEN/`>=` chuẩn; MySQL dùng cột `date` gốc.
- Tham số dòng lệnh: dùng `argparse`. Không có tham số → full.
- Không đổi cách đọc `connections.env`, không đổi 3 bảng nhỏ.

## 6. Kiểm thử
- **Unit (không cần DB):** hàm tính khoảng ngày từ `--days N` (trả về cutoff = today − N) và validate tham số (from/to bắt buộc cặp; không cho days + from/to). Test bằng cách truyền ngày "hôm nay" cố định vào hàm (không gọi `date.today()` trực tiếp trong logic thuần).
- **Tích hợp (cần DB, chạy tay):**
  1. Full load → đếm `raw.performance_list` = tổng nguồn.
  2. `--days 7` → số dòng bảng không giảm bất thường; các `date_file_excel` trong 7 ngày khớp nguồn; ngày cũ giữ nguyên.
  3. Chạy `--days 7` lần 2 → tổng không đổi (idempotent).
  4. `--from/--to` một khoảng đã biết → đúng số dòng khoảng đó.

## 7. Rủi ro
- Nếu nguồn hiếm khi sửa dữ liệu cũ hơn khoảng đang nạp → sẽ bỏ sót. Giảm thiểu: chạy `--days` với N đủ rộng (≥ 30), và **định kỳ (vd hằng tuần) chạy full** để self-heal.
- `date_file_excel` NULL/rỗng trong nguồn: dòng đó không lọt bộ lọc khoảng → sẽ không được nạp ở chế độ incremental. Nếu tồn tại, cần full. (Kiểm tra khi test.)

## 8. Ngoài phạm vi
Tối ưu thời gian build mart (tách cột phụ thuộc thời gian ra view/incremental) — thiết kế riêng nếu cần sau này.
