# Thiết kế: `mart_new_video` — tái tạo calculated table `table_new_video` của Power BI

**Ngày:** 2026-07-28
**Mục tiêu:** Đưa calculated table `table_new_video` (đang tính bằng DAX trong `MVA_VideoAFF_(new_agg).pbix`) xuống Postgres thành một model dbt, để Power BI đọc trực tiếp thay vì tính lại trong bộ nhớ — đồng thời sửa lỗi cộng đôi số đơn/số view.

## 1. Bối cảnh

Đọc trực tiếp từ file .pbix đang mở qua powerbi-mcp (`localhost:65210`):

- `table_new_video` là **calculated table (DAX)**, 12 cột, 6 measure, nguồn là bảng `postgre_data_detail`.
- `postgre_data_detail` là M query `Value.NativeQuery(... "SELECT ... FROM marts.mart_data")` → **chính là `marts.mart_data`** của repo này.
- Biểu thức calculated table:
  ```dax
  CALCULATETABLE(
      SUMMARIZE(
          postgre_data_detail,
          postgre_data_detail[time], postgre_data_detail[creator_name], postgre_data_detail[video_id],
          postgre_data_detail[Mẫu gửi], postgre_data_detail[brand], postgre_data_detail[PIC],
          postgre_data_detail[Team], postgre_data_detail[prod_contain],
          postgre_data_detail[prod_contain_combo], postgre_data_detail[Vị trí]
      ),
      postgre_data_detail[duration_date] > 0
  )
  ```
- 2 calculated column:
  ```dax
  so_don = var _vid = [video_id] RETURN
           CALCULATE(SUM(postgre_data_detail[count_order]), postgre_data_detail[video_id] = _vid, all())
  View   = var _vid = [video_id] RETURN
           CALCULATE(SUM(postgre_data_detail[vv]),          postgre_data_detail[video_id] = _vid, all())
  ```
  `all()` bỏ **mọi** filter context ⇒ tổng trên toàn bộ snapshot của video, **kể cả dòng `duration_date <= 0`**.

Số liệu đo được (PBI): `table_new_video` = **60.951 dòng / 60.668 distinct `video_id`**; `mart_data` 5,05M dòng, trong đó `duration_date > 0` = 1,64M dòng.

### 1.1 Hai phát hiện quan trọng

**(a) `vv` / `count_order` KHÔNG lũy kế.** Kiểm chứng trên dữ liệu thật (1 video qua 23 snapshot): `vv` dao động lên/xuống (8.623 → 11.519 → 8.408 → 5.026 → 213.813 → … → 464), không đơn điệu tăng. Vậy đây là **giá trị phát sinh theo ngày**, nên `SUM` qua các snapshot = **tổng view/đơn của video** ⇒ ngữ nghĩa `all()` của DAX là đúng nghiệp vụ.

**(b) Power BI đang cộng đôi.** Grain của `SUMMARIZE` gồm 10 cột nên **283 `video_id` có 2+ dòng** (60.951 − 60.668) do thuộc tính đổi giữa các snapshot: `time` 211 video, `creator_name` 38, `Mẫu gửi` 33, `PIC` 17, `prod_contain`/`prod_contain_combo` 14, `Team` 11, `brand` 5, `Vị trí` 1. Vì `so_don`/`View` tính theo `video_id` với `all()`, **mọi dòng của cùng một video nhận cùng giá trị tổng** ⇒ measure `Số đơn = SUM(so_don)` và `Số view = SUM(View)` **đếm 2 lần** cho 283 video đó.

## 2. Phạm vi

- **Thêm mới:** `dwh_project/models/marts/mart_new_video.sql` + khai báo/test trong YAML tầng marts.
- **KHÔNG đổi** `mart_data`, `mart_data_agg`, staging/intermediate, hay `el/load_raw.py`.
- **KHÔNG** đưa measure xuống SQL (`Số đơn`, `DK_sodon`, `Số creator thỏa mãn`, `DK_so_video`, `so_video_new_table`) — chúng phụ thuộc slicer/parameter (`Parameter`, `Parameter_so_video`) nên phải ở lại Power BI.
- **KHÔNG** tạo model cho `list_video_new` (chỉ là `VALUES(table_new_video[video_id])`) — Power BI lấy distinct từ bảng mới.

## 3. Quyết định thiết kế: dedupe về 1 dòng / video

Khác Power BI một cách **có chủ ý**: grain là **1 dòng / `video_id`** (~60.668 dòng), thay vì 60.951.

Quy tắc chọn dòng đại diện:
1. Chỉ xét các dòng `duration_date > 0` của video đó.
2. Lấy dòng có **`time` nhỏ nhất**.
3. Nếu vẫn còn nhiều dòng (**72 video** cùng `min(time)` nhưng khác thuộc tính khác) → dùng `max(cột)` cho từng cột để kết quả **deterministic**. Đây là idiom đã dùng trong `mart_data` (`pic_pick`, `vm_pick`: chọn theo ngày nhỏ nhất rồi `max` giá trị).

Hệ quả: `so_don`/`View` **không còn cộng đôi**.

