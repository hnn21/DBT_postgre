# `campaign_id` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lan truyền `campaign_id` từ raw `MVA_KOC_KOL_send_sample` xuống `mart_data`, để có lát cắt campaign ở 2 bảng báo cáo `mart_data_agg` và `mart_new_video`.

**Architecture:** `campaign_id` nằm ở bảng gửi mẫu, nối với video qua `(creator_name ↔ koc_kol, prod_contain, khoảng hiệu lực của lần gửi mẫu)`. Nó trở thành **cột pick thứ 4** của cụm `vm_pick` trong `mart_data` — dùng y hệt điều kiện đang áp cho `Vị trí`/`Mẫu gửi`/`nguon_yeu_cau`. Hai bảng hạ nguồn chỉ việc mang cột đó xuống: `mart_data_agg` thêm vào `group by` (thành 1 chiều), `mart_new_video` thêm 1 dim `max(...) filter (...)`.

**Tech Stack:** dbt 1.12.0-rc2, adapter postgres 1.10.2, PostgreSQL (`ecom_data_etl`), MySQL nguồn, Python venv tại `D:\PTDL\DBT_postgre\venv`.

## Global Constraints

- Kiểu dữ liệu `campaign_id` = **`text`** ở mọi tầng. Không ép sang số, không `trim`, không `nullif`.
- Giữ nguyên **`NULL`** khi video không thuộc campaign nào. **KHÔNG** thay bằng nhãn kiểu `'Không campaign'`.
- Tên cột giữ nguyên `campaign_id` (chữ thường, không dấu) ở mọi tầng — không cần bọc ngoặc kép trong SQL.
- Quy tắc gắn campaign vào video **bắt buộc** dùng lại đúng điều kiện của `vm_ranked`: `lower(s.koc_kol) = lower(k.creator_name)` AND `s.prod_contain = k.prod_contain` AND `s.sl > 0` AND `s.ngay_duyet_mau <= k.time` AND `k.time <= s.ngay_ket_thuc`.
- **KHÔNG sửa** `models/intermediate/int_send_sample.sql` — nó dùng `select ss.*` nên cột tự đi qua.
- **KHÔNG** chạy `--full-refresh` (không cần; xem lý do ở spec §1.1(b)).
- Mọi lệnh `dbt` và `python el\...` phải chạy trong `D:\PTDL\DBT_postgre\dwh_project` sau khi nạp biến môi trường bằng `. .\load_connections.ps1` (dot-source — có dấu chấm + khoảng trắng ở đầu). Không nạp thì dbt báo `Env var required but not provided: 'DEST_HOST'`.
- `dbt build` **KHÔNG** tự nạp MySQL → raw. Phải chạy `python el\load_raw.py` trước.

## File Structure

| File | Trách nhiệm |
|---|---|
| `dwh_project/el/load_raw.py` *(sửa)* | Kéo `campaign_id` từ MySQL + tự đồng bộ cột mới sang Postgres |
| `dwh_project/models/staging/stg_send_sample.sql` *(sửa)* | Cho `campaign_id` đi qua tầng staging |
| `dwh_project/models/marts/mart_data.sql` *(sửa)* | **Tính** — gắn `campaign_id` vào từng dòng video |
| `dwh_project/models/marts/mart_data_agg.sql` *(sửa)* | Thêm `campaign_id` thành 1 chiều group by |
| `dwh_project/models/marts/mart_new_video.sql` *(sửa)* | Thêm `campaign_id` thành 1 thuộc tính của video |
| `dwh_project/models/marts/_mart_data.yml` *(sửa)* | Khai báo cột + unit test cho mart_data & mart_data_agg |
| `dwh_project/models/marts/_mart_new_video.yml` *(sửa)* | Khai báo cột + mở rộng unit test |
| `dwh_project/RUNBOOK_marts.md` *(sửa)* | Ghi thứ tự chạy EL trước dbt |

---

### Task 1: EL kéo `campaign_id` về `raw.send_sample` + staging cho đi qua

