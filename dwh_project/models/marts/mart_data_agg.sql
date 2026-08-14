-- Tổng hợp metric hiệu suất theo tổ hợp chiều thời gian snapshot / gửi mẫu /
-- creator / sản phẩm, giữ nguyên video_id trong grain.
--
-- GRAIN: 15 chiều + video_id  (1 dòng = 1 video trong 1 tổ hợp chiều).
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
-- Một HashAggregate duy nhất, không sort, không join — 1 lần quét mart_data.
{{ config(
    materialized='table',
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
group by
    to_char(date_file_excel, 'YYYY-MM'),
    to_char(date_file_excel, 'IYYY-IW'),
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
