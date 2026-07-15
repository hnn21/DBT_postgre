# MVA_VideoAFF `data` Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tái tạo bảng `data` của Power BI `MVA_VideoAFF.pbix` (cột gốc + 14 cột tính toán) thành bảng rộng `mart_data` trên PostgreSQL bằng dbt, nguồn raw từ MySQL.

**Architecture:** EL nhẹ (Python) load 4 bảng MySQL → schema `raw` trên Postgres. dbt phân tầng staging (view) → intermediate → marts (`mart_data`, table). `videos_id_agency` là seed tĩnh; `int_valid_classification` suy diễn từ send_sample. Kiểm thử bằng dbt unit tests (mock input, chạy trên Postgres, không cần MySQL) + đối chiếu cuối với Power BI qua MCP.

**Tech Stack:** dbt-postgres 1.12, PostgreSQL (đích), MySQL (nguồn), Python 3.11 (venv đã có), pymysql + psycopg2 cho EL.

## Global Constraints

- Working dir dbt: `D:\PTDL\DBT_postgre\dwh_project`. Chạy dbt sau khi `. .\env.<ten>.ps1` (đã set `DBT_PROFILES_DIR`, `PYTHONUTF8=1`).
- Nguồn MySQL: `27.71.20.96` / db `tiktok_dashboard`.
- Schema raw trên Postgres: lấy từ `var('raw_schema')` (mặc định `raw`).
- `TODAY()` DAX → macro `run_date()` = `coalesce(nullif('{{ var("run_date","") }}','')::date, current_date)`.
- So khớp chuỗi tiếng Việt: dùng `ilike` (không phân biệt hoa thường). Nếu lệch dấu, bọc `unaccent()` — chỉ thêm khi cần.
- `DATEDIFF(a,b,DAY)` DAX → `(a::date - b::date)` (Postgres trả integer ngày).
- TDD: mỗi model có unit test trước khi hoàn thiện. Commit sau mỗi task.
- Đặt tên cột output: giữ nguyên tên tiếng Việt như Power BI cho 14 cột tính toán, dùng dấu ngoặc kép trong SQL. Cột gốc giữ tên snake_case như nguồn.

---

## Task 0: Chuẩn bị kết nối & thư viện

**Files:**
- Create: `env.mva.ps1` (copy từ `env.example.ps1`, điền thật)
- Modify: (không)

**Interfaces:**
- Produces: kết nối Postgres đích hoạt động (`dbt debug` pass); schema `raw` tồn tại; venv có `pymysql`, `psycopg2-binary`, `pandas`, `sqlalchemy`.

- [ ] **Step 1: Cài thư viện EL vào venv**

Run:
```bash
cd /d/PTDL/DBT_postgre && ./venv/Scripts/python.exe -m pip install pymysql psycopg2-binary pandas sqlalchemy -q
```
Expected: cài xong không lỗi.

- [ ] **Step 2: Tạo `env.mva.ps1`**

Copy `dwh_project/env.example.ps1` → `dwh_project/env.mva.ps1`, điền: `SRC_DB` (không dùng cho load nhưng để nguyên), `DEST_HOST/DEST_PORT/DEST_DB/DEST_USER/DEST_PASSWORD/DEST_SCHEMA=staging`. Thêm các biến MySQL cho EL:
```powershell
$env:MYSQL_HOST="27.71.20.96"; $env:MYSQL_DB="tiktok_dashboard"
$env:MYSQL_USER="<user>"; $env:MYSQL_PASSWORD="<pass>"; $env:MYSQL_PORT="3306"
$env:PG_RAW_SCHEMA="raw"
```

- [ ] **Step 3: Tạo schema raw trên Postgres**

Chạy trên Postgres đích (psql/pgAdmin): `CREATE SCHEMA IF NOT EXISTS raw;`

- [ ] **Step 4: Verify dbt**

Run:
```bash
cd /d/PTDL/DBT_postgre/dwh_project && ../venv/Scripts/dbt.exe debug
```
Expected: `All checks passed!`

- [ ] **Step 5: Commit** *(nếu đã git init; nếu chưa, chạy `git init` trong `D:\PTDL\DBT_postgre` trước)*

```bash
cd /d/PTDL/DBT_postgre && git add -A && git commit -m "chore: EL deps + connection config for MVA pipeline"
```

---

## Task 1: Trích seed `videos_id_agency` từ Power BI

**Files:**
- Create: `dwh_project/seeds/videos_id_agency.csv`
- Modify: `dwh_project/dbt_project.yml` (thêm cấu hình seed)

**Interfaces:**
- Produces: seed `videos_id_agency` với cột `video_id` (text). Dùng bởi `mart_data` (loai_video, video_duoctinhpfm).

- [ ] **Step 1: Lấy danh sách video_id qua MCP**

Dùng tool `mcp__powerbi-mcp__dax_query_operations` operation `Execute`, query:
```
EVALUATE SELECTCOLUMNS(videos_id_agency_full, "video_id", videos_id_agency_full[video_id])
```
Lưu kết quả thành `dwh_project/seeds/videos_id_agency.csv` với header đúng 1 cột `video_id` (loại bỏ tiền tố tên bảng nếu có).

- [ ] **Step 2: Cấu hình kiểu cột seed**

Trong `dbt_project.yml` thêm:
```yaml
seeds:
  dwh_project:
    videos_id_agency:
      +column_types:
        video_id: varchar
```

- [ ] **Step 3: Nạp seed**

Run:
```bash
cd /d/PTDL/DBT_postgre/dwh_project && ../venv/Scripts/dbt.exe seed --select videos_id_agency
```
Expected: `1 of 1 OK`.

- [ ] **Step 4: Kiểm tra số dòng khớp Power BI**