**Files:**
- Modify: `dwh_project/el/load_raw.py`
- Modify: `dwh_project/models/staging/stg_send_sample.sql`

**Interfaces:**
- Consumes: bảng MySQL `MVA_KOC_KOL_send_sample`, cột `campaign_id` kiểu `text`.
- Produces: `raw.send_sample.campaign_id` (text) và `staging.stg_send_sample.campaign_id` (text). Các task sau dùng qua `ref('int_send_sample')` → `s.campaign_id`.

- [ ] **Step 1: Thêm `campaign_id` vào câu SELECT của MySQL**

Trong `dwh_project/el/load_raw.py`, sửa entry `"send_sample"` của dict `QUERIES` — thêm `` `campaign_id` `` vào cuối danh sách cột:

```python
    "send_sample": """
        SELECT `Ngày duyệt mẫu` AS ngay_duyet_mau, `KOC/KOL` AS koc_kol, `PIC` AS pic,
               `Phân loại Creator` AS phan_loai_creator, `Nguồn yêu cầu` AS nguon_yeu_cau,
               `Tên sản phẩm` AS ten_san_pham, `SL` AS sl, `sheet`, `Số video` AS so_video,
               `MST/CCCD` AS mst_cccd, `Mã đơn hàng` AS ma_don_hang, `Vị trí` AS vi_tri,
               `cost`, `SDT` AS sdt, `campaign_id`
        FROM MVA_KOC_KOL_send_sample""",
```

- [ ] **Step 2: Cho `full_load()` tự thêm cột còn thiếu**

Vẫn trong `dwh_project/el/load_raw.py`, trong hàm `full_load()`, chèn đoạn đồng bộ cột **giữa** dòng `CREATE TABLE IF NOT EXISTS` và dòng `TRUNCATE`. Sau khi sửa, khối đó trông như sau:

```python
        pg.execute(f'CREATE TABLE IF NOT EXISTS "{RAW}"."{tbl}" (' + ", ".join(f'"{c}" text' for c in cols) + ')')
        # Bảng có thể đã tồn tại từ trước với ÍT cột hơn (nguồn MySQL vừa thêm cột mới).
        # CREATE IF NOT EXISTS KHÔNG thêm cột -> COPY sẽ lỗi
        # 'column "..." of relation "..." does not exist'. Nên đồng bộ trước:
        # thêm mọi cột còn thiếu. CHỈ THÊM — không xoá, không đổi kiểu.
        pg.execute(
            "select column_name from information_schema.columns "
            "where table_schema = %s and table_name = %s",
            (RAW, tbl),
        )
        have = {r[0] for r in pg.fetchall()}
        for c in cols:
            if c not in have:
                pg.execute(f'ALTER TABLE "{RAW}"."{tbl}" ADD COLUMN "{c}" text')
                print(f"  {tbl}: + thêm cột mới '{c}'", flush=True)
        pg.execute(f'TRUNCATE "{RAW}"."{tbl}"')
```

- [ ] **Step 3: Chạy EL để nạp `campaign_id` về Postgres**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; python el\load_raw.py --days 1
```

Expected: in ra dòng `  send_sample: + thêm cột mới 'campaign_id'`, rồi `raw.send_sample: 43,473 rows copied` (con số có thể xê dịch nếu nguồn thay đổi). `--days 1` để `performance_list` chỉ nạp 1 ngày cho nhanh — 3 bảng nhỏ (gồm `send_sample`) **luôn full reload** ở mọi chế độ.

- [ ] **Step 4: Kiểm chứng cột đã về đúng**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && cat > "C:/Users/admin/AppData/Local/Temp/claude/D--PTDL-DBT-postgre/25d1bfea-8675-4221-8812-ca2852a00c4e/scratchpad/v1.py" <<'PY'
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
cur.execute("""select count(*) from information_schema.columns
               where table_schema='raw' and table_name='send_sample'""")
print("số cột raw.send_sample =", cur.fetchone()[0], "(kỳ vọng 15)")
cur.execute("select count(*), count(nullif(trim(campaign_id),'')) from raw.send_sample")
tot, has = cur.fetchone()
print(f"tổng dòng = {tot:,} | có campaign_id = {has:,} (kỳ vọng ~1.332)")
cur.execute("select count(distinct nullif(trim(campaign_id),'')) from raw.send_sample")
print("số campaign khác nhau =", cur.fetchone()[0], "(kỳ vọng 12)")
c.close()
PY
/d/PTDL/DBT_postgre/venv/Scripts/python.exe "C:/Users/admin/AppData/Local/Temp/claude/D--PTDL-DBT-postgre/25d1bfea-8675-4221-8812-ca2852a00c4e/scratchpad/v1.py"
```

