# Thiết kế: Tái tạo bảng `data` (MVA_VideoAFF) trong dbt — MySQL → PostgreSQL

**Ngày:** 2026-07-15
**Nguồn logic:** file Power BI `MVA_VideoAFF.pbix`
**Mục tiêu:** Tái tạo đầy đủ bảng `data` của Power BI (cột gốc MySQL + 14 cột tính toán DAX) thành **một bảng rộng** `mart_data` trên PostgreSQL, dùng dbt.

---

## 1. Bối cảnh & quyết định

| Vấn đề | Quyết định |
|---|---|
| Raw ở đâu | MySQL `27.71.20.96` / db `tiktok_dashboard` |
| Kết quả ở đâu | PostgreSQL (server đích, cấu hình qua env) |
| Cầu nối MySQL→PG | **Load raw** 4 bảng MySQL vào schema `raw` trên Postgres (EL nhẹ bằng Python), rồi dbt transform |
| `TODAY()` trong DAX | Thay bằng `current_date` (ngày chạy `dbt run`) |
| Kết quả cuối | 1 bảng rộng = toàn bộ cột gốc `data` + 14 cột tính toán |
| Kiểm chứng | So khớp với `EVALUATE data` lấy từ Power BI qua MCP |

## 2. Danh mục nguồn

| Bảng Power BI | Nguồn thật | dbt |
|---|---|---|
| `data` (base) | MySQL `performance_list` | source → `stg_performance_list` |
| `Table_send_sample` (base) | MySQL `MVA_KOC_KOL_send_sample` | source → `stg_send_sample` |
| `get_product_name_from_video_tiktok` | MySQL cùng tên | source → `stg_product_name_map` |
| `doiten_PIC` | MySQL `PIC_Team` | source → `stg_pic_team` |
| `videos_id_agency_full` | **Danh sách tĩnh nhúng trong .pbix** | **seed** `videos_id_agency.csv` (trích từ MCP) |
| `dim_phanloai_creator` | Suy diễn từ `Table_send_sample` | `int_valid_classification` |

`table_new_video` **không cần** (chỉ phục vụ cột `check`, ngoài phạm vi).

## 3. Kiến trúc phân tầng

```
raw (load từ MySQL)         staging (view)            intermediate            marts
─────────────────────       ────────────────          ─────────────           ─────────
performance_list       ──►  stg_performance_list ─┐
MVA_KOC_KOL_send_sample──►  stg_send_sample ──────┼─► int_send_sample ────┐
get_product_name...    ──►  stg_product_name_map ─┤   int_valid_classif.  ├─► mart_data
PIC_Team               ──►  stg_pic_team ─────────┘                       │  (bảng rộng)
seed: videos_id_agency ─────────────────────────────────────────────────┘
```

- **staging**: mỗi bảng 1 view, áp đúng phép làm sạch trong Power Query M (xem §5).
- **intermediate**:
  - `int_send_sample`: dựng các cột phái sinh của `Table_send_sample`.
  - `int_valid_classification`: whitelist phân loại creator.
- **marts**: `mart_data`, materialized = `table`.

## 4. Cấu hình linh hoạt (đã có sẵn khung)
- Nguồn raw: `vars.raw_schema` (mặc định `raw`).
- Đích: target `dev`/`prod` trong `profiles.yml`, đổi bằng `--target`.
- Windows: `PYTHONUTF8=1` (đã set trong `env.*.ps1`).

## 5. Chi tiết staging (làm sạch 1-1 theo M query)

### stg_performance_list ← raw.performance_list
Cột (đổi tên giữ nguyên như Power BI): `creator_id, video_id, time (→date), creator_name, product_name, vv, comment, share, new_follower, clicks_from_view_to_like, product_impressions, click_on_the_product, customer, count_order, unit_sales, video_revenue, gpm, gmv, ctr, view_to_like_ratio, video_viewing_rate, co_ratio, date_file_excel (→date), brand`.
- `time = date(time)`, `date_file_excel = date(date_file_excel)`.
- `creator_name = replace(creator_name, '\', '')`, `product_name = replace(product_name, '\', '')`.

### stg_send_sample ← raw.MVA_KOC_KOL_send_sample
- `ngay_duyet_mau = date(...)`
- `koc_kol = trim(replace(replace("KOC/KOL", '@',''), 'Vinhchinchu','vinhchinchu'))`
- `phan_loai_creator = trim(coalesce(nullif("Phân loại Creator",''),'L1'))`
- `sl = cast(... as int)`, `so_video = cast(... as int)`, `cost = cast(... as int)`
- Giữ: `pic, nguon_yeu_cau, ten_san_pham, sheet, mst_cccd, ma_don_hang, vi_tri, sdt`
- **WHERE**: `koc_kol` not null/rỗng AND `pic` not null/rỗng.

