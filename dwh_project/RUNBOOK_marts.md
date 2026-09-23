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

### Cột `campaign_id` (có ở cả 3 bảng, kiểu `text`)

Nguồn: cột `campaign_id` của `MVA_KOC_KOL_send_sample` (MySQL) → `raw.send_sample` → `stg`/`int_send_sample`.
Được **tính** ở `mart_data` trong cụm `vm_pick`: mỗi dòng video lấy `campaign_id` từ bản ghi gửi mẫu
khớp với nó — cùng creator (không phân biệt hoa/thường), cùng `prod_contain`, `SL > 0`, và **video phải
lên sóng trong khoảng hiệu lực** `[ngay_duyet_mau … ngay_ket_thuc]`. Không khớp → `NULL`.
`mart_data_agg` (1 chiều trong `group by`) và `mart_new_video` chỉ lấy thẳng cột này xuống, KHÔNG tính lại.

> ⚠️ **`dbt build` KHÔNG tự nạp MySQL → raw.** Campaign mới chỉ xuất hiện sau khi chạy
> `python el\load_raw.py` (có nạp `send_sample`) TRƯỚC. Bỏ qua bước này thì `campaign_id` giữ
> nguyên dữ liệu cũ mà **không báo lỗi gì**.

> ⚠️ **Gán campaign hồi tố:** nếu ai đó điền `campaign_id` cho một lần gửi mẫu CŨ, các dòng
> `mart_data` ngoài cửa sổ `incr_days` sẽ không được cập nhật. Khi đó phải chạy full-refresh
> (mục 2) hoặc tạm nâng `incr_days` đủ rộng để phủ tới ngày gửi mẫu đó.

## 0. Chuẩn bị (1 lần cho mỗi cửa sổ PowerShell)
```powershell
# từ D:\PTDL\DBT_postgre
.\venv\Scripts\Activate.ps1
cd dwh_project
. .\load_connections.ps1        # nạp connections.env -> DBT_PROFILES_DIR, SRC_*, DEST_*, PYTHONUTF8
```
> Nạp dữ liệu raw mới trước khi build (daily) — không kèm `--tables` là nạp cả 4 bảng:
> ```powershell
> python el\load_raw.py --days 14
> ```
> Cờ `load_raw.py`: `--tables` chọn bảng nạp (mặc định tất cả 4 bảng); `--days N`/`--from/--to`
> giới hạn performance_list; `--chunk-days N` nạp performance_list theo lô N ngày (an toàn cho
> full-refresh cả lịch sử, tránh stream dài bị MySQL đóng kết nối).

---

## 1. INCREMENTAL — chạy THƯỜNG NGÀY (chỉ nạp lại ~cửa sổ ngày gần nhất)

Build đúng thứ tự, từ view thượng nguồn xuống 2 bảng đích:
```powershell
dbt run
```
> `+mart_data+` = **thượng nguồn** (staging/intermediate views + seed) + `mart_data` + **hạ nguồn**
> (`mart_data_agg`, `mart_new_video`) — dbt tự xếp thứ tự. Xem mục 3 để hiểu vì sao KHÔNG nên dùng
> `mart_data+` (thiếu `+` phía trước).

Đổi độ dài cửa sổ khi chạy (mặc định 90; daily NÊN dùng 14 vì drift đã hết):
```powershell
dbt run --vars '{incr_days: 14}'
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
dbt run --full-refresh
```
> `--full-refresh` dựng lại `mart_data` (bỏ filter cửa sổ) VÀ `mart_data_agg` (toàn bộ tháng,
> bỏ qua mode incremental). `mart_new_video` là table nên luôn dựng lại. Dùng full-refresh để bắt
> thay đổi hồi tố `send_sample` cho dòng/tháng cũ ngoài cửa sổ daily.

---

## 2b. MÔ HÌNH ID — marts hạ nguồn chở KHOÁ, dim chở NHÃN

Từ 2026-09-22, `mart_data_agg` / `mart_new_video` **không còn** `creator_name`, `PIC`, `Team`.
Chúng chở `creator_id` + `pic_user_id`; nhãn lấy từ 2 bảng dim khi join trong Power BI.