Chạy MCP DAX `EVALUATE ROW("n", COUNTROWS(videos_id_agency_full))` và so với số dòng CSV (trừ header). Phải bằng nhau.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/seeds/videos_id_agency.csv dwh_project/dbt_project.yml && git commit -m "feat: seed videos_id_agency from Power BI snapshot"
```

---

## Task 2: EL script load 4 bảng MySQL → raw

**Files:**
- Create: `dwh_project/el/load_raw.py`
- Create: `dwh_project/el/README.md`

**Interfaces:**
- Produces: 4 bảng trong schema `raw` (mọi cột kiểu `text`, tên đã alias snake_case):
  - `raw.performance_list(creator_id, video_id, time, creator_name, product_name, vv, comment, share, new_follower, clicks_from_view_to_like, product_impressions, click_on_the_product, customer, count_order, unit_sales, video_revenue, gpm, gmv, ctr, view_to_like_ratio, video_viewing_rate, co_ratio, date_file_excel, brand)`
  - `raw.send_sample(ngay_duyet_mau, koc_kol, pic, phan_loai_creator, nguon_yeu_cau, ten_san_pham, sl, sheet, so_video, mst_cccd, ma_don_hang, vi_tri, cost, sdt)`
  - `raw.product_name_map(video_id, product_contain, product_contain_combo)`
  - `raw.pic_team(raw_name, doi_ten, team)`

- [ ] **Step 1: Viết `load_raw.py`**

Load mỗi bảng bằng một `SELECT` alias sang snake_case (KHÔNG biến đổi nghiệp vụ — đó là việc của staging), ghi vào Postgres schema `raw`, replace toàn bảng. Đọc config từ env (MYSQL_*, DEST_*, PG_RAW_SCHEMA).

```python
import os, pandas as pd, pymysql
from sqlalchemy import create_engine, text

MY = dict(host=os.environ["MYSQL_HOST"], port=int(os.getenv("MYSQL_PORT","3306")),
          user=os.environ["MYSQL_USER"], password=os.environ["MYSQL_PASSWORD"],
          database=os.environ["MYSQL_DB"], charset="utf8mb4")
PG_URL = (f"postgresql+psycopg2://{os.environ['DEST_USER']}:{os.environ['DEST_PASSWORD']}"
          f"@{os.environ['DEST_HOST']}:{os.getenv('DEST_PORT','5432')}/{os.environ['DEST_DB']}")
RAW = os.getenv("PG_RAW_SCHEMA", "raw")

QUERIES = {
 "performance_list": """
   SELECT creator_id, video_id, `time`, creator_name, product_name, vv, comment, share,
          new_follower, clicks_from_view_to_like, product_impressions, click_on_the_product,
          customer, count_order, unit_sales, video_revenue, gpm, gmv, ctr,
          view_to_like_ratio, video_viewing_rate, co_ratio, date_file_excel, brand
   FROM tiktok_dashboard.performance_list""",
 "send_sample": """
   SELECT `Ngày duyệt mẫu` AS ngay_duyet_mau, `KOC/KOL` AS koc_kol, `PIC` AS pic,
          `Phân loại Creator` AS phan_loai_creator, `Nguồn yêu cầu` AS nguon_yeu_cau,
          `Tên sản phẩm` AS ten_san_pham, `SL` AS sl, `sheet`, `Số video` AS so_video,
          `MST/CCCD` AS mst_cccd, `Mã đơn hàng` AS ma_don_hang, `Vị trí` AS vi_tri,
          `cost`, `SDT` AS sdt
   FROM MVA_KOC_KOL_send_sample""",
 "product_name_map": """
   SELECT video_id, product_contain, product_contain_combo
   FROM get_product_name_from_video_tiktok""",
 "pic_team": """
   SELECT Raw_name AS raw_name, Change_name AS doi_ten, Team AS team
   FROM PIC_Team""",
}

def main():
    myconn = pymysql.connect(**MY)
    pg = create_engine(PG_URL)
    with pg.begin() as c:
        c.execute(text(f'CREATE SCHEMA IF NOT EXISTS "{RAW}"'))
    for tbl, q in QUERIES.items():
        df = pd.read_sql(q, myconn).astype(str).where(lambda x: x.notna(), None)
        df.to_sql(tbl, pg, schema=RAW, if_exists="replace", index=False, chunksize=5000)
        print(f"{RAW}.{tbl}: {len(df)} rows")
    myconn.close()

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Viết `el/README.md`**

Nội dung: cách chạy `. .\env.mva.ps1 ; ..\venv\Scripts\python.exe el\load_raw.py`, giải thích load là replace-full, chạy trước `dbt run`.

- [ ] **Step 3: Chạy thử EL**

Run:
```bash
cd /d/PTDL/DBT_postgre/dwh_project && ../venv/Scripts/python.exe el/load_raw.py
```
Expected: in ra 4 dòng `raw.<tbl>: N rows`, N>0.

- [ ] **Step 4: Đối chiếu số dòng với MySQL**

So `raw.performance_list` count với MCP DAX `EVALUATE ROW("n", COUNTROWS(data))` — chấp nhận chênh do `data` đã lọc; số dòng `raw.send_sample` phải ≥ số dòng sau lọc. Ghi nhận, không cần khớp tuyệt đối ở raw.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/el/ && git commit -m "feat: EL script load 4 MySQL tables into raw"
```

---

## Task 3: Sources + macro run_date

**Files:**
- Modify: `dwh_project/models/staging/_sources.yml`
- Create: `dwh_project/macros/run_date.sql`

**Interfaces:**
- Produces: source `raw` với 4 bảng; macro `run_date()`.

- [ ] **Step 1: Cập nhật `_sources.yml`**

```yaml
version: 2
sources:
  - name: raw
    database: "{{ var('raw_database') }}"
    schema: "{{ var('raw_schema') }}"
    tables:
      - name: performance_list
      - name: send_sample
      - name: product_name_map
      - name: pic_team