Expected:
```
số cột raw.send_sample = 15 (kỳ vọng 15)
tổng dòng = 43,473 | có campaign_id = 1,332 (kỳ vọng ~1.332)
số campaign khác nhau = 12 (kỳ vọng 12)
```

- [ ] **Step 5: Cho `campaign_id` đi qua staging**

Trong `dwh_project/models/staging/stg_send_sample.sql`, thêm `campaign_id` vào danh sách cột — sửa dòng `    sdt` thành 2 dòng:

```sql
    sdt,
    campaign_id
```

- [ ] **Step 6: Build staging và kiểm chứng**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt build -s stg_send_sample
```

Expected: `Completed successfully`, `PASS=3` — model `stg_send_sample` OK, data test `not_null_stg_send_sample_koc_kol` PASS, và unit test `ut_stg_send_sample_cleanup` (khai báo ở `models/staging/_stg_models.yml`) PASS. Unit test này không khai `campaign_id` trong input nên cột sẽ là NULL — không ảnh hưởng vì nó chỉ đối chiếu các cột được liệt kê ở `expect`.

- [ ] **Step 7: Commit**

```bash
cd /d/PTDL/DBT_postgre && git add dwh_project/el/load_raw.py dwh_project/models/staging/stg_send_sample.sql && git commit -m "feat(el): kéo campaign_id về raw.send_sample + tự đồng bộ cột mới"
```

---

### Task 2: Tính `campaign_id` trong `mart_data`

**Files:**
- Modify: `dwh_project/models/marts/mart_data.sql`
- Modify: `dwh_project/models/marts/_mart_data.yml`

**Interfaces:**
- Consumes: `ref('int_send_sample')` → cột `campaign_id` (text) do Task 1 tạo ra.
- Produces: `marts.mart_data.campaign_id` (text, cột cuối cùng của bảng). Task 3 dùng qua `ref('mart_data')`.

- [ ] **Step 1: Viết unit test (sẽ FAIL vì cột chưa tồn tại)**

Trong `dwh_project/models/marts/_mart_data.yml`, thêm test sau vào **cuối file** (sau test `ut_mart_creator_case_insensitive`):

```yaml

  # ── Nhóm 6: campaign_id theo cụm vm_pick ───────────────────────
  - name: ut_mart_campaign_id
    description: >
      campaign_id lấy từ CÙNG bản ghi gửi mẫu đã cho Vị trí/Mẫu gửi (cụm vm_pick).
      v1 lên sóng SAU ngày duyệt mẫu -> rơi vào khoảng hiệu lực -> nhận campaign '5'.
      v2 lên sóng TRƯỚC ngày duyệt mẫu -> không khớp -> campaign_id = NULL.
    model: mart_data
    overrides:
      macros:
        is_incremental: false
      vars:
        run_date: "2025-03-20"
    given:
      - input: ref('stg_performance_list')
        rows:
          - {video_id: "v1", time: "2025-03-10", product_name: "x", creator_name: "a"}
          - {video_id: "v2", time: "2025-03-01", product_name: "x", creator_name: "a"}
      - input: ref('stg_product_name_map')
        rows:
          - {video_id: "v1", product_contain: "kẽm", product_contain_combo: null}
          - {video_id: "v2", product_contain: "kẽm", product_contain_combo: null}
      - input: ref('int_send_sample')
        rows:
          - {koc_kol: "a", prod_contain: "kẽm", sl: 2, ngay_duyet_mau: "2025-03-05", ngay_ket_thuc: "2099-12-31", pic_rename: "Anh", team: "T1", vi_tri: "top", product_detail: "mẫu A", phan_loai_creator_fix: "S", campaign_id: "5"}
      - input: ref('int_valid_classification')
        rows:
          - {phan_loai_creator: "S"}
      - input: ref('videos_id_agency')
        rows: []
    expect:
      rows:
        - {video_id: "v1", campaign_id: "5", "Mẫu gửi": "mẫu A"}
        - {video_id: "v2", campaign_id: null, "Mẫu gửi": null}
