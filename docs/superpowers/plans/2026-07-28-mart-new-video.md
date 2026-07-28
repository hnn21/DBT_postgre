# `mart_new_video` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tạo model dbt `mart_new_video` (1 dòng / `video_id`) tái tạo calculated table `table_new_video` của `MVA_VideoAFF_(new_agg).pbix`, nhưng đã dedupe nên không cộng đôi số đơn/số view.

**Architecture:** Một model duy nhất ở tầng marts, đọc `ref('mart_data')`. Dùng window `min("time") filter (where duration_date > 0) over (partition by video_id)` để xác định dòng đại diện, rồi `group by video_id` **trong một lần quét**: 9 cột chiều lấy bằng `max(cột) filter (...)` tại dòng `time = _min_time`, còn `so_don`/`"View"` là `sum()` trên **toàn bộ** dòng của video (kể cả `duration_date <= 0`) — đúng ngữ nghĩa `all()` của DAX.

**Tech Stack:** dbt 1.12.0-rc2, adapter postgres 1.10.2, PostgreSQL (server đích `ecom_data_etl`), Python venv tại `D:\PTDL\DBT_postgre\venv`.

## Global Constraints

- Tên cột giữ **nguyên văn** như Power BI, kể cả dấu tiếng Việt và chữ hoa: `"Mẫu gửi"`, `"PIC"`, `"Team"`, `"Vị trí"`, `"View"`. Trong SQL phải bọc dấu ngoặc kép.
- Grain bắt buộc: **1 dòng / `video_id`**. Chỉ giữ video có **ít nhất 1 dòng `duration_date > 0`**.
- `so_don` = `sum(count_order)`, `"View"` = `sum(vv)` tính trên **TẤT CẢ** dòng của video, **KHÔNG** lọc `duration_date`. Cast `::bigint`.
- Quy tắc chọn dòng đại diện: `time` nhỏ nhất trong các dòng `duration_date > 0`; nếu vẫn nhiều dòng → `max(cột)` cho deterministic.
- `materialized='table'`. **KHÔNG dùng incremental** (tổng theo video trên toàn lịch sử ⇒ incremental theo cửa sổ ngày sẽ sai số).
- `pre_hook=["set work_mem = '256MB'", "set jit = off"]` — giống `mart_data`/`mart_data_agg`.
- **Không sửa** `mart_data`, `mart_data_agg`, staging/intermediate, `el/load_raw.py`.
- Mọi lệnh `dbt` phải chạy trong thư mục `D:\PTDL\DBT_postgre\dwh_project` sau khi đã nạp biến môi trường bằng `. .\load_connections.ps1` (dot-source, có dấu chấm + khoảng trắng ở đầu). Không nạp thì dbt báo `Env var required but not provided: 'DEST_HOST'`.

## File Structure

| File | Trách nhiệm |
|---|---|
| `dwh_project/models/marts/mart_new_video.sql` *(tạo mới)* | Toàn bộ logic dựng bảng: dedupe + tính `so_don`/`"View"`. |
| `dwh_project/models/marts/_mart_new_video.yml` *(tạo mới)* | Mô tả model, data tests (`not_null`, `unique` trên `video_id`), 4 unit tests. |
| `dwh_project/RUNBOOK_marts.md` *(sửa)* | Thêm `mart_new_video` vào lệnh build. |

Đặt YAML riêng (không nhồi vào `_mart_data.yml` đang có 5 unit test) để mỗi file một trách nhiệm.

---

### Task 1: Model `mart_new_video` + tests

**Files:**
- Create: `dwh_project/models/marts/mart_new_video.sql`
- Create: `dwh_project/models/marts/_mart_new_video.yml`

**Interfaces:**
- Consumes: `ref('mart_data')` — model incremental sẵn có ở `dwh_project/models/marts/mart_data.sql`. Các cột dùng tới: `video_id` (text), `"time"` (date), `creator_name` (text), `"Mẫu gửi"` (text), `brand` (text), `"PIC"` (text), `"Team"` (text), `prod_contain` (text), `prod_contain_combo` (text), `"Vị trí"` (text), `vv` (bigint), `count_order` (bigint), `duration_date` (int).
- Produces: bảng `marts.mart_new_video` với 12 cột: `video_id` (text), `"time"` (date), `creator_name`, `"Mẫu gửi"`, `brand`, `"PIC"`, `"Team"`, `prod_contain`, `prod_contain_combo`, `"Vị trí"` (đều text), `so_don` (bigint), `"View"` (bigint).