```

- [ ] **Step 2: Viết macro `run_date`**

```sql
{% macro run_date() %}
  coalesce(nullif('{{ var("run_date", "") }}', '')::date, current_date)
{% endmacro %}
```

- [ ] **Step 3: Parse**

Run:
```bash
cd /d/PTDL/DBT_postgre/dwh_project && ../venv/Scripts/dbt.exe parse
```
Expected: parse OK, không lỗi.

- [ ] **Step 4: Commit**

```bash
git add dwh_project/models/staging/_sources.yml dwh_project/macros/run_date.sql && git commit -m "feat: raw sources + run_date macro"
```

---

## Task 4: Staging models

**Files:**
- Create: `dwh_project/models/staging/stg_performance_list.sql`
- Create: `dwh_project/models/staging/stg_send_sample.sql`
- Create: `dwh_project/models/staging/stg_product_name_map.sql`
- Create: `dwh_project/models/staging/stg_pic_team.sql`
- Modify: `dwh_project/models/staging/_stg_models.yml` (thay nội dung cũ)

**Interfaces:**
- Produces:
  - `stg_performance_list(creator_id, video_id, time date, creator_name, product_name, vv int, ... , date_file_excel date, brand)` — đã bỏ `\`, ép ngày.
  - `stg_send_sample(ngay_duyet_mau date, koc_kol, pic, phan_loai_creator, nguon_yeu_cau, ten_san_pham, sl int, sheet, so_video int, mst_cccd, ma_don_hang, vi_tri, cost int, sdt)` — đã TRIM/REPLACE/COALESCE + WHERE lọc.
  - `stg_product_name_map(video_id, product_contain, product_contain_combo)`.
  - `stg_pic_team(raw_name, doi_ten, team)`.

- [ ] **Step 1: Viết unit test cho stg_send_sample (làm sạch)**

Thêm vào `_stg_models.yml`:
```yaml
unit_tests:
  - name: ut_stg_send_sample_cleanup
    model: stg_send_sample
    given:
      - input: source('raw', 'send_sample')
        rows:
          - {ngay_duyet_mau: "2025-01-05", koc_kol: "@Vinhchinchu ", pic: "An", phan_loai_creator: "", nguon_yeu_cau: "x", ten_san_pham: "DHC Vitamin C", sl: "3", sheet: "s1", so_video: "2", mst_cccd: "1", ma_don_hang: "d1", vi_tri: "top", cost: "1000", sdt: "09"}
          - {ngay_duyet_mau: "2025-01-06", koc_kol: "", pic: "An", phan_loai_creator: "S", nguon_yeu_cau: "x", ten_san_pham: "y", sl: "1", sheet: "s1", so_video: "1", mst_cccd: "1", ma_don_hang: "d2", vi_tri: "top", cost: "1", sdt: "09"}
    expect:
      rows:
        - {koc_kol: "vinhchinchu", phan_loai_creator: "L1", sl: 3, cost: 1000}
```
(Dòng 2 bị loại vì `koc_kol` rỗng → expect chỉ 1 dòng.)

- [ ] **Step 2: Chạy test — kỳ vọng FAIL (model chưa có)**

Run:
```bash
../venv/Scripts/dbt.exe test --select ut_stg_send_sample_cleanup
```
Expected: FAIL / compilation error (model chưa tồn tại).

- [ ] **Step 3: Viết `stg_send_sample.sql`**

```sql
with src as (select * from {{ source('raw','send_sample') }})
select
    nullif(ngay_duyet_mau,'')::date                                            as ngay_duyet_mau,
    trim(replace(replace(koc_kol, '@', ''), 'Vinhchinchu', 'vinhchinchu'))      as koc_kol,
    pic,
    trim(coalesce(nullif(phan_loai_creator, ''), 'L1'))                         as phan_loai_creator,
    nguon_yeu_cau,
    ten_san_pham,
    nullif(sl,'')::numeric::int                                                 as sl,
    sheet,
    nullif(so_video,'')::numeric::int                                           as so_video,
    mst_cccd,
    ma_don_hang,
    vi_tri,
    nullif(cost,'')::numeric::int                                               as cost,
    sdt
from src
where koc_kol is not null and trim(koc_kol) <> ''
  and pic is not null and trim(pic) <> ''