```

- [ ] **Step 2: Chạy test để xác nhận FAIL**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt test -s "mart_data,test_type:unit"
```

Expected: `ut_mart_campaign_id` **FAIL**, thông báo dạng `column "campaign_id" does not exist` hoặc bảng so sánh lệch vì thiếu cột. 5 test cũ vẫn PASS.

- [ ] **Step 3: Thêm `campaign_id` vào 5 vị trí trong `mart_data.sql`**

**(3a)** Thêm `on_schema_change` vào `config()` — sửa khối `{{ config(...) }}` ở đầu file thành:

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['video_id', 'date_file_excel'],
    on_schema_change='append_new_columns',
    pre_hook=["set work_mem = '256MB'", "set jit = off", "set enable_mergejoin = off"],
    post_hook=["set enable_mergejoin = on"]
) }}
```

**(3b)** CTE `vm_ranked` — thêm `s.campaign_id` vào select:

```sql
vm_ranked as (
    select k.creator_name, k.prod_contain, k.time, s.vi_tri, s.product_detail, s.nguon_yeu_cau, s.campaign_id, s.ngay_duyet_mau
    from keys_cpt k
    join send s
      on lower(s.koc_kol) = lower(k.creator_name)   -- khớp KHÔNG phân biệt hoa/thường (như DAX)
     and s.prod_contain = k.prod_contain
     and s.sl > 0
     and s.ngay_duyet_mau <= k.time
     and k.time <= s.ngay_ket_thuc
),
```

**(3c)** CTE `vm_pick` — thêm 1 dòng aggregate:

```sql
vm_pick as (
    select creator_name, prod_contain, time,
           max(vi_tri)         filter (where ngay_duyet_mau = mn) as "Vị trí",
           max(product_detail) filter (where ngay_duyet_mau = mn) as "Mẫu gửi",
           max(nguon_yeu_cau)  filter (where ngay_duyet_mau = mn) as nguon_yeu_cau,
           max(campaign_id)    filter (where ngay_duyet_mau = mn) as campaign_id
    from (
        select r.*, min(ngay_duyet_mau) over (partition by creator_name, prod_contain, time) as mn
        from vm_ranked r
    ) z
    group by creator_name, prod_contain, time
),
```

**(3d)** CTE `picks` — thêm 1 dòng, ngay sau `vm.nguon_yeu_cau as _nguon_yeu_cau`:

```sql
        vm.nguon_yeu_cau as _nguon_yeu_cau,
        vm.campaign_id   as _campaign_id
```

**(3e)** CTE `j` — thêm 1 dòng, ngay sau `pk._nguon_yeu_cau as _nguon_yeu_cau`:

```sql
        pk._nguon_yeu_cau               as _nguon_yeu_cau,
        pk._campaign_id                 as _campaign_id
```

**(3f)** CTE `final` — thêm 1 dòng, ngay sau `g._nguon_yeu_cau as nguon_yeu_cau`:

```sql
        g._nguon_yeu_cau as nguon_yeu_cau,
        g._campaign_id   as campaign_id