- [ ] **Step 1: Viết 4 unit test (sẽ fail vì model chưa tồn tại)**

Tạo `dwh_project/models/marts/_mart_new_video.yml` với nội dung:

```yaml
version: 2

models:
  - name: mart_new_video
    description: >
      1 dòng / video_id — tái tạo calculated table `table_new_video` của
      MVA_VideoAFF_(new_agg).pbix (SUMMARIZE 10 cột + 2 cột so_don/View), nhưng ĐÃ
      dedupe về 1 dòng mỗi video (chọn dòng có time nhỏ nhất) nên KHÔNG cộng đôi
      số đơn / số view như bản DAX. Chỉ gồm video có ít nhất 1 dòng duration_date > 0.
    columns:
      - name: video_id
        description: "Khóa — đúng 1 dòng mỗi video."
        data_tests: [not_null, unique]
      - name: time
        description: "time nhỏ nhất trong các dòng duration_date > 0 của video."
      - name: so_don
        description: "SUM(count_order) trên TOÀN BỘ snapshot của video, kể cả dòng duration_date <= 0."
      - name: View
        description: "SUM(vv) trên TOÀN BỘ snapshot của video, kể cả dòng duration_date <= 0."

unit_tests:
  # ── 1: dedupe theo min(time) + totals cộng qua các snapshot ─────
  - name: ut_new_video_dedupe_min_time
    description: "2 dòng duration>0 khác time -> 1 dòng; dims lấy từ dòng time nhỏ nhất; so_don/View cộng cả 2 dòng."
    model: mart_new_video
    given:
      - input: ref('mart_data')
        rows:
          - {video_id: "v1", time: "2025-03-10", creator_name: "a", "Mẫu gửi": "mau1", brand: "DHC", "PIC": "P1", "Team": "T1", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "top", vv: 100, count_order: 1, duration_date: 7}
          - {video_id: "v1", time: "2025-03-15", creator_name: "a", "Mẫu gửi": "mau2", brand: "DHC", "PIC": "P2", "Team": "T2", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "mid", vv: 200, count_order: 2, duration_date: 7}
    expect:
      rows:
        - {video_id: "v1", time: "2025-03-10", "Mẫu gửi": "mau1", "PIC": "P1", "Team": "T1", "Vị trí": "top", so_don: 3, "View": 300}

  # ── 2: tie-break khi cùng min(time) ────────────────────────────
  - name: ut_new_video_tiebreak
    description: "Cùng min(time) nhưng khác PIC -> vẫn 1 dòng, lấy max() cho deterministic (Binh > Anh)."
    model: mart_new_video
    given:
      - input: ref('mart_data')
        rows:
          - {video_id: "v1", time: "2025-03-10", creator_name: "a", "Mẫu gửi": "m", brand: "DHC", "PIC": "Anh", "Team": "T1", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "top", vv: 10, count_order: 1, duration_date: 7}
          - {video_id: "v1", time: "2025-03-10", creator_name: "a", "Mẫu gửi": "m", brand: "DHC", "PIC": "Binh", "Team": "T1", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "top", vv: 20, count_order: 2, duration_date: 7}
    expect:
      rows:
        - {video_id: "v1", time: "2025-03-10", "PIC": "Binh", so_don: 3, "View": 30}

  # ── 3: dòng duration<=0 KHÔNG làm dims nhưng VẪN cộng vào totals ─
  - name: ut_new_video_totals_include_all
    description: "Dòng duration_date <= 0 (time sớm hơn) không được chọn làm dims, nhưng vẫn cộng vào so_don/View — đúng all() của DAX."
    model: mart_new_video
    given:
      - input: ref('mart_data')
        rows:
          - {video_id: "v1", time: "2025-03-10", creator_name: "a", "Mẫu gửi": "m", brand: "DHC", "PIC": "P1", "Team": "T1", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "top", vv: 100, count_order: 1, duration_date: 7}
          - {video_id: "v1", time: "2025-03-05", creator_name: "a", "Mẫu gửi": "m", brand: "DHC", "PIC": "P9", "Team": "T9", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "bot", vv: 50, count_order: 5, duration_date: -1}
    expect:
      rows:
        - {video_id: "v1", time: "2025-03-10", "PIC": "P1", "Vị trí": "top", so_don: 6, "View": 150}

  # ── 4: loại video không có dòng duration>0 nào ──────────────────
  - name: ut_new_video_exclude_no_valid_row
    description: "Video chỉ có dòng duration_date <= 0 thì không xuất hiện trong bảng."
    model: mart_new_video
    given:
      - input: ref('mart_data')
        rows:
          - {video_id: "v1", time: "2025-03-10", creator_name: "a", "Mẫu gửi": "m", brand: "DHC", "PIC": "P1", "Team": "T1", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "top", vv: 100, count_order: 1, duration_date: 7}
          - {video_id: "v2", time: "2025-03-11", creator_name: "b", "Mẫu gửi": "m", brand: "DHC", "PIC": "P2", "Team": "T2", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "top", vv: 999, count_order: 9, duration_date: -1}
    expect:
      rows:
        - {video_id: "v1", time: "2025-03-10", so_don: 1, "View": 100}
```

