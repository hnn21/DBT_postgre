# Thiết kế: lan truyền `campaign_id` từ raw `MVA_KOC_KOL_send_sample` xuống 3 bảng marts

**Ngày:** 2026-09-14
**Mục tiêu:** Đưa cột `campaign_id` (mới thêm ở MySQL) đi hết pipeline — EL → staging → mart_data → mart_data_agg + mart_new_video — để báo cáo cắt được số liệu video theo campaign.

## 1. Bối cảnh — trạng thái đo được (2026-09-14)

**MySQL `MVA_KOC_KOL_send_sample`** đã có cột `campaign_id` (kiểu `text`):

| Chỉ số | Giá trị |
|---|---|
| Tổng dòng | 43.473 |
| Dòng có `campaign_id` | **1.332 (3,1%)** |
| Số campaign khác nhau | **12** (`'5'`, `'8'`, `'7'`, `'13'`, `'36'`, …) |
| Ngày duyệt mẫu sớm nhất có campaign | **2026-08-15** |

Sparsity 3,1% **không phải lỗi dữ liệu**: campaign mới bắt đầu được ghi nhận từ giữa tháng 8/2026, nên toàn bộ dữ liệu trước đó không có campaign. Không tồn tại bảng dimension campaign (chỉ có id trần, không có tên).

**Postgres `raw.send_sample`** hiện có 14 cột, **CHƯA có** `campaign_id` — vì `el/load_raw.py` chưa SELECT cột này.

### 1.1 Ba phát hiện quyết định thiết kế

**(a) Quy tắc pick gần như không có rủi ro.** Khảo sát 38.977 nhóm `(KOC/KOL × Tên sản phẩm)`:

| Kiểm tra | Kết quả | Ý nghĩa |
|---|---|---|
| Nhóm có >1 campaign khác nhau | **1** | Hầu như không có mơ hồ khi chọn |
| Nhóm vừa có campaign vừa có NULL | **0** | Luật "bản ghi sớm nhất" không làm mất campaign |
| Dòng có campaign mà `SL > 0` | **1.332 / 1.332 (100%)** | Bộ lọc `sl > 0` sẵn có không loại dòng nào |

⇒ Dùng chung quy tắc với `Vị trí`/`Mẫu gửi`/`nguon_yeu_cau` là an toàn.

**(b) Không cần full-refresh 5M dòng.** Mọi dòng `mart_data` có video lên sóng từ 2026-08-15 (kỷ nguyên campaign) nằm ở `date_file_excel` trong khoảng **2026-08-07 → 2026-09-12**, tức gọn trong cửa sổ incremental 90 ngày (từ 2026-06-16). Dòng ngoài cửa sổ giữ `campaign_id = NULL` — **đúng**, vì campaign chưa tồn tại khi đó.

**(c) Hai chỗ âm thầm nuốt cột mới.** Đây là điểm dễ vỡ nhất của thay đổi này:
- `el/load_raw.py` → `full_load()` dùng `CREATE TABLE IF NOT EXISTS`. Bảng `raw.send_sample` đã tồn tại nên lệnh này **không thêm cột**; `COPY` với danh sách cột có `campaign_id` sẽ **lỗi** `column "campaign_id" of relation "send_sample" does not exist`.
- `mart_data` và `mart_data_agg` là model **incremental**, dbt mặc định `on_schema_change='ignore'` → cột mới **không xuất hiện** trong bảng đích mà không báo lỗi.

## 2. Phạm vi

**Sửa:** `el/load_raw.py`, `models/staging/stg_send_sample.sql`, `models/marts/mart_data.sql`, `models/marts/mart_data_agg.sql`, `models/marts/mart_new_video.sql`, `models/marts/_mart_data.yml`, `models/marts/_mart_new_video.yml`.

**KHÔNG sửa:** `models/intermediate/int_send_sample.sql` (đang `select ss.*` nên cột tự đi qua), `stg_performance_list.sql`, `int_valid_classification.sql`, các model staging khác.

**KHÔNG làm:** đổi phía Power BI (người dùng tự sửa); tạo dimension campaign (chưa có nguồn tên campaign).

## 3. Quy tắc gắn `campaign_id` vào video (phần "tính")

`campaign_id` nằm ở bảng gửi mẫu, nối với video qua `(creator_name ↔ koc_kol, prod_contain, khoảng thời gian hiệu lực)`. Nó trở thành **cột pick thứ 4** của cụm `vm_pick`, dùng **y hệt** điều kiện đang áp cho `Vị trí`/`Mẫu gửi`/`nguon_yeu_cau`:

```
vm_ranked: join send s với keys_cpt k khi
    lower(s.koc_kol) = lower(k.creator_name)     -- không phân biệt hoa/thường
AND s.prod_contain   = k.prod_contain
AND s.sl > 0
AND s.ngay_duyet_mau <= k.time
AND k.time <= s.ngay_ket_thuc                    -- video phải lên TRONG khoảng hiệu lực

vm_pick:  max(s.campaign_id) filter (where ngay_duyet_mau = mn)
          -- mn = min(ngay_duyet_mau) over (partition by creator_name, prod_contain, time)
```