```

- [ ] **Step 4: Chạy test để xác nhận PASS**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt test -s "mart_data,test_type:unit"
```

Expected: `Done. PASS=6 WARN=0 ERROR=0` — 5 test cũ + `ut_mart_campaign_id` đều PASS.

- [ ] **Step 5: Khai báo cột trong YAML**

Trong `dwh_project/models/marts/_mart_data.yml`, mục `models:` → `- name: mart_data` → `columns:`, thêm vào cuối danh sách cột (sau mục `range_date`):

```yaml
      - name: campaign_id
        description: >
          Mã campaign của lần gửi mẫu mà video này rơi vào (cùng bản ghi đã cho
          Vị trí/Mẫu gửi/nguon_yeu_cau). NULL nếu video không khớp lần gửi mẫu nào
          hoặc lần gửi mẫu đó không thuộc campaign. Kiểu text.
```

- [ ] **Step 6: Commit**

```bash
cd /d/PTDL/DBT_postgre && git add dwh_project/models/marts/mart_data.sql dwh_project/models/marts/_mart_data.yml && git commit -m "feat(mart_data): tính campaign_id theo cụm vm_pick"
```

---

### Task 3: Đưa lát cắt campaign xuống 2 bảng báo cáo

**Files:**
- Modify: `dwh_project/models/marts/mart_data_agg.sql`
- Modify: `dwh_project/models/marts/mart_new_video.sql`
- Modify: `dwh_project/models/marts/_mart_data.yml`
- Modify: `dwh_project/models/marts/_mart_new_video.yml`

**Interfaces:**
- Consumes: `ref('mart_data')` → cột `campaign_id` (text) do Task 2 tạo ra.
- Produces: `marts.mart_data_agg.campaign_id` (text, nằm TRONG grain group by) và `marts.mart_new_video.campaign_id` (text, 1 giá trị/video).

- [ ] **Step 1: Mở rộng 2 unit test sẵn có (sẽ FAIL)**

**(1a)** Trong `dwh_project/models/marts/_mart_data.yml`, test `ut_agg_grain_dims_video`: thêm `campaign_id` vào **cả 5 dòng input** và **4 dòng expect**. Cho `v1` và `v2` campaign `"5"`, `v4` campaign `"8"` (để chứng minh campaign tách nhóm), `v3` để `null`:

```yaml
    given:
      - input: ref('mart_data')
        rows:
          - {video_id: "v1", time: "2025-03-10", brand: "DHC", creator_name: "a", duration_date: 7, range_date: 30, prod_contain: "kẽm", prod_contain_combo: "kẽm", "Ngày gửi mẫu": "2025-03-05", "Phân loại Creator": "S", "Group creator": "S", "PIC": "An", "Team": "T1", "Vị trí": "top", "Mẫu gửi": "m1", nguon_yeu_cau: "web", campaign_id: "5"}
          - {video_id: "v1", time: "2025-03-10", brand: "DHC", creator_name: "a", duration_date: 7, range_date: 30, prod_contain: "kẽm", prod_contain_combo: "kẽm", "Ngày gửi mẫu": "2025-03-05", "Phân loại Creator": "S", "Group creator": "S", "PIC": "An", "Team": "T1", "Vị trí": "top", "Mẫu gửi": "m1", nguon_yeu_cau: "web", campaign_id: "5"}
          - {video_id: "v2", time: "2025-03-10", brand: "DHC", creator_name: "b", duration_date: 7, range_date: 30, prod_contain: "kẽm", prod_contain_combo: "kẽm", "Ngày gửi mẫu": "2025-03-05", "Phân loại Creator": "S", "Group creator": "S", "PIC": "An", "Team": "T1", "Vị trí": "top", "Mẫu gửi": "m1", nguon_yeu_cau: "web", campaign_id: "5"}
          - {video_id: "v4", time: "2025-03-10", brand: "DHC", creator_name: "a", duration_date: 3, range_date: 30, prod_contain: "kẽm", prod_contain_combo: "kẽm", "Ngày gửi mẫu": "2025-03-05", "Phân loại Creator": "S", "Group creator": "S", "PIC": "An", "Team": "T1", "Vị trí": "top", "Mẫu gửi": "m1", nguon_yeu_cau: "web", campaign_id: "8"}
          - {video_id: "v3", time: "2025-03-10", brand: "DHC", creator_name: "c", duration_date: -1, range_date: null, prod_contain: "kẽm", prod_contain_combo: "kẽm", "Ngày gửi mẫu": null, "Phân loại Creator": "Organic", "Group creator": "Organic", "PIC": null, "Team": null, "Vị trí": null, "Mẫu gửi": null, nguon_yeu_cau: null, campaign_id: null}
    expect:
      rows:
        - {video_id: "v1", creator_name: "a", duration_date: 7, campaign_id: "5"}
        - {video_id: "v2", creator_name: "b", duration_date: 7, campaign_id: "5"}
        - {video_id: "v4", creator_name: "a", duration_date: 3, campaign_id: "8"}
        - {video_id: "v3", creator_name: "c", duration_date: -1, campaign_id: null}
```

