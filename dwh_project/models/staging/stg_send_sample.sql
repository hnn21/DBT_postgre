-- Chuẩn hoá bảng gửi mẫu + gắn DANH TÍNH PIC theo user_id.
--
-- Hai cột `user_id` / `koc_booking_content_id` mới có ở nguồn và chỉ phủ ~4,1% dòng
-- (1.805/43.944) vì phần lớn dữ liệu là lịch sử từ sheet, có trước hệ thống KOC.
-- Phần trống được lấp bằng seed `pic_user_map` (tra theo tên PIC, phủ 100%).
--
-- ⚠️ `user_id` ở nguồn là cột AUDIT "ai tạo bản ghi" (trỏ users.id), KHÔNG phải
-- "PIC phụ trách". Đã đo: 337 dòng có user_id nguồn khác với tra theo tên —
-- cả 3 tài khoản Partner (PA/Ly/MA) đều mang user_id=74 vì một người nhập hộ.
-- Quyết định: ƯU TIÊN NGUỒN (coalesce theo thứ tự này). Test
-- `ut_send_sample_user_id_lech` giữ con số đó luôn hiển thị.
with src as (select * from {{ source('raw','send_sample') }}),
pic_map as (select * from {{ ref('pic_user_map') }})

select
    nullif(s.ngay_duyet_mau,'')::date                                          as ngay_duyet_mau,
    trim(replace(replace(s.koc_kol, '@', ''), 'Vinhchinchu', 'vinhchinchu'))    as koc_kol,
    s.pic,
    trim(coalesce(nullif(s.phan_loai_creator, ''), 'L1'))                       as phan_loai_creator,
    s.nguon_yeu_cau,
    s.ten_san_pham,
    nullif(s.sl,'')::numeric::int                                               as sl,
    s.sheet,
    nullif(s.so_video,'')::numeric::int                                         as so_video,
    s.mst_cccd,
    s.ma_don_hang,
    s.vi_tri,
    nullif(s.cost,'')::numeric::int                                             as cost,
    s.sdt,
    nullif(trim(s.campaign_id),'')::numeric::int                                as campaign_id,
    nullif(trim(s.agency_id),'')::numeric::int                                  as agency_id,

    -- user_id thô từ nguồn — CHỈ để đối chiếu, không dùng tính toán trực tiếp
    nullif(trim(s.user_id),'')::numeric::int                                    as user_id_nguon,
    -- danh tính PIC dùng cho toàn bộ hạ nguồn
    coalesce(
        nullif(trim(s.user_id),'')::numeric::int,
        nullif(trim(m.user_id),'')::numeric::int
    )                                                                           as pic_user_id,
    nullif(trim(s.koc_booking_content_id),'')::numeric::int                     as koc_booking_content_id

from src s
-- Join KHỚP CHÍNH XÁC (không lower/trim): seed được sinh ra từ đúng giá trị `pic` thô
-- của bảng này, nên mọi chuẩn hoá thêm chỉ làm lệch khoá.
left join pic_map m on m.pic_trong_send_sample = s.pic
where s.koc_kol is not null and trim(s.koc_kol) <> ''
  and s.pic is not null and trim(s.pic) <> ''