### stg_product_name_map ← raw.get_product_name_from_video_tiktok
`video_id, product_contain, product_contain_combo`.

### stg_pic_team ← raw.PIC_Team
`raw_name (Raw_name), doi_ten (Change_name), team (Team)`.

### seed videos_id_agency.csv
Cột `video_id`. Trích giá trị hiện tại từ Power BI qua MCP (`EVALUATE videos_id_agency_full`).

## 6. Intermediate

### int_send_sample (từ stg_send_sample + stg_pic_team)
- `prod_contain`: `SWITCH(TRUE(), CONTAINSSTRING(ten_san_pham, ...))` — **theo thứ tự luật của Table_send_sample**:
  son dưỡng → biotin → kẽm → vitamin c → vitamin tổng(→"vitamin tổng hợp") → canxi → dầu tẩy trang → (kem chống nắng & togishi)→"Kem chống nắng" → vệ sinh nam→"VSnam" → (COLD CREAM & mini)|COLD CREAM→"Cold cream" → FOAMING FACE WASH → WHITENING MOISTURE GEL → adlay→"ADLAY" → (b mix|bmix|b-mix)→"b mix" → kem ủ→"Adolph kem ủ" → (adolph&hộp)→"Adolph hộp quà" → (adolph&gội)→"Adolph gội" → (adolph&xả)→"Adolph xả" → (adolph&tinh dầu)→"Adolph tinh dầu" → (adolph&sữa tắm)→"Adolph sữa tắm" → else NULL. (so khớp không phân biệt hoa thường)
- `pic_rename`: LEFT JOIN pic_team ON `pic = raw_name`; `= coalesce(doi_ten, pic)`.
- `team`: LEFT JOIN pic_team ON `pic_rename = doi_ten` → `team`.
- `phan_loai_creator_fix = phan_loai_creator`.
- `ngay_ket_thuc`: `lead(ngay_duyet_mau) over (partition by koc_kol, prod_contain order by ngay_duyet_mau)`; nếu có giá trị → `- interval '1 day'`, nếu NULL → `date '2099-12-31'`.
- `product_detail`: `case when sheet ilike '%adolph%' then prod_contain else ten_san_pham end`.
- (Bỏ cột `check`.)

### int_valid_classification
`DISTINCT phan_loai_creator` từ stg_send_sample WHERE not blank AND not ilike `%quà%` AND not ilike `%nghiệm%` AND not ilike `%house%`, UNION các giá trị `'T'`, `'L2.1'`, `'L2.2'`.

## 7. mart_data — 14 cột tính toán (thứ tự phụ thuộc)

Xây bằng chuỗi CTE, mỗi CTE thêm cột. Các phép "lấy 1 bản ghi khớp" dùng **LEFT JOIN LATERAL** vào `int_send_sample`.

1. **prod_contain**: LEFT JOIN product_name_map ON video_id → `_name`. `= coalesce(nullif(_name,''), <SWITCH rules trên product_name>)`.
   Luật SWITCH của **data** (khác thứ tự với send_sample): (b mix|bmix|b-mix)→"b mix" → son dưỡng → biotin → kẽm → vitamin c → vitamin tổng→"vitamin tổng hợp" → canxi → dầu tẩy trang → (kem chống nắng & togishi)→"Kem chống nắng" → vệ sinh nam→"VSnam" → (COLD CREAM|kem lạnh)→"Cold cream" → FOAMING FACE WASH → WHITENING MOISTURE GEL → adlay→"ADLAY" → (adolph&kem ủ)→"Adolph kem ủ" → (adolph&hộp quà)→"Adolph hộp quà" → (adolph&gội) → (adolph&xả) → (adolph&tinh dầu) → (adolph&sữa tắm) → else NULL.
2. **prod_contain_combo**: LEFT JOIN map → `product_contain_combo` (`_name`); `case when _name ilike '%combo%' then _name else prod_contain end`.
3. **ngay_gui_mau**: `MIN(iss.ngay_duyet_mau)` với `iss.koc_kol = creator_name AND iss.prod_contain = data.prod_contain AND iss.sl > 0 AND length(iss.prod_contain) > 0`.
4. **duration_date** (dùng `current_date`):
   - `_duration = (time - ngay_gui_mau)` ngày; `_check_today = (current_date - time)` ngày.
   - `case when ngay_gui_mau is null then -1 when ngay_gui_mau > time then -1 else (case when _check_today<=30 then 7 when _check_today<=60 then 6 when _duration<=7 then 1 when _duration<=14 then 2 when _duration<=30 then 3 when _duration<=90 then 4 else 5 end) end`.
