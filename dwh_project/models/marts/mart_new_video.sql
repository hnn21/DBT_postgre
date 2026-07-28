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