- [ ] **Step 2: Chạy test để xác nhận FAIL**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt test -s "mart_new_video,test_type:unit"
```

Expected: **thất bại ở bước parse** vì YAML khai báo unit test cho model `mart_new_video` chưa tồn tại — dbt in `Compilation Error` / `Parsing Error` kèm tên `mart_new_video`. Câu chữ có thể khác chút theo phiên bản; điều cần thấy là dbt **không chạy được** test vì model chưa có (chưa PASS gì cả).

- [ ] **Step 3: Viết model**

Tạo `dwh_project/models/marts/mart_new_video.sql`:

```sql
-- Bảng 1 dòng/video: tái tạo calculated table `table_new_video` của Power BI
-- (MVA_VideoAFF_(new_agg).pbix). DAX gốc:
--   CALCULATETABLE(SUMMARIZE(postgre_data_detail, <10 cột>), duration_date > 0)
--   so_don = CALCULATE(SUM(count_order), video_id = _vid, all())
--   View   = CALCULATE(SUM(vv),          video_id = _vid, all())
-- `all()` bỏ MỌI filter => tổng trên TOÀN BỘ snapshot của video, kể cả duration_date <= 0.
-- (Đã kiểm chứng vv/count_order KHÔNG lũy kế mà phát sinh theo ngày => sum là tổng đúng.)
--
-- KHÁC Power BI (có chủ ý): DAX giữ grain 10 cột nên 283 video_id có 2+ dòng do thuộc
-- tính đổi giữa các snapshot; vì so_don/View gán theo video_id nên measure Số đơn/Số view
-- bị CỘNG ĐÔI. Ở đây dedupe: lấy dòng có time nhỏ nhất trong các dòng duration_date > 0;
-- nếu vẫn nhiều dòng (72 video) -> max(cột) cho deterministic (idiom pic_pick/vm_pick
-- trong mart_data).
--
-- HIỆU NĂNG: mart_data ~2GB và server nghẽn disk I/O, nên chỉ quét MỘT lần —
-- window tính _min_time rồi group by video_id, thay vì 2 CTE (dims + totals) rồi join.
{{ config(
    materialized='table',
    pre_hook=["set work_mem = '256MB'", "set jit = off"]
) }}

with base as (
    select
        video_id, "time", creator_name, "Mẫu gửi", brand, "PIC", "Team",
        prod_contain, prod_contain_combo, "Vị trí",
        vv, count_order, duration_date,
        min("time") filter (where duration_date > 0) over (partition by video_id) as _min_time
    from {{ ref('mart_data') }}
)

select
    video_id,
    min("time") filter (where duration_date > 0)                                    as "time",
    max(creator_name)       filter (where duration_date > 0 and "time" = _min_time) as creator_name,
    max("Mẫu gửi")          filter (where duration_date > 0 and "time" = _min_time) as "Mẫu gửi",
    max(brand)              filter (where duration_date > 0 and "time" = _min_time) as brand,
    max("PIC")              filter (where duration_date > 0 and "time" = _min_time) as "PIC",
    max("Team")             filter (where duration_date > 0 and "time" = _min_time) as "Team",
    max(prod_contain)       filter (where duration_date > 0 and "time" = _min_time) as prod_contain,
    max(prod_contain_combo) filter (where duration_date > 0 and "time" = _min_time) as prod_contain_combo,
    max("Vị trí")           filter (where duration_date > 0 and "time" = _min_time) as "Vị trí",
    (sum(count_order))::bigint as so_don,
    (sum(vv))::bigint          as "View"
from base
group by video_id
having count(*) filter (where duration_date > 0) > 0
```

- [ ] **Step 4: Chạy unit test để xác nhận PASS**

Chỉ chạy **unit test** (bảng chưa build nên data test `unique`/`not_null` chưa chạy được — selector `test_type:unit` loại chúng ra):

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt test -s "mart_new_video,test_type:unit"
```