**(1b)** Trong `dwh_project/models/marts/_mart_new_video.yml`, test `ut_new_video_dedupe_min_time`: thêm `campaign_id: "5"` vào **cả 2 dòng input** và vào dòng expect:

```yaml
    given:
      - input: ref('mart_data')
        rows:
          - {video_id: "v1", time: "2025-03-10", creator_name: "a", "Mẫu gửi": "mau1", brand: "DHC", "PIC": "P1", "Team": "T1", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "top", vv: 100, count_order: 1, video_revenue: 1000, nguon_yeu_cau: "web", campaign_id: "5", duration_date: 7}
          - {video_id: "v1", time: "2025-03-15", creator_name: "a", "Mẫu gửi": "mau2", brand: "DHC", "PIC": "P2", "Team": "T2", prod_contain: "kẽm", prod_contain_combo: "kẽm", "Vị trí": "mid", vv: 200, count_order: 2, video_revenue: 2000, nguon_yeu_cau: "web", campaign_id: "5", duration_date: 7}
    expect:
      rows:
        - {video_id: "v1", time: "2025-03-10", "Mẫu gửi": "mau1", "PIC": "P1", "Team": "T1", "Vị trí": "top", campaign_id: "5", so_don: 3, "View": 300, gmv: 3000}
```

- [ ] **Step 2: Chạy test để xác nhận FAIL**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt test -s "mart_data_agg,test_type:unit" "mart_new_video,test_type:unit"
```

Expected: `ut_agg_grain_dims_video` và `ut_new_video_dedupe_min_time` **FAIL** vì 2 model chưa có cột `campaign_id`.

- [ ] **Step 3: Thêm `campaign_id` vào `mart_data_agg.sql`**

**(3a)** Sửa `config()` thêm `on_schema_change`:

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='thang',
    on_schema_change='append_new_columns',
    pre_hook=["set work_mem = '256MB'", "set jit = off"]
) }}
```

**(3b)** Trong `select`, thêm `campaign_id` ngay sau dòng `    nguon_yeu_cau,`:

```sql
    nguon_yeu_cau,
    campaign_id,
    video_id,
```

**(3c)** Trong `group by`, thêm `campaign_id` ngay sau dòng `    nguon_yeu_cau,`:

```sql
    nguon_yeu_cau,
    campaign_id,
    video_id
```

- [ ] **Step 4: Thêm `campaign_id` vào `mart_new_video.sql`**

**(4a)** CTE `base` — thêm `campaign_id` vào danh sách cột:

```sql
with base as (
    select
        video_id, "time", creator_name, "Mẫu gửi", brand, "PIC", "Team",
        prod_contain, prod_contain_combo, "Vị trí", nguon_yeu_cau, campaign_id,
        vv, count_order, video_revenue, duration_date,
        min("time") filter (where duration_date > 0) over (partition by video_id) as _min_time
    from {{ ref('mart_data') }}
)
```

