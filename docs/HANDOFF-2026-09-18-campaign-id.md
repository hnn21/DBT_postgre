# BÀN GIAO — thêm `campaign_id` (+ 2 cột booking) vào pipeline dbt

**Ngày:** 2026-09-18 · **Repo:** `D:\PTDL\DBT_postgre` · **Nhánh:** `feat/mva-video-aff-data`
**Mục đích file này:** chuyển tiếp công việc sang session Claude Code mới.

---

## 1. Việc đang làm

Lan truyền cột `campaign_id` từ bảng gửi mẫu (MySQL) xuống 3 bảng marts, để báo cáo Power BI có thêm **lát cắt theo campaign**.

Chuỗi dữ liệu:
```
MySQL MVA_KOC_KOL_send_sample
  └─ el/load_raw.py ──> raw.send_sample            (text, tầng raw vốn all-text)
      └─ stg_send_sample  ──> ÉP KIỂU sang int tại đây
          └─ int_send_sample (tự đi qua nhờ `select ss.*`)
              └─ mart_data        ──> TÍNH campaign_id (cụm vm_pick)
                  ├─ mart_data_agg    (campaign_id là 1 chiều trong GROUP BY)
                  └─ mart_new_video   (1 dim như PIC/Vị trí)
```

### Quy tắc tính `campaign_id` (nằm ở `mart_data`, cụm `vm_pick`)

Mỗi dòng video lấy `campaign_id` từ bản ghi gửi mẫu khớp với nó:

```sql
lower(s.koc_kol) = lower(k.creator_name)   -- không phân biệt hoa/thường
AND s.prod_contain = k.prod_contain
AND s.sl > 0
AND s.ngay_duyet_mau <= k.time
AND k.time <= s.ngay_ket_thuc              -- video phải lên TRONG khoảng hiệu lực
-- lấy bản ghi có ngay_duyet_mau SỚM NHẤT: max(campaign_id) filter (where ngay_duyet_mau = mn)
```

Không khớp → `NULL`. `mart_data_agg` và `mart_new_video` **không tính lại**, chỉ lấy thẳng cột xuống.

> Vì `int_send_sample` tính `ngay_ket_thuc` = *ngày gửi mẫu kế tiếp − 1*, các lần gửi mẫu của cùng `(KOC, sản phẩm)` xếp thành dải **không chồng lấn** → mỗi video rơi vào đúng 1 lần gửi mẫu → campaign là duy nhất, không mơ hồ.

---

## 2. ĐÃ XONG (đã commit + đã chạy trên DB)

| Commit | Nội dung |
|---|---|
| `4146246` | spec thiết kế |
| `f0e5619` | plan triển khai |
| `b042d66` | EL kéo `campaign_id` về raw + `full_load()` tự đồng bộ cột mới |
| `ccd8786` | `mart_data` tính `campaign_id` theo cụm `vm_pick` + unit test `ut_mart_campaign_id` |
| `a4af671` | `mart_data_agg` (vào GROUP BY) + `mart_new_video` |
| `12e6a20` | cập nhật `RUNBOOK_marts.md` |
| `b7e6a35` | ép kiểu `campaign_id` text → **int** tại `stg_send_sample` |

### Trạng thái DB (đã kiểm chứng)

| Bảng | Dòng | `campaign_id` |
|---|---|---|
| `raw.send_sample` | 43.473 | `text` (giữ nguyên — raw vốn all-text) |
| `staging.stg_send_sample` | view | **integer** ← chỗ ép kiểu |
| `intermediate.int_send_sample` | view | integer |
| `marts.mart_data` | 5.464.601 | integer — **5.639 dòng có campaign** |
| `marts.mart_data_agg` | 2.248.106 | integer — **2.010 dòng có campaign** |
| `marts.mart_new_video` | 66.915 | integer — **905 video có campaign** |