Expected: `Done. PASS=4 WARN=0 ERROR=0 SKIP=0` với 4 dòng PASS: `ut_new_video_dedupe_min_time`, `ut_new_video_tiebreak`, `ut_new_video_totals_include_all`, `ut_new_video_exclude_no_valid_row`.

**Nếu gặp lỗi `'None' has no attribute 'database'`:** đó là do unit test chạm vào model incremental. Thêm khối này vào **từng** unit test (ngay dưới dòng `model: mart_new_video`), rồi chạy lại:

```yaml
    overrides:
      macros:
        is_incremental: false
```

- [ ] **Step 5: Commit**

```bash
cd /d/PTDL/DBT_postgre && git add dwh_project/models/marts/mart_new_video.sql dwh_project/models/marts/_mart_new_video.yml && git commit -m "feat(marts): thêm mart_new_video (1 dòng/video, tái tạo table_new_video của PBI)"
```

---

### Task 2: Build trên dữ liệu thật + đối chiếu số + cập nhật runbook

**Files:**
- Modify: `dwh_project/RUNBOOK_marts.md` (mục mô tả đầu file, và 2 khối lệnh ở §1 và §2)

**Interfaces:**
- Consumes: bảng `marts.mart_new_video` do Task 1 tạo ra.
- Produces: không có artifact code mới; kết quả là bảng đã build trên server và runbook đã cập nhật.

- [ ] **Step 1: Build model trên dữ liệu thật**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt build -s mart_new_video
```

Expected: `OK created sql table model marts.mart_new_video ... [SELECT 60668 in ~20-120s]`, và `unique_mart_new_video_video_id` + `not_null_mart_new_video_video_id` đều PASS. Thời gian dao động theo trạng thái cache đĩa của server (đo được 18,6s khi cache nóng).

- [ ] **Step 2: Đối chiếu số với giá trị kỳ vọng**

Chạy script sau (Bash, từ `D:\PTDL\DBT_postgre\dwh_project`):

```bash
cd /d/PTDL/DBT_postgre/dwh_project && cat > /tmp/verify_nv.py <<'PY'
import os, sys, psycopg2
sys.stdout.reconfigure(encoding="utf-8")
def load_env(p):
    for line in open(p, encoding="utf-8"):
        line=line.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        k,v=line.split("=",1); v=v.strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "'\"": v=v[1:-1]
        os.environ.setdefault(k.strip(), v)
load_env("connections.env")
c=psycopg2.connect(host=os.environ["DEST_HOST"],port=int(os.getenv("DEST_PORT","5432")),
    user=os.environ["DEST_USER"],password=os.environ["DEST_PASSWORD"],dbname=os.environ["DEST_DB"])
c.autocommit=True; cur=c.cursor()
def q(s):
    cur.execute(s); return cur.fetchall()
rows, vids = q("select count(*), count(distinct video_id) from marts.mart_new_video")[0]
sd, vw = q('select sum(so_don), sum("View") from marts.mart_new_video')[0]
nulls = q('select count(*) from marts.mart_new_video where "time" is null or creator_name is null')[0][0]
print(f"dòng                = {rows:,}      (kỳ vọng 60,668)")
print(f"distinct video_id   = {vids:,}      (phải BẰNG số dòng)")
print(f"sum(so_don)         = {sd:,}     (kỳ vọng 143,572)")
print(f'sum("View")         = {vw:,}  (kỳ vọng 437,454,229)')
print(f"dòng NULL time/creator = {nulls}   (kỳ vọng 0)")
print("\nGRAIN OK" if rows == vids else "\n*** LỖI: grain KHÔNG phải 1 dòng/video ***")
c.close()
PY
/d/PTDL/DBT_postgre/venv/Scripts/python.exe /tmp/verify_nv.py
```

Expected:

```
dòng                = 60,668      (kỳ vọng 60,668)
distinct video_id   = 60,668      (phải BẰNG số dòng)
sum(so_don)         = 143,572     (kỳ vọng 143,572)
sum("View")         = 437,454,229  (kỳ vọng 437,454,229)
dòng NULL time/creator = 0   (kỳ vọng 0)

