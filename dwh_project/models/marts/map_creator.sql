-- KHO TÍCH LUỸ mọi cặp (creator_id, creator_name) từng quan sát được.
-- Bảng VẬT LÝ ở schema marts để tiện `select` truy cứu trực tiếp.
--
-- TẠI SAO PHẢI TÍCH LUỸ, không tính lại từ đầu mỗi lần:
--   `full_load()` trong el/load_raw.py dùng TRUNCATE (dòng ~175). Nếu về sau MySQL
--   dọn dữ liệu cũ rồi ai đó chạy full reload, mọi creator_name cũ biến mất khỏi raw
--   -> ~8.430 video từng được sửa attribution sẽ hỏng lại mà KHÔNG báo lỗi gì.
--   Bảng chỉ-thêm miễn nhiễm với chuyện đó.
--
-- ⚠️ full_refresh=false là BẮT BUỘC, không phải tuỳ chọn.
--   Kế hoạch triển khai có `dbt run --full-refresh` cho cả cây. Thiếu cấu hình này,
--   dbt DROP bảng và dựng lại chỉ từ cửa sổ hiện tại -> mất sạch phần tích luỹ ngay
--   lần chạy đầu tiên, tức là mất đúng thứ mà bảng này sinh ra để giữ.
--
-- Quy mô (đo 2026-09-22): 54.533 cặp / 45.441 creator, tăng ~2.000 cặp/tháng.
-- Lần chạy ĐẦU quét toàn bộ 5,5M dòng (vài phút); các lần sau chỉ quét cửa sổ incr_days.
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['creator_id', 'creator_name_key'],
    full_refresh=false,
    on_schema_change='append_new_columns'
) }}

with src as (
    select
        creator_id,
        lower(trim(creator_name)) as creator_name_key,
        creator_name,
        date_file_excel
    from {{ ref('stg_performance_list') }}
    where creator_id is not null and trim(creator_id) <> ''
      and trim(coalesce(creator_name, '')) <> ''
    {% if is_incremental() %}
      and date_file_excel >= current_date - {{ var('incr_days', 90) | int }}
    {% endif %}
),

moi as (
    select
        creator_id,
        creator_name_key,
        max(creator_name)    as creator_name,
        min(date_file_excel) as first_seen,
        max(date_file_excel) as last_seen
    from src
    group by creator_id, creator_name_key
)

{% if is_incremental() %}
-- delete+insert xoá dòng cũ TRƯỚC KHI chèn, nên first_seen sẽ bị tính lại chỉ từ
-- cửa sổ hiện tại. Đọc lại {{ this }} (trạng thái TRƯỚC khi xoá — bảng tạm được dựng
-- trước) để giữ mốc đầu tiên thật sự.
select
    m.creator_id,
    m.creator_name_key,
    m.creator_name,
    least(coalesce(cu.first_seen, m.first_seen), m.first_seen)    as first_seen,
    greatest(coalesce(cu.last_seen, m.last_seen), m.last_seen)    as last_seen
from moi m
left join {{ this }} cu
  on cu.creator_id = m.creator_id
 and cu.creator_name_key = m.creator_name_key
{% else %}
select creator_id, creator_name_key, creator_name, first_seen, last_seen
from moi
{% endif %}
