-- Tổng hợp số video (distinct) theo tổ hợp chiều gửi mẫu / creator / sản phẩm,
-- chỉ tính các dòng duration_date > 0 (video thỏa điều kiện tính PFM theo thời gian).
{{ config(
    materialized='table',
    pre_hook=["set work_mem = '256MB'", "set jit = off"]
) }}

-- count(distinct video_id) trên GROUP BY nhiều cột text buộc Postgres SORT ~1.6M dòng
-- (DISTINCT-aggregate không dùng được HashAggregate) → rất chậm với collation tiếng Việt.
-- Viết lại 2 tầng HASH tương đương: (1) DISTINCT (13 chiều + video_id) khử trùng,
-- (2) COUNT(*) theo 13 chiều. Cả 2 tầng đều HashAggregate → KHÔNG cần sort.
-- video_id là khóa NOT NULL nên count(*) ≡ count(distinct video_id).
with dedup as (
    select distinct
        "Ngày gửi mẫu",
        "time",
        brand,
        creator_name,
        duration_date,
        prod_contain,
        prod_contain_combo,
        "Phân loại Creator",
        "Group creator",
        "PIC",
        "Team",
        "Vị trí",
        "Mẫu gửi",
        video_id
    from {{ ref('mart_data') }}
    where duration_date > 0 and video_id is not null
)
select
    "Ngày gửi mẫu",
    "time",
    brand,
    creator_name,
    duration_date,
    prod_contain,
    prod_contain_combo,
    "Phân loại Creator",
    "Group creator",
    "PIC",
    "Team",
    "Vị trí",
    "Mẫu gửi",
    count(*) as so_luong_video
from dedup
group by
    "time",
    brand,
    creator_name,
    duration_date,
    prod_contain,
    prod_contain_combo,
    "Ngày gửi mẫu",
    "Phân loại Creator",
    "Group creator",
    "PIC",
    "Team",
    "Vị trí",
    "Mẫu gửi"