```

- [ ] **Step 4: Viết 3 staging còn lại**

`stg_performance_list.sql`:
```sql
with src as (select * from {{ source('raw','performance_list') }})
select
    creator_id, video_id,
    nullif(time,'')::date                             as time,
    replace(creator_name, '\', '')                    as creator_name,
    replace(product_name, '\', '')                    as product_name,
    nullif(vv,'')::numeric::bigint                    as vv,
    nullif(comment,'')::numeric::bigint               as comment,
    nullif(share,'')::numeric::bigint                 as share,
    nullif(new_follower,'')::numeric::bigint          as new_follower,
    nullif(clicks_from_view_to_like,'')::numeric::bigint as clicks_from_view_to_like,
    nullif(product_impressions,'')::numeric::bigint   as product_impressions,
    nullif(click_on_the_product,'')::numeric::bigint  as click_on_the_product,
    customer,
    nullif(count_order,'')::numeric::bigint           as count_order,
    nullif(unit_sales,'')::numeric::bigint            as unit_sales,
    nullif(video_revenue,'')::numeric::bigint         as video_revenue,
    nullif(gpm,'')::numeric::bigint                   as gpm,
    nullif(gmv,'')::numeric::bigint                   as gmv,
    nullif(ctr,'')::numeric::bigint                   as ctr,
    nullif(view_to_like_ratio,'')::double precision   as view_to_like_ratio,
    nullif(video_viewing_rate,'')::double precision   as video_viewing_rate,
    nullif(co_ratio,'')::double precision             as co_ratio,
    nullif(date_file_excel,'')::date                  as date_file_excel,
    brand
from src
```

`stg_product_name_map.sql`:
```sql
select video_id, product_contain, product_contain_combo
from {{ source('raw','product_name_map') }}
```

`stg_pic_team.sql`:
```sql
select raw_name, doi_ten, team
from {{ source('raw','pic_team') }}
```

- [ ] **Step 5: Thay `_stg_models.yml`** (mô tả + test cơ bản)

```yaml
version: 2
models:
  - name: stg_performance_list
    columns:
      - name: video_id
      - name: time
  - name: stg_send_sample
    columns:
      - name: koc_kol
        data_tests: [not_null]
  - name: stg_product_name_map
    columns:
      - name: video_id
        data_tests: [not_null]
  - name: stg_pic_team
```
(Giữ block `unit_tests` từ Step 1.)

- [ ] **Step 6: Chạy build + test staging**

Run:
```bash
../venv/Scripts/dbt.exe build --select staging
```
Expected: các model + `ut_stg_send_sample_cleanup` PASS.

- [ ] **Step 7: Commit**

```bash
git add dwh_project/models/staging/ && git commit -m "feat: staging models with cleanup + unit test"
```

---

## Task 5: int_send_sample

**Files:**
- Create: `dwh_project/models/intermediate/int_send_sample.sql`
- Create: `dwh_project/models/intermediate/_int_models.yml`
- Modify: `dwh_project/dbt_project.yml` (thêm cấu hình tầng intermediate)

**Interfaces:**
- Consumes: `stg_send_sample`, `stg_pic_team`.
- Produces: `int_send_sample(ngay_duyet_mau date, koc_kol, pic, pic_rename, team, phan_loai_creator, phan_loai_creator_fix, prod_contain, ten_san_pham, sheet, sl int, vi_tri, product_detail, ngay_ket_thuc date, cost int, ...)`.

- [ ] **Step 1: Cấu hình tầng intermediate trong `dbt_project.yml`**

Trong `models: dwh_project:` thêm:
```yaml
    intermediate:
      +materialized: view
      +schema: intermediate
```

- [ ] **Step 2: Unit test prod_contain + ngay_ket_thuc + product_detail**

`_int_models.yml`:
```yaml
version: 2
unit_tests:
  - name: ut_int_send_sample_derived
    model: int_send_sample
    given:
      - input: ref('stg_send_sample')
        rows:
          - {ngay_duyet_mau: "2025-01-01", koc_kol: "a", pic: "An", phan_loai_creator: "S", ten_san_pham: "DHC Vitamin C mini", sheet: "adolph_s", sl: 2, vi_tri: "top", cost: 1}
          - {ngay_duyet_mau: "2025-02-01", koc_kol: "a", pic: "An", phan_loai_creator: "S", ten_san_pham: "DHC Vitamin C mini", sheet: "dhc",     sl: 1, vi_tri: "top", cost: 1}
      - input: ref('stg_pic_team')
        rows:
          - {raw_name: "An", doi_ten: "Anh", team: "T1"}
    expect:
      rows:
        - {ngay_duyet_mau: "2025-01-01", prod_contain: "vitamin c", pic_rename: "Anh", team: "T1", product_detail: "vitamin c", ngay_ket_thuc: "2025-01-31"}
        - {ngay_duyet_mau: "2025-02-01", prod_contain: "vitamin c", pic_rename: "Anh", team: "T1", product_detail: "DHC Vitamin C mini", ngay_ket_thuc: "2099-12-31"}
```
(Dòng 1: sheet chứa "adolph" → product_detail = prod_contain; ngay_ket_thuc = next(2025-02-01)-1. Dòng 2: sheet không adolph → product_detail = ten_san_pham; không có next → 2099-12-31.)

- [ ] **Step 3: Chạy test — kỳ vọng FAIL**

Run: `../venv/Scripts/dbt.exe test --select ut_int_send_sample_derived`
Expected: FAIL (model chưa có).

- [ ] **Step 4: Viết `int_send_sample.sql`**

```sql
with ss as (select * from {{ ref('stg_send_sample') }}),
pt as (select * from {{ ref('stg_pic_team') }}),

derived as (
    select
        ss.*,
        -- prod_contain: luật SWITCH của Table_send_sample (thứ tự quan trọng)
        case
            when ss.ten_san_pham ilike '%son dưỡng%' then 'son dưỡng'
            when ss.ten_san_pham ilike '%biotin%' then 'biotin'
            when ss.ten_san_pham ilike '%kẽm%' then 'kẽm'
            when ss.ten_san_pham ilike '%vitamin c%' then 'vitamin c'
            when ss.ten_san_pham ilike '%vitamin tổng%' then 'vitamin tổng hợp'
            when ss.ten_san_pham ilike '%canxi%' then 'canxi'
            when ss.ten_san_pham ilike '%dầu tẩy trang%' then 'dầu tẩy trang'
            when ss.ten_san_pham ilike '%kem chống nắng%' and ss.ten_san_pham ilike '%togishi%' then 'Kem chống nắng'
            when ss.ten_san_pham ilike '%vệ sinh nam%' then 'VSnam'
            when ss.ten_san_pham ilike '%COLD CREAM%' and ss.ten_san_pham ilike '%mini%' then 'Cold cream'
            when ss.ten_san_pham ilike '%COLD CREAM%' then 'Cold cream'
            when ss.ten_san_pham ilike '%FOAMING FACE WASH%' then 'FOAMING FACE WASH'
            when ss.ten_san_pham ilike '%WHITENING MOISTURE GEL%' then 'WHITENING MOISTURE GEL'
            when ss.ten_san_pham ilike '%adlay%' then 'ADLAY'
            when ss.ten_san_pham ilike '%b mix%' or ss.ten_san_pham ilike '%bmix%' or ss.ten_san_pham ilike '%b-mix%' then 'b mix'
            when ss.ten_san_pham ilike '%kem ủ%' then 'Adolph kem ủ'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%hộp%' then 'Adolph hộp quà'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%gội%' then 'Adolph gội'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%xả%' then 'Adolph xả'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%tinh dầu%' then 'Adolph tinh dầu'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%sữa tắm%' then 'Adolph sữa tắm'
            else null
        end as prod_contain,
        coalesce(pt.doi_ten, ss.pic) as pic_rename
    from ss left join pt on ss.pic = pt.raw_name
),

with_team as (
    select d.*, pt2.team
    from derived d
    left join pt pt2 on d.pic_rename = pt2.doi_ten
),

final as (
    select
        *,
        phan_loai_creator as phan_loai_creator_fix,
        case when sheet ilike '%adolph%' then prod_contain else ten_san_pham end as product_detail,
        (lead(ngay_duyet_mau) over (partition by koc_kol, prod_contain order by ngay_duyet_mau)) as _next_date
    from with_team
)

select
    *,
    case when _next_date is not null then _next_date - interval '1 day'
         else date '2099-12-31' end as ngay_ket_thuc
from final
```

- [ ] **Step 5: Chạy test — kỳ vọng PASS**

Run: `../venv/Scripts/dbt.exe build --select int_send_sample`
Expected: model + unit test PASS.

- [ ] **Step 6: Commit**

```bash
git add dwh_project/models/intermediate/ dwh_project/dbt_project.yml && git commit -m "feat: int_send_sample with derived columns + unit test"
```

---

## Task 6: int_valid_classification

**Files:**
- Create: `dwh_project/models/intermediate/int_valid_classification.sql`
- Modify: `dwh_project/models/intermediate/_int_models.yml`

**Interfaces:**
- Consumes: `stg_send_sample`.
- Produces: `int_valid_classification(phan_loai_creator)` — whitelist DISTINCT + {T, L2.1, L2.2}.

- [ ] **Step 1: Unit test whitelist**

Thêm vào `_int_models.yml`:
```yaml
  - name: ut_int_valid_classification
    model: int_valid_classification
    given:
      - input: ref('stg_send_sample')
        rows:
          - {phan_loai_creator: "S"}
          - {phan_loai_creator: "quà tặng"}
          - {phan_loai_creator: "S"}
          - {phan_loai_creator: ""}
    expect:
      rows:
        - {phan_loai_creator: "S"}
        - {phan_loai_creator: "T"}
        - {phan_loai_creator: "L2.1"}
        - {phan_loai_creator: "L2.2"}
```
(“quà tặng” bị loại; rỗng bị loại; "S" distinct; thêm T/L2.1/L2.2.)

- [ ] **Step 2: Chạy test — FAIL**

Run: `../venv/Scripts/dbt.exe test --select ut_int_valid_classification`
Expected: FAIL.

- [ ] **Step 3: Viết `int_valid_classification.sql`**

```sql
with base as (
    select distinct phan_loai_creator
    from {{ ref('stg_send_sample') }}
    where phan_loai_creator is not null
      and trim(phan_loai_creator) <> ''
      and phan_loai_creator not ilike '%quà%'
      and phan_loai_creator not ilike '%nghiệm%'
      and phan_loai_creator not ilike '%house%'
),
extra as (
    select unnest(array['T','L2.1','L2.2']) as phan_loai_creator
)
select phan_loai_creator from base
union
select phan_loai_creator from extra
```

- [ ] **Step 4: Chạy test — PASS**

Run: `../venv/Scripts/dbt.exe build --select int_valid_classification`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/models/intermediate/ && git commit -m "feat: int_valid_classification whitelist + unit test"
```

---

## Task 7: mart_data — nhóm sản phẩm (prod_contain, prod_contain_combo, loai_video)

**Files:**
- Create: `dwh_project/models/marts/mart_data.sql`
- Create: `dwh_project/models/marts/_mart_data.yml`
- Modify: `dwh_project/dbt_project.yml` (đảm bảo `marts` materialized table)

**Interfaces:**
- Consumes: `stg_performance_list`, `stg_product_name_map`, seed `videos_id_agency`.
- Produces: `mart_data` (giai đoạn 1) = mọi cột `stg_performance_list` + `prod_contain`, `prod_contain_combo`, `"Loại video"`.

- [ ] **Step 1: Unit test 3 cột**

`_mart_data.yml`:
```yaml
version: 2
unit_tests:
  - name: ut_mart_prod_and_loaivideo
    model: mart_data
    given:
      - input: ref('stg_performance_list')
        rows:
          - {video_id: "v1", time: "2025-03-01", product_name: "DHC combo b mix", creator_name: "a"}
          - {video_id: "v2", time: "2025-03-01", product_name: "Togishi kem chống nắng", creator_name: "b"}
      - input: ref('stg_product_name_map')
        rows:
          - {video_id: "v1", product_contain: "b mix", product_contain_combo: "combo b mix + c"}
      - input: ref('int_send_sample')
        rows: []
      - input: ref('int_valid_classification')
        rows: []
      - input: ref('videos_id_agency')
        rows:
          - {video_id: "v2"}
    expect:
      rows:
        - {video_id: "v1", prod_contain: "b mix", prod_contain_combo: "combo b mix + c", "Loại video": "Video thường"}
        - {video_id: "v2", prod_contain: "Kem chống nắng", prod_contain_combo: "Kem chống nắng", "Loại video": "Video AI"}
```
(v1: map có → prod_contain="b mix"; combo chứa "combo" → dùng combo. v2: map trống → SWITCH togishi+kcn → "Kem chống nắng"; combo trống→prod_contain; v2 ∈ seed → Video AI.)

- [ ] **Step 2: Chạy test — FAIL**

Run: `../venv/Scripts/dbt.exe test --select ut_mart_prod_and_loaivideo`
Expected: FAIL.

- [ ] **Step 3: Viết `mart_data.sql` (giai đoạn 1)**

```sql
{{ config(materialized='table') }}

with base as (select * from {{ ref('stg_performance_list') }}),
pmap as (select * from {{ ref('stg_product_name_map') }}),
agency as (select distinct video_id from {{ ref('videos_id_agency') }}),

prod as (
    select
        b.*,
        p.product_contain      as _map_contain,
        p.product_contain_combo as _map_combo,
        case
            when coalesce(nullif(p.product_contain,''), null) is not null then p.product_contain
            when b.product_name ilike '%b mix%' or b.product_name ilike '%bmix%' or b.product_name ilike '%b-mix%' then 'b mix'
            when b.product_name ilike '%son dưỡng%' then 'son dưỡng'
            when b.product_name ilike '%biotin%' then 'biotin'
            when b.product_name ilike '%kẽm%' then 'kẽm'
            when b.product_name ilike '%vitamin c%' then 'vitamin c'
            when b.product_name ilike '%vitamin tổng%' then 'vitamin tổng hợp'
            when b.product_name ilike '%canxi%' then 'canxi'
            when b.product_name ilike '%dầu tẩy trang%' then 'dầu tẩy trang'
            when b.product_name ilike '%kem chống nắng%' and b.product_name ilike '%togishi%' then 'Kem chống nắng'
            when b.product_name ilike '%vệ sinh nam%' then 'VSnam'
            when b.product_name ilike '%COLD CREAM%' or b.product_name ilike '%kem lạnh%' then 'Cold cream'
            when b.product_name ilike '%FOAMING FACE WASH%' then 'FOAMING FACE WASH'
            when b.product_name ilike '%WHITENING MOISTURE GEL%' then 'WHITENING MOISTURE GEL'
            when b.product_name ilike '%adlay%' then 'ADLAY'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%kem ủ%' then 'Adolph kem ủ'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%hộp quà%' then 'Adolph hộp quà'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%gội%' then 'Adolph gội'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%xả%' then 'Adolph xả'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%tinh dầu%' then 'Adolph tinh dầu'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%sữa tắm%' then 'Adolph sữa tắm'
            else null
        end as prod_contain
    from base b
    left join pmap p on b.video_id = p.video_id
),

with_cols as (
    select
        prod.*,
        case when _map_combo ilike '%combo%' then _map_combo else prod_contain end as prod_contain_combo,
        case when video_id in (select video_id from agency) then 'Video AI' else 'Video thường' end as "Loại video"
    from prod
)

select * from with_cols
```

- [ ] **Step 4: Chạy test — PASS**

Run: `../venv/Scripts/dbt.exe build --select mart_data`
Expected: model + unit test PASS.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/models/marts/ dwh_project/dbt_project.yml && git commit -m "feat: mart_data stage 1 (prod_contain, combo, loai_video)"
```

---

## Task 8: mart_data — nhóm gửi mẫu & thời gian (ngay_gui_mau, duration_date, video_duoctinhpfm, 2 cột ĐK)

**Files:**
- Modify: `dwh_project/models/marts/mart_data.sql`
- Modify: `dwh_project/models/marts/_mart_data.yml`

**Interfaces:**
- Consumes thêm: `int_send_sample`.
- Produces thêm cột: `"Ngày gửi mẫu" date, duration_date int, video_duoctinhPFM int, "DK Creator được gửi mẫu", "DK Time air video"`.

- [ ] **Step 1: Unit test (dùng run_date cố định)**

Thêm vào `_mart_data.yml`:
```yaml
  - name: ut_mart_duration
    model: mart_data
    overrides:
      vars:
        run_date: "2025-03-20"
    given:
      - input: ref('stg_performance_list')
        rows:
          - {video_id: "v1", time: "2025-03-10", product_name: "x", creator_name: "a"}
      - input: ref('stg_product_name_map')
        rows:
          - {video_id: "v1", product_contain: "kẽm", product_contain_combo: null}
      - input: ref('int_send_sample')
        rows:
          - {koc_kol: "a", prod_contain: "kẽm", sl: 2, ngay_duyet_mau: "2025-03-05", ngay_ket_thuc: "2099-12-31", pic_rename: "An", team: "T1", vi_tri: "top", product_detail: "kẽm", phan_loai_creator_fix: "S"}
      - input: ref('int_valid_classification')
        rows:
          - {phan_loai_creator: "S"}
      - input: ref('videos_id_agency')
        rows: []
    expect:
      rows:
        - {video_id: "v1", "Ngày gửi mẫu": "2025-03-05", duration_date: 3, "video_duoctinhPFM": 1, "DK Creator được gửi mẫu": "Có gửi mẫu", "DK Time air video": "Thỏa mãn ĐK thời gian là sau khi gửi mẫu"}
```
(gửi mẫu 05/03, air 10/03 → _duration=5? Kiểm: 10-05=5 → nhánh _duration<=7 → 1?? nhưng _check_today = 20-10=10 <=30 → 7. Vậy duration_date=7. Sửa expect=7.)

> **Lưu ý người thực thi:** `_check_today = run_date - time = 2025-03-20 - 2025-03-10 = 10 <= 30` → duration_date = **7**. Đặt `duration_date: 7` trong expect.

- [ ] **Step 2: Chạy test — FAIL**

Run: `../venv/Scripts/dbt.exe test --select ut_mart_duration`
Expected: FAIL.

- [ ] **Step 3: Sửa `mart_data.sql` — thêm CTE sau `with_cols`**

Chèn trước `select * from with_cols` cuối cùng (đổi câu select cuối):
```sql
,
send AS (select * from {{ ref('int_send_sample') }}),

gui_mau as (
    select
        w.*,
        (select min(s.ngay_duyet_mau) from send s
         where s.koc_kol = w.creator_name
           and s.prod_contain = w.prod_contain
           and s.sl > 0
           and length(s.prod_contain) > 0) as "Ngày gửi mẫu"
    from with_cols w
),

duration as (
    select
        g.*,
        case
            when "Ngày gửi mẫu" is null then -1
            when "Ngày gửi mẫu" > g.time then -1
            else case
                when ({{ run_date() }} - g.time) <= 30 then 7
                when ({{ run_date() }} - g.time) <= 60 then 6
                when (g.time - "Ngày gửi mẫu") <= 7 then 1
                when (g.time - "Ngày gửi mẫu") <= 14 then 2
                when (g.time - "Ngày gửi mẫu") <= 30 then 3
                when (g.time - "Ngày gửi mẫu") <= 90 then 4
                else 5
            end
        end as duration_date
    from gui_mau g
),

pfm as (
    select
        d.*,
        case when d.video_id in (select video_id from agency) or d.duration_date > 0 then 1 else 0 end as "video_duoctinhPFM",
        case when d.duration_date > 0 then 'Có gửi mẫu' else 'Ko gửi mẫu' end as "DK Creator được gửi mẫu",
        case when d.duration_date > 0 then 'Thỏa mãn ĐK thời gian là sau khi gửi mẫu' else 'Không tính' end as "DK Time air video"
    from duration d
)

select * from pfm
```

- [ ] **Step 4: Chạy test — PASS**

Run: `../venv/Scripts/dbt.exe build --select mart_data`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/models/marts/ && git commit -m "feat: mart_data stage 2 (ngay_gui_mau, duration_date, PFM, DK cols)"
```

---

## Task 9: mart_data — phân loại creator (phan_loai_creator, group_creator)

**Files:**
- Modify: `dwh_project/models/marts/mart_data.sql`
- Modify: `dwh_project/models/marts/_mart_data.yml`

**Interfaces:**
- Consumes thêm: `int_valid_classification`.
- Produces thêm cột: `"Phân loại Creator", "Group creator"`.

- [ ] **Step 1: Unit test**

Thêm:
```yaml
  - name: ut_mart_phanloai
    model: mart_data
    overrides:
      vars:
        run_date: "2025-03-20"
    given:
      - input: ref('stg_performance_list')
        rows:
          - {video_id: "v1", time: "2025-03-10", product_name: "x", creator_name: "a"}
      - input: ref('stg_product_name_map')
        rows:
          - {video_id: "v1", product_contain: "kẽm", product_contain_combo: null}
      - input: ref('int_send_sample')
        rows:
          - {koc_kol: "a", prod_contain: "kẽm", sl: 2, ngay_duyet_mau: "2025-03-05", ngay_ket_thuc: "2099-12-31", pic_rename: "An", team: "T1", vi_tri: "top", product_detail: "kẽm", phan_loai_creator_fix: "S"}
          - {koc_kol: "a", prod_contain: "kẽm", sl: 2, ngay_duyet_mau: "2025-03-06", ngay_ket_thuc: "2099-12-31", pic_rename: "An", team: "T1", vi_tri: "top", product_detail: "kẽm", phan_loai_creator_fix: "L1"}
      - input: ref('int_valid_classification')
        rows:
          - {phan_loai_creator: "S"}
      - input: ref('videos_id_agency')
        rows: []
    expect:
      rows:
        - {video_id: "v1", "Phân loại Creator": "S", "Group creator": "S"}
```
(2 dòng khớp thời gian; priority S=3 < L1=6 → chọn S; S có trong whitelist → group_value=S; PFM=1 (duration_date=7>0) → _kq=S; group_creator: không chứa L0/L1/L2 → "S".)

- [ ] **Step 2: Chạy test — FAIL**

Run: `../venv/Scripts/dbt.exe test --select ut_mart_phanloai`
Expected: FAIL.

- [ ] **Step 3: Sửa `mart_data.sql` — thêm CTE sau `pfm`**

Đổi `select * from pfm` cuối thành:
```sql
,
valid as (select distinct phan_loai_creator from {{ ref('int_valid_classification') }}),

pl_ranked as (
    select
        p.video_id, p.time, p.creator_name, p.prod_contain,
        s.phan_loai_creator_fix,
        case s.phan_loai_creator_fix
            when 'S+' then 1 when 'T' then 2 when 'S' then 3 when 'M' then 4
            when 'L2' then 5 when 'L1' then 6 when 'L0' then 7
            when 'L1.2' then 8 when 'L1.1' then 9 else 999 end as priority
    from pfm p
    join send s
      on s.koc_kol = p.creator_name
     and s.prod_contain = p.prod_contain
     and s.ngay_duyet_mau <= p.time
     and (s.ngay_ket_thuc is null or p.time <= s.ngay_ket_thuc)
),

pl_pick as (
    select video_id,
           max(phan_loai_creator_fix) filter (where priority = min_priority) as picked
    from (
        select r.*, min(priority) over (partition by video_id) as min_priority
        from pl_ranked r
    ) z
    group by video_id
),

phanloai as (
    select
        p.*,
        pp.picked as _picked,
        case
            when p.prod_contain is null or length(p.prod_contain) = 0 then 'Thiếu dữ liệu tên SP'
            else coalesce(
                case p."video_duoctinhPFM"
                    when 1 then (select v.phan_loai_creator from valid v where v.phan_loai_creator = pp.picked)
                    when 0 then 'Organic'
                end, 'Organic')
        end as "Phân loại Creator"
    from pfm p
    left join pl_pick pp on p.video_id = pp.video_id
),

grp as (
    select
        ph.*,
        case
            when ph."Phân loại Creator" ilike '%L0%' then 'L0'
            when ph."Phân loại Creator" ilike '%L1%' then 'L1'
            when ph."Phân loại Creator" ilike '%L2%' then 'L2'
            else ph."Phân loại Creator"
        end as "Group creator"
    from phanloai ph
)

select * from grp
```

> **Lưu ý:** `pfm` cần chứa mọi cột trước đó; `phanloai` select `p.*` từ `pfm` để mang cột gốc. `_picked` giữ để debug (có thể bỏ khi hoàn thiện).

- [ ] **Step 4: Chạy test — PASS**

Run: `../venv/Scripts/dbt.exe build --select mart_data`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/models/marts/ && git commit -m "feat: mart_data stage 3 (phan_loai_creator, group_creator)"
```

---

## Task 10: mart_data — PIC / Team / Vị trí / Mẫu gửi

**Files:**
- Modify: `dwh_project/models/marts/mart_data.sql`
- Modify: `dwh_project/models/marts/_mart_data.yml`

**Interfaces:**
- Produces thêm cột: `"PIC", "Team", "Vị trí", "Mẫu gửi"`. Đây là bảng rộng hoàn chỉnh.

- [ ] **Step 1: Unit test 4 cột**

Thêm:
```yaml
  - name: ut_mart_pic_team_vitri_maugui
    model: mart_data
    overrides:
      vars:
        run_date: "2025-03-20"
    given:
      - input: ref('stg_performance_list')
        rows:
          - {video_id: "v1", time: "2025-03-10", product_name: "x", creator_name: "a"}
      - input: ref('stg_product_name_map')
        rows:
          - {video_id: "v1", product_contain: "kẽm", product_contain_combo: null}
      - input: ref('int_send_sample')
        rows:
          - {koc_kol: "a", prod_contain: "kẽm", sl: 2, ngay_duyet_mau: "2025-03-05", ngay_ket_thuc: "2099-12-31", pic_rename: "Anh", team: "T1", vi_tri: "top", product_detail: "mẫu A", phan_loai_creator_fix: "S"}
      - input: ref('int_valid_classification')
        rows:
          - {phan_loai_creator: "S"}
      - input: ref('videos_id_agency')
        rows: []
    expect:
      rows:
        - {video_id: "v1", "PIC": "Anh", "Team": "T1", "Vị trí": "top", "Mẫu gửi": "mẫu A"}
```

- [ ] **Step 2: Chạy test — FAIL**

Run: `../venv/Scripts/dbt.exe test --select ut_mart_pic_team_vitri_maugui`
Expected: FAIL.

- [ ] **Step 3: Sửa `mart_data.sql` — thêm CTE sau `grp`**

Đổi `select * from grp` cuối thành các LATERAL pick + team:
```sql
,
pic_pick as (
    select g.video_id,
           max(s.pic_rename) filter (where s.ngay_duyet_mau = mn) as "PIC"
    from grp g
    join lateral (
        select s.*, min(s.ngay_duyet_mau) over () as mn
        from send s
        where s.koc_kol = g.creator_name
          and s.prod_contain = g.prod_contain
          and s.sl > 0
          and s.prod_contain is not null and length(s.prod_contain) > 0
          and s.koc_kol is not null and length(s.koc_kol) > 0
          and s.ngay_duyet_mau <= g.time
          and g.time <= s.ngay_ket_thuc
    ) s on true
    group by g.video_id
),

vitri_maugui_pick as (
    select g.video_id,
           max(s.vi_tri)         filter (where s.ngay_duyet_mau = mn) as "Vị trí",
           max(s.product_detail) filter (where s.ngay_duyet_mau = mn) as "Mẫu gửi"
    from grp g
    join lateral (
        select s.*, min(s.ngay_duyet_mau) over () as mn
        from send s
        where s.koc_kol = g.creator_name
          and s.prod_contain = g.prod_contain
          and s.ngay_duyet_mau <= g.time
          and g.time <= s.ngay_ket_thuc
    ) s on true
    group by g.video_id
),

final as (
    select
        g.*,
        pp."PIC",
        (select max(s.team) from send s where s.pic_rename = pp."PIC" and s.team is not null and s.team <> '') as "Team",
        vm."Vị trí",
        vm."Mẫu gửi"
    from grp g
    left join pic_pick pp on g.video_id = pp.video_id
    left join vitri_maugui_pick vm on g.video_id = vm.video_id
)

select * from final
```

> **Lưu ý:** Team dùng `max(team)` thay cho FIRSTNONBLANK — với 1 PIC thường chỉ 1 team nên tương đương; nếu Power BI cho kết quả khác, chuyển sang lấy team theo `ngay_duyet_mau` mới nhất.

- [ ] **Step 4: Chạy test — PASS**

Run: `../venv/Scripts/dbt.exe build --select mart_data`
Expected: tất cả unit test PASS.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/models/marts/ && git commit -m "feat: mart_data stage 4 (PIC, Team, Vị trí, Mẫu gửi) — bảng rộng hoàn chỉnh"
```

---

## Task 11: Chạy end-to-end + đối chiếu Power BI

**Files:**
- Create: `dwh_project/analyses/compare_powerbi.sql` (tùy chọn, để tham chiếu)
- Create: `dwh_project/tests/` (data test tùy chọn)

**Interfaces:**
- Produces: `mart_data` chạy trên dữ liệu thật; báo cáo mức khớp với Power BI.

- [ ] **Step 1: Load raw + build toàn bộ**

Run:
```bash
cd /d/PTDL/DBT_postgre/dwh_project && ../venv/Scripts/python.exe el/load_raw.py && ../venv/Scripts/dbt.exe build
```
Expected: EL 4 bảng OK; dbt build tất cả model + test PASS.

- [ ] **Step 2: Trích kết quả Power BI để đối chiếu**

Dùng MCP `dax_query_operations` Execute:
```
EVALUATE
SELECTCOLUMNS(
  TOPN(200, data, data[video_id]),
  "video_id", data[video_id], "time", data[time],
  "prod_contain", data[prod_contain], "duration_date", data[duration_date],
  "Phan loai", data[Phân loại Creator], "PIC", data[PIC],
  "Vi tri", data[Vị trí], "Mau gui", data[Mẫu gửi]
)
```
Lưu thành `scratchpad/pbi_expected.csv`.

> **Lưu ý:** chạy `dbt build` **cùng ngày** với thời điểm trích Power BI (vì `duration_date` phụ thuộc `current_date`). Nếu khác ngày, truyền `--vars '{run_date: "<ngày trích PBI>"}'`.

- [ ] **Step 3: So khớp**

Query Postgres `mart_data` cho cùng 200 `video_id`, so từng cột với `pbi_expected.csv`. Ghi nhận cột/dòng lệch.

- [ ] **Step 4: Xử lý lệch (nếu có)**

Với mỗi cột lệch, dùng superpowers:systematic-debugging: khoanh vùng 1 `video_id` lệch, so logic DAX gốc (§7 spec) với SQL, sửa, chạy lại unit test + so khớp.

- [ ] **Step 5: Commit**

```bash
git add dwh_project/ && git commit -m "test: end-to-end run + Power BI reconciliation"
```

---

## Self-Review Notes

- **Spec coverage:** §5 staging → Task 4; §6 intermediate → Task 5-6; §7 (14 cột) → Task 7-10; §8 test → Task 11 + unit tests mỗi task; §2 nguồn → Task 1 (seed) + Task 2 (EL); §4 cấu hình linh hoạt → dùng khung sẵn.
- **prod_contain khác biệt** giữa data (Task 7) và send_sample (Task 5): đã dùng đúng thứ tự luật riêng cho từng bảng.
- **TOPN/MAXX** → `max(...) filter (where key = min_key)`: áp dụng nhất quán ở Task 9 (priority) và Task 10 (ngay_duyet_mau).
- **run_date**: unit tests dùng `overrides.vars.run_date` để xác định `duration_date`.
- **Điểm cần kiểm ở dữ liệu thật:** ngữ nghĩa Team (max vs mới nhất), so khớp dấu tiếng Việt (thêm `unaccent` nếu lệch).