Giá trị campaign hiện có: `[5, 7, 8, 13, 14, 15, 20, 21, 29, 30, 36]` (11 giá trị; raw có 12, campaign `15` chưa có video nào rơi vào khoảng hiệu lực — đúng, không phải mất dữ liệu).

**Độ phủ:** campaign chỉ bắt đầu từ **2026-08-15** nên chỉ video lên sóng từ đó mới có. ~3.487/213.285 video (1,6%) là cận trên. Phần `NULL` là đúng bản chất.

---

## 3. ĐANG DANG DỞ — việc cần làm tiếp

### 3.1. Hai cột `koc_booking_content_id`, `kol_booking_content_id`

**Hiện trạng đo được:**

| Nơi | Có 2 cột này? |
|---|---|
| MySQL `MVA_KOC_KOL_send_sample` | **KHÔNG** |
| `raw.send_sample` | KHÔNG |
| `marts.mart_data` | KHÔNG |
| `marts.mart_data_agg` | **CÓ** — kiểu `integer`, 0 dòng có giá trị |
| `marts.mart_new_video` | **CÓ** — kiểu `integer`, 0 dòng có giá trị |

(User tự thêm tay 2 cột này vào 2 bảng marts.)

**Câu hỏi user đặt ra:** "hay là không động đến 2 cột đang có sẵn trong bảng được không?"

**Đã trả lời: KHÔNG ĐƯỢC.** Lý do (có bằng chứng thực tế trong session):

- `mart_data_agg` là **incremental**: dbt dựng danh sách cột cho `INSERT` từ **cột của bảng đích**. Cột nào có trong bảng mà model không sinh ra → lỗi:
  ```
  column "campaign_name" does not exist
  DETAIL: There is a column named "campaign_name" in table "mart_data_agg",
          but it cannot be referenced from this part of the query.
  ```
  Lỗi này đã xảy ra thật (15:34:46 ngày 14/09) do chính mấy cột mồ côi này.
- `mart_new_video` là **`materialized='table'`**: dbt tạo bảng mới rồi đổi tên thay thế → 2 cột đó **bị xoá sạch mỗi lần build**, không cách nào giữ.

**Phương án đã chốt (chưa thực hiện):** model phải sinh ra đủ 3 cột, 2 cột booking để `NULL`:
```sql
null::int as koc_booking_content_id,
null::int as kol_booking_content_id,
```
`::int` để khớp kiểu `integer` đang có. Ở `mart_data_agg` chúng là **hằng số nên KHÔNG cần đưa vào `GROUP BY`** → không ảnh hưởng grain, không phình dòng.

**CÒN THIẾU — 2 điều cần user xác nhận trước khi sửa:**
1. **Thêm vào những bảng nào?** `mart_data_agg` + `mart_new_video` (2 bảng đang có sẵn 2 cột đó), hay thêm cả vào `mart_data`?
2. **Kiểu `int` có đúng không?** Hiện là `integer`. Nếu sau này ID booking là chuỗi/UUID thì nên để `text` ngay từ đầu để khỏi phải đổi kiểu lần nữa.

### 3.2. Thay đổi CHƯA COMMIT — `alias` trỏ sang bảng test

```
M dwh_project/models/marts/mart_data_agg.sql    → thêm alias='mart_data_agg_test'
M dwh_project/models/marts/mart_new_video.sql   → thêm alias='mart_new_video_test'
```

⚠️ **Đang bật thì `dbt build` sẽ ghi vào `marts.mart_data_agg_test` / `marts.mart_new_video_test`, KHÔNG phải bảng thật.** Quyết định giữ hay bỏ trước khi chạy production.

---

## 4. BẪY ĐÃ GẶP — đọc kỹ để khỏi mất thời gian lại

1. **`dbt build` KHÔNG tự nạp MySQL → raw.** Phải chạy `python el\load_raw.py` trước. Bỏ qua thì `campaign_id` giữ dữ liệu cũ mà **không báo lỗi gì**.