| Bảng | Vai trò | Dòng |
|---|---|---|
| `marts.map_creator` | kho **chỉ-thêm** mọi cặp (creator_id, tên) từng thấy + first/last_seen | 54.533 |
| `marts.map_creator_resolve` | view: tên → creator_id, chỉ tên phân giải DUY NHẤT | — |
| `marts.dim_creator` | **1 dòng/creator_id**, tên mới nhất — đích join của PBI | 45.441 |
| `marts.dim_pic` | **1 dòng/user_id** (username, team_phong_ban) — đích join của PBI | 79 |

> ⚠️ `dim_creator` BẮT BUỘC 1 dòng/creator_id. Nếu chứa đủ mọi tên, join vào fact sẽ
> **nhân bản** mỗi dòng theo số tên (có creator 12 tên) → phá mọi phép tổng. Muốn tra lịch
> sử tên thì `select * from marts.map_creator where creator_id = '...' order by last_seen desc`.

> ⚠️ `map_creator` có `full_refresh=false` nên `--full-refresh` KHÔNG xoá nó (đã kiểm chứng:
> chạy full-refresh toàn cây, bảng vẫn 54.533 dòng). Đây là chủ ý — `full_load()` dùng
> TRUNCATE nên nếu MySQL dọn dữ liệu cũ, đây là nơi DUY NHẤT còn giữ tên cũ.

### Bảng `users` (nguồn Postgres `krm`)

`load_raw.py` nay đọc 2 nguồn. `users` đến từ Postgres `krm` (KHÔNG phải MySQL) vì Postgres
không join cross-database được. Cần `KRM_HOST/KRM_PORT/KRM_DB/KRM_USER/KRM_PASSWORD` trong
`connections.env`.

> ⚠️ **TUYỆT ĐỐI không đặt tên biến KRM là `DEST_*`.** `load_connections.ps1` nạp tuần tự và
> dòng sau ghi đè dòng trước → `DEST_*` sẽ trỏ vào `krm` và `dbt run --full-refresh` sẽ dựng
> toàn bộ marts **vào database sản xuất `krm`**. Đã suýt xảy ra ngày 2026-09-22.

---

## 2c. BẪY: dựng lại view lẻ làm CHẾT view hạ nguồn

dbt drop view kèm `cascade`. Dựng lẻ `stg_pic_team` sẽ **xoá luôn** `int_send_sample` (view phụ
thuộc), và lỗi chỉ lộ ra ở lần chạy sau dưới dạng "relation does not exist".

❌ `dbt run -s stg_pic_team`
✅ `dbt run --exclude mart_data mart_data_agg mart_new_video map_creator` (dựng cả cụm view)

> Chạy dbt từ Bash (không qua `load_connections.ps1`) thì phải tự export thêm
> `SRC_DB="$DEST_DB" SRC_SCHEMA=raw`, nếu không `source('raw',...)` sẽ trỏ sang database `dwh`
> và báo `cross-database references are not implemented`.

---

## 3. CHỌN SELECTOR ĐÚNG — `mart_data+` hay `+mart_data+`?

Dấu `+` **đằng sau** = "và hạ nguồn". Dấu `+` **đằng trước** = "và thượng nguồn". Đếm thật bằng `dbt ls`:

| Selector | Số node | Gồm những gì |
|---|---|---|
| `mart_data+` | **3** | `mart_data`, `mart_data_agg`, `mart_new_video` |
| `+mart_data+` | **13** | thượng nguồn + mart_data + hạ nguồn — **THIẾU 3 node** |
| `dbt run` (không `-s`) | **16** | toàn bộ project |

> ⚠️ **`+mart_data+` BỎ SÓT `dim_creator`, `dim_pic`, `stg_users`.** Chúng là nhánh SONG SONG,
> không phải thượng/hạ nguồn của `mart_data`, nên selector đó không chạm tới. Mà đây lại đúng là
> 2 bảng dim Power BI join vào để lấy `creator_name` / `username` / `team` → dùng `+mart_data+`
> cho daily sẽ khiến nhãn hiển thị **cũ dần mà không ai biết**.
>
> ✅ Từ nay daily dùng **`dbt run` không selector** (16 node). Ba node thừa đều rẻ:
> `stg_users` là view, `dim_pic` 79 dòng, `dim_creator` quét bảng 54k dòng.

### Khi nào BẮT BUỘC phải có `+` phía trước

