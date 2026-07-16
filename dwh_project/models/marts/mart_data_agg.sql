-- Tổng hợp số video (distinct) theo tổ hợp chiều gửi mẫu / creator / sản phẩm,
-- chỉ tính các dòng duration_date > 0 (video thỏa điều kiện tính PFM theo thời gian).
{{ config(materialized='table') }}

select
    "Ngày gửi mẫu",
    "time",
    brand,
    prod_contain,
    prod_contain_combo,
    "Phân loại Creator",
    "Group creator",
    "PIC",
    "Team",
    "Vị trí",
    "Mẫu gửi",
    count(distinct video_id) as so_luong
from {{ ref('mart_data') }}
where duration_date > 0
group by
    "time",
    brand,
    prod_contain,
    prod_contain_combo,
    "Ngày gửi mẫu",
    "Phân loại Creator",
    "Group creator",
    "PIC",
    "Team",
    "Vị trí",
    "Mẫu gửi"