5. **loai_video**: `case when video_id in (seed) then 'Video AI' else 'Video thường' end`.
6. **video_duoctinhpfm**: `case when video_id in (seed) or duration_date > 0 then 1 else 0 end`.
7. **phan_loai_creator**:
   - Tập khớp: `iss.koc_kol=creator_name AND iss.prod_contain=data.prod_contain AND iss.ngay_duyet_mau <= time AND (iss.ngay_ket_thuc is null OR time <= iss.ngay_ket_thuc)`.
   - Priority: S+→1, T→2, S→3, M→4, L2→5, L1→6, L0→7, L1.2→8, L1.1→9, else 999.
   - `PhanLoaiCreator = max(phan_loai_creator_fix)` trong số các dòng có priority nhỏ nhất (TOPN 1 by priority ASC → MAXX).
   - `group_value = PhanLoaiCreator nếu tồn tại trong int_valid_classification, else NULL`.
   - `_kq = case video_duoctinhpfm when 1 then group_value when 0 then 'Organic' end`.
   - Final: `case when prod_contain is null or length(prod_contain)=0 then 'Thiếu dữ liệu tên SP' else coalesce(_kq,'Organic') end`.
8. **group_creator**: `case when phan_loai_creator ilike '%L0%' then 'L0' when ilike '%L1%' then 'L1' when ilike '%L2%' then 'L2' else phan_loai_creator end`.
9. **dk_creator_duoc_gui_mau**: `case when duration_date>0 then 'Có gửi mẫu' else 'Ko gửi mẫu' end`.
10. **dk_time_air_video**: `case when duration_date>0 then 'Thỏa mãn ĐK thời gian là sau khi gửi mẫu' else 'Không tính' end`.
11. **pic**: tập khớp `iss.koc_kol=creator_name AND iss.prod_contain=data.prod_contain AND iss.sl>0 AND iss.prod_contain not blank AND iss.koc_kol not blank AND iss.ngay_duyet_mau<=time AND time<=iss.ngay_ket_thuc`; TOPN(1 by ngay_duyet_mau ASC) → `max(pic_rename)` trong số các dòng ngày sớm nhất.
12. **team**: `max(iss.team)` (FIRSTNONBLANK) với `iss.pic_rename = data.pic` (toàn bộ send_sample, không lọc thời gian).
13. **vi_tri**: tập khớp `iss.koc_kol=creator_name AND iss.prod_contain=data.prod_contain AND iss.ngay_duyet_mau<=time AND time<=iss.ngay_ket_thuc` (KHÔNG lọc SL); TOPN(1 by ngay_duyet_mau ASC) → `max(vi_tri)`.
14. **mau_gui**: cùng tập khớp như vi_tri; TOPN(1 by ngay_duyet_mau ASC) → `max(product_detail)`.

**Bảng cuối** = tất cả cột gốc của stg_performance_list + 14 cột trên.

### Lưu ý ngữ nghĩa TOPN/MAXX → SQL
`TOPN(1, tbl, [key] ASC)` + `MAXX(top, [col])` = trong tập khớp, tìm giá trị `[key]` nhỏ nhất, rồi lấy `MAX([col])` trong các dòng có `[key]` = min đó. Triển khai: subquery lấy `min(key)`, rồi `max(col) where key = min_key`; hoặc `ROW_NUMBER()`/`rank()` + `max`.

## 8. Chiến lược test (TDD)
1. Trích `EVALUATE data` (hoặc tập cột chọn + video_id làm khóa) từ Power BI qua MCP → lưu thành CSV kỳ vọng (seed test).
2. Sau `dbt run`, so khớp `mart_data` với CSV kỳ vọng theo `video_id` (và `time`), báo cáo dòng/cột lệch.
3. Ưu tiên bắt đầu từ các cột đơn giản (prod_contain, loai_video) rồi mở rộng.
4. Lưu ý: `duration_date` và các cột phụ thuộc phụ thuộc `current_date` — khi so khớp phải chạy dbt cùng ngày với thời điểm chụp dữ liệu Power BI.

## 9. Rủi ro / điểm cần xác nhận
- **Khác biệt luật `prod_contain`** giữa `data` và `Table_send_sample` (thứ tự & vài điều kiện) — đã giữ đúng theo từng bảng.
- **So khớp chuỗi tiếng Việt**: đảm bảo collation/không phân biệt hoa thường giống `CONTAINSSTRING` (dùng `ilike` + unaccent nếu cần).
- **Kiểu ngày**: MySQL `DATE()` → Postgres `date`; phép `DATEDIFF(a,b,DAY)` → `(a::date - b::date)`.
- **`current_date`**: kết quả `duration_date` đổi theo ngày chạy — đúng như `TODAY()` trong Power BI.
- **videos_id_agency là snapshot tĩnh**: cần cập nhật seed khi danh sách agency thay đổi.

## 10. Phạm vi KHÔNG bao gồm
- Các measure DAX (count_data, Chi phí gửi mẫu...), các bảng dashboard khác, `table_new_video`, cột `check`.