**(4b)** Trong `select` ngoài, thêm 1 dòng ngay sau dòng `nguon_yeu_cau`:

```sql
    max(nguon_yeu_cau)      filter (where duration_date > 0 and "time" = _min_time) as nguon_yeu_cau,
    max(campaign_id)        filter (where duration_date > 0 and "time" = _min_time) as campaign_id,
```

- [ ] **Step 5: Chạy test để xác nhận PASS**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt test -s "mart_data_agg,test_type:unit" "mart_new_video,test_type:unit"
```

Expected: `Done. PASS=7 WARN=0 ERROR=0` — 3 unit test của `mart_data_agg` + 4 của `mart_new_video`, tất cả PASS.

- [ ] **Step 6: Khai báo cột trong 2 YAML**

**(6a)** `dwh_project/models/marts/_mart_data.yml`, mục `- name: mart_data_agg` → `columns:`, thêm vào cuối:

```yaml
      - name: campaign_id
        description: >
          Mã campaign — nằm TRONG grain (1 chiều group by). Lọc campaign_id rồi
          count(distinct video_id) để ra số video của campaign. NULL = video không
          thuộc campaign nào.
```

**(6b)** `dwh_project/models/marts/_mart_new_video.yml`, mục `columns:`, thêm vào cuối:

```yaml
      - name: campaign_id
        description: >
          Mã campaign của lần gửi mẫu mà video rơi vào, lấy tại dòng time nhỏ nhất
          (cùng quy tắc với PIC/Vị trí/Mẫu gửi). NULL = không thuộc campaign nào.
```

- [ ] **Step 7: Commit**

```bash
cd /d/PTDL/DBT_postgre && git add dwh_project/models/marts/mart_data_agg.sql dwh_project/models/marts/mart_new_video.sql dwh_project/models/marts/_mart_data.yml dwh_project/models/marts/_mart_new_video.yml && git commit -m "feat(marts): thêm lát cắt campaign_id cho mart_data_agg + mart_new_video"
```

---

### Task 4: Build thật, đối chiếu số, cập nhật runbook

**Files:**
- Modify: `dwh_project/RUNBOOK_marts.md`

**Interfaces:**
- Consumes: toàn bộ thay đổi của Task 1–3.
- Produces: 3 bảng marts trên Postgres đã có cột `campaign_id`; runbook ghi rõ thứ tự chạy.

- [ ] **Step 1: Build cả chuỗi từ staging xuống 3 marts**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt build -s stg_send_sample+
```

Expected: `Completed successfully`, không có ERROR/FAIL. Selector `stg_send_sample+` phủ đúng chuỗi phụ thuộc: `stg_send_sample` → `int_send_sample`, `int_valid_classification` → `mart_data` → `mart_data_agg`, `mart_new_video`. Thời gian dao động mạnh theo trạng thái cache đĩa của server (`mart_data` incremental từng đo 276s).

- [ ] **Step 2: Đối chiếu số trên dữ liệu thật**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && cat > "C:/Users/admin/AppData/Local/Temp/claude/D--PTDL-DBT-postgre/25d1bfea-8675-4221-8812-ca2852a00c4e/scratchpad/v4.py" <<'PY'
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
c.autocommit=True; cur=c.cursor(); cur.execute("set work_mem='128MB'")
def q(s):
    cur.execute(s); return cur.fetchall()
ok = True
for t in ("mart_data", "mart_data_agg", "mart_new_video"):
    n = q(f"""select count(*) from information_schema.columns
              where table_schema='marts' and table_name='{t}' and column_name='campaign_id'""")[0][0]
    print(f"{t:16} có cột campaign_id: {'CÓ' if n else '*** KHÔNG ***'}")
    ok = ok and n == 1
