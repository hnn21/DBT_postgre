-- Tổng hợp metric hiệu suất theo tổ hợp chiều thời gian snapshot / gửi mẫu /
-- creator / sản phẩm, giữ nguyên video_id trong grain.
--
-- GRAIN: 16 chiều + video_id  (1 dòng = 1 video trong 1 tổ hợp chiều).
-- => Số video phải đếm bằng count(distinct video_id) (PBI: DISTINCTCOUNT(video_id)),
--    KHÔNG cộng số dòng. Nhờ giữ video_id, số video ĐÚNG ở MỌI mức roll-up
--    (tuần, tháng, quý, toàn kỳ). Trước đây bảng đã gộp mất video_id nên một video
--    có mặt ở nhiều tuần bị đếm lặp khi cộng lên tháng (~2,3 lần).
--
-- KHÔNG lọc duration_date: nó là một CHIỀU trong grain, phía báo cáo tự lọc nếu cần.
--
-- thang/tuan lấy từ date_file_excel (NGÀY FILE SNAPSHOT, không phải ngày lên video —
-- ngày lên sóng là cột "time"). tuan dùng ISO week và BẮT BUỘC ghép IYYY với IW:
-- 'YYYY-IW' sẽ sai ở giao năm (29/12/2025 thuộc tuần ISO 01 của 2026).
--
-- LƯU Ý metric: vv, count_order, ... là số PHÁT SINH theo từng snapshot, KHÔNG lũy kế
-- (đã kiểm chứng ở spec mart_new_video) nên sum qua các snapshot mới là tổng đúng.
--
-- INCREMENTAL (delete+insert theo `thang`). An toàn vì mart_data bất biến sau khi tạo
-- (duration_date/range_date tĩnh + performance_list append-only) -> tháng cũ không đổi.
--   • Full:         dbt build -s mart_data_agg --full-refresh   (dựng lại toàn bộ)
--   • Truyền tháng: --vars '{agg_months: ["2026-07","2026-08"]}' (chỉ các tháng này)
--   • Không truyền: mặc định tháng hiện tại + tháng trước.
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='thang',
    pre_hook=["set work_mem = '256MB'", "set jit = off"]
) }}

select
    to_char(date_file_excel, 'YYYY-MM')           as thang,
    to_char(date_file_excel, 'IYYY-IW')           as tuan,
    "Ngày gửi mẫu",
    "time",
    brand,
    creator_name,
    duration_date,
    range_date,
    prod_contain,
    prod_contain_combo,
    "Phân loại Creator",
    "Group creator",
    "PIC",
    "Team",
    "Vị trí",
    "Mẫu gửi",
    video_id,
    coalesce(sum(vv), 0)::bigint                   as so_view,
    coalesce(sum(click_on_the_product), 0)::bigint as so_click,
    coalesce(sum(count_order), 0)::bigint          as so_don,
    coalesce(sum(video_revenue), 0)::bigint        as gmv,
    coalesce(sum(product_impressions), 0)::bigint  as product_impressions,
    coalesce(sum(unit_sales), 0)::bigint           as unit_sales
from {{ ref('mart_data') }}
where video_id is not null
{% if is_incremental() %}
    {% set agg_months = var('agg_months', none) %}
    {% if agg_months is string %}{% set agg_months = [agg_months] %}{% endif %}
    {% if agg_months is not none %}
    -- Mode "truyền tháng": chỉ tính lại các tháng chỉ định
    and to_char(date_file_excel, 'YYYY-MM') in (
        {%- for m in agg_months -%}'{{ m }}'{{ ', ' if not loop.last }}{%- endfor -%}
    )
    {% else %}
    -- Mặc định: tháng hiện tại + tháng trước (phủ cửa sổ 14 ngày của mart_data)
    and date_file_excel >= date_trunc('month', current_date) - interval '1 month'
    {% endif %}
{% endif %}
group by
    to_char(date_file_excel, 'YYYY-MM'),
    to_char(date_file_excel, 'IYYY-IW'),
    "Ngày gửi mẫu",
    "time",
    brand,
    creator_name,
    duration_date,
    range_date,
    prod_contain,
    prod_contain_combo,
    "Phân loại Creator",
    "Group creator",
    "PIC",
    "Team",
    "Vị trí",
    "Mẫu gửi",
    video_id