Hệ quả có chủ ý: video lên sóng **trước** ngày gửi mẫu sẽ **không** nhận campaign (`NULL`), nhất quán với cách `Mẫu gửi` đang hoạt động.

**Xử lý NULL:** giữ nguyên `NULL`, **không** thay bằng nhãn kiểu `'Không campaign'` — nhất quán với `nguon_yeu_cau`/`Vị trí`. Phía báo cáo tự quyết cách hiển thị.

**Kiểu dữ liệu:** `text`. Giá trị hiện là chuỗi số (`'5'`, `'13'`) nhưng để `text` cho nhất quán với tầng raw và an toàn nếu sau này có mã chữ.

## 4. Thay đổi từng tầng

### 4.1 `el/load_raw.py`
1. Thêm `` `campaign_id` `` vào câu SELECT của `send_sample`.
2. Trong `full_load()`, sau `CREATE TABLE IF NOT EXISTS` và **trước** `TRUNCATE`, thêm bước đồng bộ cột: với mỗi cột trong `cols` chưa có ở bảng Postgres, chạy `ALTER TABLE ... ADD COLUMN "<c>" text`. Chỉ THÊM, không xóa/đổi cột. Áp dụng cho cả 3 bảng nhỏ nên lần sau thêm cột ở MySQL không phải đụng tay.

### 4.2 `models/staging/stg_send_sample.sql`
Thêm `campaign_id` vào danh sách cột (passthrough, không ép kiểu, không trim).

### 4.3 `models/marts/mart_data.sql`
- Thêm `s.campaign_id` vào `select` của CTE `vm_ranked`.
- Thêm `max(campaign_id) filter (where ngay_duyet_mau = mn) as campaign_id` vào `vm_pick`.
- Thêm `vm.campaign_id as _campaign_id` vào CTE `picks`.
- Thêm `pk._campaign_id as _campaign_id` vào CTE `j`.
- Thêm `g._campaign_id as campaign_id` vào `final`.
- Thêm `on_schema_change='append_new_columns'` vào `config()`.

### 4.4 `models/marts/mart_data_agg.sql`
- Thêm `campaign_id` vào `select` và vào `group by` → grain **18 chiều + video_id**.
- Thêm `on_schema_change='append_new_columns'` vào `config()`.

Số dòng gần như không tăng: `campaign_id` là hàm của `(creator_name, prod_contain, time)` mà cả ba đều đã nằm trong grain.

### 4.5 `models/marts/mart_new_video.sql`
- Thêm `campaign_id` vào danh sách cột của CTE `base`.
- Thêm `max(campaign_id) filter (where duration_date > 0 and "time" = _min_time) as campaign_id` vào `select` ngoài — y hệt cách `nguon_yeu_cau` đang làm.

## 5. Kiểm thử

**Unit test mới** — `ut_mart_campaign_id` trong `_mart_data.yml`, 2 tình huống trong cùng một test:
- Video lên sóng **trong** khoảng hiệu lực của bản ghi gửi mẫu có campaign → `campaign_id` = giá trị đó.
- Video lên sóng **trước** `ngay_duyet_mau` → `campaign_id = NULL` (chốt đúng điều kiện thời gian ở §3).

**Mở rộng test sẵn có:**
- `ut_agg_grain_dims_video` (`_mart_data.yml`): thêm `campaign_id` vào input và expect.
- `ut_new_video_dedupe_min_time` (`_mart_new_video.yml`): thêm `campaign_id` vào input và expect.

**Khai báo cột** trong 2 YAML: thêm mục `campaign_id` kèm mô tả cho `mart_data`, `mart_data_agg`, `mart_new_video`.

**Đối chiếu sau khi chạy:** `raw.send_sample` phải có 15 cột; số dòng `raw.send_sample` có `campaign_id` khác NULL ≈ 1.332; `mart_data` phải có ít nhất một dòng `campaign_id` khác NULL; số dòng `mart_data_agg` không tăng đáng kể so với trước.

## 6. Thứ tự chạy

```
1. python el\load_raw.py       <-- BẮT BUỘC chạy trước: dbt KHÔNG tự nạp MySQL -> raw
2. dbt build -s mart_data+
```

Không cần `--full-refresh` (xem §1.1(b)). Nếu muốn chắc chắn tuyệt đối vẫn có thể chạy full-refresh, nhưng phải trả giá dựng lại ~5,4M dòng trên server vốn đã nghẽn disk I/O.

## 7. Rủi ro

- **Quên chạy EL trước dbt** → `campaign_id` toàn NULL mà không có lỗi nào. Giảm thiểu: ghi rõ thứ tự ở §6 và trong runbook.
- **`on_schema_change` bị bỏ sót ở một trong hai model incremental** → cột không xuất hiện, im lặng. Giảm thiểu: bước đối chiếu ở §5 kiểm tra sự tồn tại của cột.
- Nếu sau này campaign được **gán hồi tố** cho các lần gửi mẫu cũ (trước 2026-06-16), cửa sổ incremental 90 ngày sẽ không phủ tới → khi đó cần chạy `--full-refresh` một lần.

## 8. Ngoài phạm vi

Sửa file `.pbix` (thêm `campaign_id` vào M query và các visual) — người dùng tự làm.