GRAIN OK
```

**Bắt buộc:** `dòng` phải BẰNG `distinct video_id` — đây là bất biến của thiết kế. Nếu lệch thì dừng lại, không đi tiếp.

**Lưu ý về 3 con số kỳ vọng:** chúng được đo ngày 2026-07-28 khi `marts.mart_data` có 5.047.709 dòng. Nếu `mart_data` đã được nạp thêm dữ liệu mới (chạy `load_raw.py` + build lại) thì cả 3 con số sẽ **tăng nhẹ** — đó là bình thường, KHÔNG phải lỗi. Chỉ cần: (a) `dòng == distinct video_id`, (b) `NULL time/creator == 0`, (c) số dòng cùng cỡ ~60-61k. Riêng bất biến (a) và (b) thì luôn phải đúng.

- [ ] **Step 3: Cập nhật RUNBOOK_marts.md**

Sửa 3 chỗ trong `dwh_project/RUNBOOK_marts.md`.

(a) Thêm dòng mô tả model mới vào danh sách đầu file — chèn ngay sau dòng mô tả `mart_data_agg`:

```markdown
- `mart_new_video`: materialized = **table** → 1 dòng / `video_id`, dựng lại toàn bộ từ `mart_data`.
  Tái tạo calculated table `table_new_video` của Power BI (đã dedupe, không cộng đôi số đơn/view).
  Không dùng incremental vì `so_don`/`View` là tổng theo video trên toàn lịch sử.
```

(b) Trong §1 (INCREMENTAL), thay khối lệnh:

```powershell
dbt build -s mart_data mart_data_agg
```

thành:

```powershell
dbt build -s mart_data+
```

kèm dòng giải thích ngay dưới khối lệnh:

```markdown
> `mart_data+` = `mart_data` và **mọi model hạ nguồn** (`mart_data_agg`, `mart_new_video`) — dbt tự xếp thứ tự.
```

(c) Trong §2 (FULL-REFRESH), thay khối lệnh:

```powershell
dbt build -s mart_data mart_data_agg --full-refresh
```

thành:

```powershell
dbt build -s mart_data+ --full-refresh
```

- [ ] **Step 4: Chạy lại toàn bộ nhóm marts để xác nhận không phá gì**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt build -s mart_data+
```

Expected: `Completed successfully` với `TOTAL=14`, gồm:
- **3 model OK**: `mart_data` (incremental), `mart_data_agg`, `mart_new_video`
- **9 unit test PASS**: 5 của `mart_data` (`ut_mart_prod_and_loaivideo`, `ut_mart_duration`, `ut_mart_phanloai`, `ut_mart_pic_team_vitri_maugui`, `ut_mart_creator_case_insensitive`) + 4 của `mart_new_video`
- **2 data test PASS**: `unique_mart_new_video_video_id`, `not_null_mart_new_video_video_id`

Không có ERROR/FAIL. (`mart_data+` chỉ chọn `mart_data` và hạ nguồn, nên staging/intermediate không nằm trong lần chạy này.)

- [ ] **Step 5: Commit**

```bash
cd /d/PTDL/DBT_postgre && git add dwh_project/RUNBOOK_marts.md && git commit -m "docs(runbook): thêm mart_new_video, dùng selector mart_data+ cho nhóm marts"
```

---

## Việc phía Power BI (ngoài phạm vi plan này)

Sau khi bảng đã có trên Postgres, để dashboard dùng nó thì trong `MVA_VideoAFF_(new_agg).pbix` cần:

1. Đổi `table_new_video` từ **calculated table (DAX)** sang **M query** đọc bảng mới, theo đúng mẫu của `postgre_data_detail`:
   ```
   let
       Source = Value.NativeQuery(
           PostgreSQL.Database("postgresql-pavietnam.belief.vn", "ecom_data_etl"),
           "SELECT video_id,""time"",creator_name,""Mẫu gửi"",brand,""PIC"",""Team"",prod_contain,prod_contain_combo,""Vị trí"",so_don,""View"" FROM marts.mart_new_video",
           null, [EnableFolding=true]),
       #"Changed Type" = Table.TransformColumnTypes(Source,{{"time", type date}})
   in
       #"Changed Type"
   ```
2. **Xóa 2 calculated column** `so_don` và `View` (giờ đã là cột thật trong bảng).
3. **Giữ nguyên 6 measure** (`Số đơn`, `DK_sodon`, `Số view`, `Số creator thỏa mãn`, `DK_so_video`, `so_video_new_table`) — chúng phụ thuộc slicer/parameter nên phải ở lại Power BI.
4. `list_video_new` (`VALUES(table_new_video[video_id])`) vẫn hoạt động bình thường, không cần sửa.
5. **Thông báo người dùng báo cáo**: `Số đơn` giảm 5.950 (149.522 → 143.572) và `Số view` giảm 5.710.725 (443.164.954 → 437.454.229) do bỏ cộng đôi 283 video. Đây là sửa lỗi, không phải mất dữ liệu.