| Thứ gì thay đổi | Cần `+` phía trước? |
|---|---|
| **Dữ liệu** (vừa chạy `load_raw`) | ❌ không — staging/intermediate là **view**, tự phản ánh raw ngay |
| **File model** thượng nguồn (`stg_*.sql`, `int_*.sql`) | ✅ **có** — view trong DB vẫn chạy câu SQL **cũ** cho tới khi `dbt run` dựng lại |

> ⚠️ Đây là bẫy im lặng. Sửa `int_send_sample.sql` rồi chạy `dbt build -s mart_data+` thì dbt
> báo thành công nhưng `mart_data` vẫn đọc view CŨ. Không có cảnh báo nào.

**Khuyến nghị: dùng `+mart_data+` làm mặc định.** Các model thượng nguồn đều là view, dựng dưới 1 giây
→ gần như không tốn thêm thời gian, mà khỏi phải nhớ hôm nào có sửa model. Thêm model mới về sau
(vd `int_creator_alias`) cũng tự nằm trong phạm vi, không phải sửa lệnh.

### Selector dùng tên MODEL, không phải tên BẢNG

2 model đang có `alias` → tên bảng vật lý khác tên model:

| Model (dùng trong `-s`) | Bảng thật được ghi |
|---|---|
| `mart_data` | `marts.mart_data` |
| `mart_data_agg` | **`marts.mart_data_agg_test`** |
| `mart_new_video` | **`marts.mart_new_video_test`** |

Gõ `-s mart_data_agg_test` thì dbt **không tìm thấy gì**.

> ⚠️ **Power BI đang đọc chính 2 bảng `_test`.** Các bảng KHÔNG hậu tố là bản cũ bỏ không.
> Nghĩa là alias **KHÔNG phải lưới an toàn** — mọi thay đổi schema tác động báo cáo ngay lần build đầu.

---

## 4. LỆNH DỰNG ĐẦY ĐỦ (A → Z)

Nạp toàn bộ dữ liệu đầu vào rồi dựng hết từ thượng nguồn tới 2 bảng đích:

```powershell
python el\load_raw.py --chunk-days 30
dbt run --full-refresh
```

> ⚠️ **Dùng `dbt run`, KHÔNG dùng `dbt build`** cho lệnh đầy đủ. `dbt build` chạy cả unit test, mà
> `ut_stg_send_sample_cleanup` đang **ERROR** → nó chặn `stg_send_sample` và **SKIP toàn bộ hạ nguồn**
> (đã kiểm chứng: `ERROR=1 SKIP=4`). Lỗi này có từ trước và chưa được sửa. `dbt build -s mart_data+`
> không gặp vì selector đó không chạm tới `stg_send_sample`.

Chạy test riêng (hiện có đúng 1 ERROR đã biết, 15 test còn lại pass):
```powershell
dbt test
```

> ⚠️ `--chunk-days` ở chế độ full **KHÔNG `TRUNCATE`** — nó chỉ `DELETE` từng lô trong dải
> `min/max(date_file_excel)` của MySQL. Dòng nào trong `raw` nằm ngoài dải đó (hoặc `date_file_excel`
> rỗng) sẽ **sống sót**. Muốn xoá sạch thật sự: `python el\load_raw.py` (không `--chunk-days`).

Khi nào unit test kia được sửa thì gộp lại thành một lệnh:
```powershell
dbt build -s +mart_data+ --full-refresh
```

---

## Ghi chú
- `dbt build` = model + test. `dbt run` = chỉ model, không test → dùng khi test đang hỏng chặn pipeline (mục 4).
- Chạy cả pipeline: `dbt build` trơn (bỏ `-s`) ≡ `-s +mart_data+` ở project này (10/10 node).
- Nút thắt tốc độ còn lại là disk I/O + `shared_buffers` của server đích (bảng ~2GB), không sửa được bằng SQL — xem lịch sử tối ưu trong git.

---

## BẢNG TRA LỆNH NHANH

Chạy sau khi đã chuẩn bị (mục 0): `.\venv\Scripts\Activate.ps1` → `cd dwh_project` → `. .\load_connections.ps1`.

