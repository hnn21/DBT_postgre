-- Bảng gửi mẫu cho Power BI: 1 dòng = 1 lần gửi mẫu.
-- Vật chất hoá từ int_send_sample (view nội bộ) để báo cáo đọc được, kèm 2 khoá
-- định danh (creator_id, pic_user_id) và số video THỰC TẾ đã ra.
--
-- ⚠️ ĐÃ LOẠI `mst_cccd` và `sdt`: đó là mã số thuế/CCCD và số điện thoại của KOC.
-- Bảng này phục vụ Power BI nên mọi người xem báo cáo đều đọc được — không đưa dữ
-- liệu định danh cá nhân vào đây. Hai cột đó vẫn còn ở raw/staging cho ai thực sự cần.
--
-- Cũng bỏ `_next_date` (cột trung gian để tính ngay_ket_thuc, không có nghĩa nghiệp vụ).
{{ config(materialized='table') }}

with ss as (select * from {{ ref('int_send_sample') }}),

-- Số video THỰC TẾ ra theo từng koc_booking_content_id.
-- Đếm từ mart_new_video vì bảng đó đã là 1 dòng/video (mart_data có nhiều snapshot
-- mỗi video nên đếm ở đó sẽ bị thổi phồng).
nv as (select * from {{ ref('mart_new_video') }}),

-- NHÁNH 1 (ưu tiên): đếm theo koc_booking_content_id — liên kết TRỰC TIẾP, chắc chắn nhất.
-- Chỉ dùng được cho ~4,1% bản ghi có id này.
kq_booking as (
    select
        koc_booking_content_id,
        count(distinct video_id) as so_video
    from nv
    where koc_booking_content_id is not null
    group by koc_booking_content_id
),

-- NHÁNH 2 (dự phòng): với bản ghi KHÔNG có booking id, khớp theo
-- (creator_id, prod_contain, pic_user_id) + video lên trong KHOẢNG HIỆU LỰC.
--
-- ⚠️ `time <= ngay_ket_thuc` là BẮT BUỘC, không phải tuỳ chọn.
-- Nếu chỉ dùng `time >= ngay_duyet_mau`, một creator gửi mẫu cùng sản phẩm nhiều lần
-- sẽ khiến MỌI video về sau bị tính cho MỌI lần gửi mẫu trước đó. Đã đo:
--   chỉ >= ngay_duyet_mau : 72.440 cặp / 67.466 video khác nhau  -> lặp 4.974 lượt (+7%)
--   thêm <= ngay_ket_thuc : 67.441 cặp / 67.441 video khác nhau  -> 1:1, không lặp
-- Có video bị tính cho 25 bản ghi gửi mẫu khi bỏ cận trên. Cận trên giữ đúng bất biến
-- "mỗi video rơi vào đúng MỘT lần gửi mẫu" mà campaign_id/PIC/Vị trí đang dựa vào.
kq_khop as (
    select
        k.creator_id, k.prod_contain, k.pic_user_id, k.ngay_duyet_mau, k.ngay_ket_thuc,
        count(distinct v.video_id) as so_video
    from (
        select distinct creator_id, prod_contain, pic_user_id, ngay_duyet_mau, ngay_ket_thuc
        from ss
        where koc_booking_content_id is null
          and creator_id is not null and prod_contain is not null and pic_user_id is not null
    ) k
    join nv v
      on v.creator_id   = k.creator_id
     and v.prod_contain = k.prod_contain
     and v.pic_user_id  = k.pic_user_id
     and v."time"      >= k.ngay_duyet_mau
     and v."time"      <= k.ngay_ket_thuc
    group by 1, 2, 3, 4, 5
)

select
    -- thời gian hiệu lực
    ss.ngay_duyet_mau,
    ss.ngay_ket_thuc,

    -- danh tính creator
    ss.koc_kol,
    ss.creator_id,

    -- danh tính PIC
    ss.pic,
    ss.pic_rename,
    ss.pic_user_id,

    -- phân loại
    ss.phan_loai_creator,
    ss.phan_loai_creator_fix,
    ss.nguon_yeu_cau,
    ss.sheet,
    ss.vi_tri,

    -- sản phẩm
    ss.ten_san_pham,
    ss.product_detail,
    ss.prod_contain,

    -- số liệu gửi mẫu
    ss.sl,
    ss.so_video,          -- số video CAM KẾT (từ nguồn)
    ss.cost,
    ss.ma_don_hang,

    -- liên kết booking / campaign
    ss.campaign_id,
    ss.koc_booking_content_id,
    ss.agency_id,

    -- Số video THỰC TẾ đã ra cho lần gửi mẫu này. Hai nhánh, ưu tiên nhánh 1.
    --   0    = có đủ dữ liệu để đếm, nhưng KHÔNG ra video nào
    --   NULL = KHÔNG đếm được (thiếu creator_id / prod_contain / pic_user_id)
    -- Phân biệt rõ hai ca này: gán 0 cho ca thứ hai sẽ khiến báo cáo đọc thành
    -- "đã gửi mẫu mà không ra video", sai hoàn toàn về bản chất.
    case
        -- có booking id -> đếm trực tiếp
        when ss.koc_booking_content_id is not null then coalesce(kb.so_video, 0)
        -- không có booking id VÀ thiếu khoá khớp -> KHÔNG đếm được (NULL, không phải 0)
        when ss.creator_id is null or ss.prod_contain is null or ss.pic_user_id is null then null
        -- khớp theo điều kiện
        else coalesce(kk.so_video, 0)
    end as so_video_ket_qua,

    -- cách tính đã dùng cho dòng này — để đối chiếu/kiểm tra, đừng gộp 2 cách khi đọc số
    case
        when ss.koc_booking_content_id is not null then 'booking_id'
        when ss.creator_id is null or ss.prod_contain is null or ss.pic_user_id is null then null
        else 'khop_dieu_kien'
    end as cach_tinh_so_video

from ss
left join kq_booking kb on kb.koc_booking_content_id = ss.koc_booking_content_id
left join kq_khop kk
       on kk.creator_id     = ss.creator_id
      and kk.prod_contain   = ss.prod_contain
      and kk.pic_user_id    = ss.pic_user_id
      and kk.ngay_duyet_mau = ss.ngay_duyet_mau
      and kk.ngay_ket_thuc  = ss.ngay_ket_thuc