2. **`CREATE TABLE IF NOT EXISTS` không thêm cột mới.** Bảng `raw.*` đã tồn tại nên thêm cột ở MySQL sẽ làm `COPY` lỗi. **Đã sửa** trong `full_load()`: tự `ALTER TABLE ADD COLUMN` cho mọi cột còn thiếu (chỉ THÊM, không xoá).

3. **`on_schema_change` mặc định là `'ignore'`** → model incremental **âm thầm bỏ qua cột mới**. Đã set `'append_new_columns'` cho `mart_data` và `mart_data_agg`.

4. **Cột mồ côi làm gãy incremental INSERT** (xem mục 3.1). Từng có 3 cột mồ côi `campaign_name` + 2 booking; `campaign_name` đã xoá, 2 booking được user thêm lại.

5. **Lệch kiểu dữ liệu**: cột thêm tay là `integer` còn model sinh ra `text` → `column "campaign_id" is of type integer but expression is of type text`. Khi đổi kiểu cả bảng, dùng `ALTER COLUMN ... TYPE ... USING ...` (giữ nguyên dữ liệu) thay vì dựng lại — nhanh hơn nhiều: 0,4s / 251s / 423s cho 3 bảng.

6. **View `intermediate.*` có thể biến mất** (drift). Khi đó unit test của `mart_data` ERROR hàng loạt. Sửa: `dbt run -s int_send_sample int_valid_classification` (view dựng trong <1s).

7. **Nạp env**: phải dot-source — `. .\load_connections.ps1` (dấu chấm + khoảng trắng). Không nạp thì dbt báo `Env var required but not provided: 'DEST_HOST'`.

8. **`$LASTEXITCODE` trong `powershell -Command "..."`**: nếu gọi từ PowerShell, shell ngoài thay biến TRƯỚC → mã thoát sai. Gọi từ cmd/Task Scheduler mới đúng.

9. **Server Postgres nghẽn disk I/O** (`shared_buffers` 128MB, bảng ~2GB). Thời gian build dao động mạnh theo cache. Huỷ dbt ở máy **không** dừng query phía server — phải `pg_cancel_backend`.

---

## 5. Lệnh chạy

**Chuẩn bị (1 lần mỗi cửa sổ PowerShell):**
```powershell
.\venv\Scripts\Activate.ps1
cd dwh_project
. .\load_connections.ps1
```

**Daily:**
```powershell
python el\load_raw.py --tables performance_list send_sample product_name_map pic_team --days 14
dbt build -s mart_data+ --vars '{incr_days: 14}'
```

**Chỉ 2 bảng hạ nguồn (mart_data đã xong):**
```powershell
dbt build -s mart_data_agg mart_new_video
```

Chi tiết đầy đủ: `dwh_project/RUNBOOK_marts.md` (có bảng tra lệnh nhanh).

---

## 6. File liên quan

| File | Vai trò |
|---|---|
| `dwh_project/el/load_raw.py` | EL MySQL→raw; có `--tables`, `--days`, `--from/--to`, `--chunk-days` |
| `dwh_project/models/staging/stg_send_sample.sql` | ép kiểu `campaign_id` → int (dòng 17) |
| `dwh_project/models/marts/mart_data.sql` | **tính** campaign_id — cụm `vm_ranked`/`vm_pick`/`picks`/`j`/`final` |
| `dwh_project/models/marts/mart_data_agg.sql` | campaign_id trong GROUP BY |
| `dwh_project/models/marts/mart_new_video.sql` | campaign_id là 1 dim |
| `dwh_project/models/marts/_mart_data.yml` | unit test, có `ut_mart_campaign_id` |
| `dwh_project/RUNBOOK_marts.md` | runbook lệnh chạy |
| `docs/superpowers/specs/2026-09-14-campaign-id-design.md` | spec thiết kế |
| `docs/superpowers/plans/2026-09-14-campaign-id.md` | plan triển khai |