### A. `load_raw.py` (EL: MySQL → raw)
```powershell
# Daily (khuyến nghị): cả 4 bảng — performance_list 14 ngày, 3 bảng nhỏ full
python el\load_raw.py --days 14

# Dạng dài tương đương (liệt kê tường minh, không khác gì)
python el\load_raw.py --tables performance_list send_sample product_name_map pic_team --days 14

# Nạp TẤT CẢ 4 bảng, full (mặc định không cờ) — performance_list bị TRUNCATE
python el\load_raw.py

# Chỉ 1 / vài bảng (bảng nhỏ luôn full)
python el\load_raw.py --tables send_sample
python el\load_raw.py --tables send_sample product_name_map

# performance_list theo khoảng ngày cụ thể
python el\load_raw.py --tables performance_list --from 2026-01-01 --to 2026-03-31

# Full-refresh performance_list AN TOÀN theo lô (tránh stream dài đứt kết nối)
python el\load_raw.py --tables performance_list --chunk-days 30
```
> Cờ: `--tables {performance_list|send_sample|product_name_map|pic_team}` (chọn nhiều, mặc định tất cả);
> `--days N` hoặc `--from/--to` (chỉ áp performance_list); `--chunk-days N` (chia lô, dùng khi full-refresh cả lịch sử).

### B. `mart_data_agg` (incremental theo `thang`)
```powershell
# Mặc định — daily (tháng hiện tại + tháng trước)
dbt build -s mart_data_agg

# Truyền tháng (backfill đúng (các) tháng, không đụng tháng khác)
dbt build -s mart_data_agg --vars '{agg_months: ["2026-06","2026-07"]}'

# Full (dựng lại toàn bộ)
dbt build -s mart_data_agg --full-refresh
```

### C. `mart_new_video` (table — luôn dựng full, chưa incremental)
```powershell
dbt build -s mart_new_video
```

### D. Cả cụm marts (thượng nguồn → 2 bảng đích)
```powershell
# Daily: view thượng nguồn → mart_data 14 ngày → agg mặc định → new_video full
dbt run --vars '{incr_days: 14}'

# Full-refresh toàn bộ (định kỳ hằng tuần, bắt sửa hồi tố send_sample)
dbt run --full-refresh
```
> Dùng `+mart_data+` (có `+` phía trước) làm mặc định — xem mục 3. `mart_data+` bỏ sót các view
> thượng nguồn nên KHÔNG áp dụng được thay đổi ở `stg_*.sql` / `int_*.sql`.

### E. Trình tự CHUẨN mỗi ngày
```powershell
python el\load_raw.py --days 14
dbt run --vars '{incr_days: 14}'
```
> `--days 14` không kèm `--tables` = nạp **cả 4 bảng**, tương đương hệt lệnh dài
> `--tables performance_list send_sample product_name_map pic_team --days 14`.
> 3 bảng nhỏ (`send_sample`, `product_name_map`, `pic_team`) LUÔN full reload dù truyền `--days`;
> `--days` chỉ giới hạn `performance_list`. Riêng `send_sample` là **bắt buộc** nếu muốn `campaign_id` cập nhật.

> ⚠️ **Hai con số phải khớp nhau.** `load_raw --days N` và `--vars '{incr_days: N}'` phải cùng N.
> Nạp tháng 1 (`--from 2026-01-01`) mà chạy `incr_days: 14` thì dbt **báo thành công nhưng không
> cập nhật dòng nào** — không có gì cảnh báo bạn.

> ℹ️ Vì `send_sample` LUÔN full reload, mọi sửa đổi bên MySQL (kể cả đổi `Tên sản phẩm`) lan vào
> hệ thống **ngay lần chạy kế tiếp, không độ trễ, không cảnh báo**. Nếu tên sản phẩm đổi làm luật
> `prod_contain` không còn khớp → `prod_contain = NULL` → video mất attribution và **biến mất khỏi
> `mart_new_video`** (bảng này có `having count(*) filter (where duration_date > 0) > 0`, loại cả dòng
> chứ không hiện số 0).

Chạy một dòng (dùng cho Task Scheduler):
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "cd D:\PTDL\DBT_postgre\dwh_project; . .\load_connections.ps1; python el\load_raw.py --days 14; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; dbt run --vars '{incr_days: 14}'; exit $LASTEXITCODE"
```
> `if ($LASTEXITCODE -ne 0) { exit ... }` sau bước EL là **quan trọng**: nếu dùng `;` trơn mà EL lỗi,
> dbt vẫn chạy tiếp trên dữ liệu raw cũ và báo thành công — hỏng dữ liệu trong im lặng.
> `mart_data_agg` / `mart_new_video` đọc từ `mart_data` → nếu chỉ chạy riêng chúng, phải chạy `mart_data` (hoặc `mart_data+`) TRƯỚC.