print()
for t in ("mart_data", "mart_data_agg", "mart_new_video"):
    r = q(f"""select count(*) filter (where campaign_id is not null),
                     count(distinct campaign_id) from marts.{t}""")[0]
    print(f"{t:16} dòng có campaign = {r[0]:,} | số campaign khác nhau = {r[1]}")
print()
v = q("""select count(distinct video_id) from marts.mart_new_video where campaign_id is not null""")[0][0]
print(f"mart_new_video: số video có campaign = {v:,}  (kỳ vọng > 0 và <= 3.487)")
g = q("select count(*), count(distinct video_id) from marts.mart_new_video")[0]
print(f"mart_new_video: {g[0]:,} dòng / {g[1]:,} video  -> grain 1 dòng/video: {'OK' if g[0]==g[1] else '*** VỠ ***'}")
print("\nKẾT LUẬN:", "ĐẠT" if ok and v > 0 and g[0]==g[1] else "*** CÓ VẤN ĐỀ — dừng lại kiểm tra ***")
c.close()
PY
/d/PTDL/DBT_postgre/venv/Scripts/python.exe "C:/Users/admin/AppData/Local/Temp/claude/D--PTDL-DBT-postgre/25d1bfea-8675-4221-8812-ca2852a00c4e/scratchpad/v4.py"
```

Expected: cả 3 bảng đều báo `CÓ` cột `campaign_id`; `mart_new_video` có `> 0` video mang campaign và không quá 3.487; grain `mart_new_video` vẫn `OK` (số dòng = số video); dòng cuối in `KẾT LUẬN: ĐẠT`.

Nếu `mart_data` báo `*** KHÔNG ***`: `on_schema_change='append_new_columns'` chưa được thêm hoặc gõ sai — sửa rồi chạy lại Step 1.

- [ ] **Step 3: Cập nhật runbook**

Trong `dwh_project/RUNBOOK_marts.md`, thêm ghi chú vào phần đầu file (ngay dưới dòng mô tả mục đích), nội dung:

```markdown
> ⚠️ `campaign_id` đến từ bảng gửi mẫu ở MySQL. `dbt build` **KHÔNG** tự nạp MySQL → raw,
> nên muốn campaign mới xuất hiện thì phải chạy `python el\load_raw.py` TRƯỚC, rồi mới `dbt build`.
> Bỏ qua bước này thì `campaign_id` vẫn là dữ liệu cũ mà không có lỗi nào báo ra.
```

- [ ] **Step 4: Chạy lại toàn bộ test suite để chắc không phá gì**

```bash
cd /d/PTDL/DBT_postgre/dwh_project && . .\load_connections.ps1 ; dbt test
```

Expected: `Completed successfully`, không có FAIL/ERROR. Tổng số test = số hiện có + 1 (`ut_mart_campaign_id` mới thêm).

- [ ] **Step 5: Commit**

```bash
cd /d/PTDL/DBT_postgre && git add dwh_project/RUNBOOK_marts.md && git commit -m "docs(runbook): nhắc chạy load_raw.py trước dbt để campaign_id được cập nhật"
```

---

## Việc phía Power BI (ngoài phạm vi plan này)

Sau khi 3 bảng đã có `campaign_id`, phía `.pbix` cần tự sửa:

1. **`postgre_data_agg`** và **`postgre_data_detail`**: M query đang `SELECT` liệt kê **cột tường minh** — phải thêm `campaign_id` vào danh sách, nếu không cột sẽ không về Power BI (không báo lỗi, chỉ thiếu cột).
2. Bảng đọc từ `mart_new_video`: tương tự, thêm `campaign_id` vào M query.
3. Dùng `campaign_id` làm slicer/chiều. Đếm số video theo campaign ở `mart_data_agg` phải dùng `DISTINCTCOUNT(video_id)` — **không** cộng số dòng.
4. Lưu ý độ phủ: chỉ video lên sóng từ ~2026-08-15 mới có campaign (tối đa ~3.487/213.285 video). Phần `NULL` là đúng bản chất, không phải thiếu dữ liệu.