## 4. Cấu trúc bảng đích (12 cột)

Giữ nguyên tên cột như Power BI (kể cả dấu tiếng Việt, chữ hoa) để map trực tiếp — cùng cách `mart_data` đang làm.

| Cột | Nguồn / cách tính |
|---|---|
| `video_id` | khóa, 1 dòng/video |
| `time` | `min(time)` trong các dòng `duration_date > 0` |
| `creator_name` | `max(...)` tại dòng `time = min_time` |
| `"Mẫu gửi"` | `max(...)` tại dòng `time = min_time` |
| `brand` | `max(...)` tại dòng `time = min_time` |
| `"PIC"` | `max(...)` tại dòng `time = min_time` |
| `"Team"` | `max(...)` tại dòng `time = min_time` |
| `prod_contain` | `max(...)` tại dòng `time = min_time` |
| `prod_contain_combo` | `max(...)` tại dòng `time = min_time` |
| `"Vị trí"` | `max(...)` tại dòng `time = min_time` |
| `so_don` | `sum(count_order)` trên **toàn bộ** dòng của video (kể cả `duration_date <= 0`) |
| `"View"` | `sum(vv)` trên **toàn bộ** dòng của video (kể cả `duration_date <= 0`) |

Chỉ giữ video có **ít nhất 1 dòng `duration_date > 0`** (tương đương `CALCULATETABLE(..., duration_date > 0)`).

## 5. Chi tiết kỹ thuật — một lần quét

`mart_data` ~2GB và server đích **nghẽn disk I/O** (xem lịch sử tối ưu marts), nên chi phí gần như toàn bộ là quét `mart_data`; bảng đích chỉ 60k dòng. Vì vậy dùng **1 lần quét** thay vì 2 (dims + totals rồi join).

```
mart_data (5M dòng)
  └─ window: min(time) filter (where duration_date > 0) over (partition by video_id)  → _min_time
       └─ group by video_id
            ├─ 9 cột dims ← max(cột) filter (where duration_date > 0 and time = _min_time)
            ├─ time       ← min(time) filter (where duration_date > 0)
            ├─ so_don     ← sum(count_order)      [KHÔNG lọc duration_date]
            └─ "View"     ← sum(vv)               [KHÔNG lọc duration_date]
       └─ having: count(*) filter (where duration_date > 0) > 0
```

Cấu hình:
- `materialized='table'` — bảng nhỏ (60k dòng), dựng lại nhanh.
- `pre_hook=["set work_mem = '256MB'", "set jit = off"]` — giống `mart_data`/`mart_data_agg`.
- **KHÔNG dùng incremental** (có chủ ý): `so_don`/`View` là tổng theo `video_id` trên **toàn lịch sử**; một snapshot mới của video làm đổi tổng của video đó, nên incremental theo cửa sổ ngày sẽ cho số sai.

## 6. Kiểm thử

**Unit tests** (`_mart_new_video.yml`, theo mẫu `ut_mart_*` sẵn có):
1. `ut_new_video_dedupe_min_time` — video có 2 dòng `duration_date > 0` với `time` khác nhau ⇒ ra **1 dòng**, lấy `time` nhỏ nhất và các dims của dòng đó.
2. `ut_new_video_tiebreak` — 2 dòng cùng `min(time)` khác `PIC` ⇒ ra 1 dòng, `PIC` = `max()` (deterministic).
3. `ut_new_video_totals_include_all` — video có dòng `duration_date > 0` và dòng `duration_date = -1` ⇒ `so_don`/`View` **cộng cả** dòng `-1`.
4. `ut_new_video_exclude_no_valid_row` — video chỉ có dòng `duration_date <= 0` ⇒ **không xuất hiện**.

**Data tests:** `unique` + `not_null` trên `video_id` (chốt grain 1 dòng/video).

**Đối chiếu sau build:** số dòng = **60.668**; `count(distinct video_id)` = số dòng; `sum(so_don)`/`sum("View")` khớp tổng tính trực tiếp từ `mart_data` theo tập video tương ứng.

## 7. Rủi ro & lưu ý vận hành

- **Số liệu báo cáo giảm nhẹ**: `Số đơn`/`Số view` không còn cộng đôi cho 283 video ⇒ cần **thông báo người dùng báo cáo** trước khi đổi nguồn trong Power BI.
- Sau khi có bảng này, phía Power BI cần **đổi `table_new_video` từ calculated table sang M query** đọc `marts.mart_new_video` (giống `postgre_data_detail`), và **giữ nguyên 6 measure**. Việc sửa .pbix nằm ngoài phạm vi spec này.
- `mart_new_video` phụ thuộc `mart_data`, nên trong lệnh build phải chạy **sau** `mart_data` (dbt tự xếp thứ tự qua `ref`).

## 8. Ngoài phạm vi

- Sửa file .pbix (đổi nguồn bảng, xóa calculated table/columns).
- Đưa các measure phụ thuộc parameter xuống SQL.
- Tối ưu thêm I/O của `mart_data` (đã xử lý ở vòng tối ưu marts trước; giới hạn còn lại là phần cứng server).
