-- CẢNH BÁO khi `user_id` từ nguồn KHÁC với kết quả tra theo tên PIC.
--
-- Kỳ vọng hiện tại: 337 dòng (PA-Partner / Ly - Partner / MA-Partner đều mang
-- user_id=74 vì Khánh Dư Hoàng nhập hộ — cột nguồn ghi NGƯỜI NHẬP, không phải PIC).
-- stg_send_sample ưu tiên nguồn, nên các dòng này thuộc về user 74.
-- Test giữ con số đó luôn hiển thị; nếu nó tăng bất thường thì cần xem lại.
{{ config(severity='warn') }}

select
    s.pic,
    s.user_id_nguon,
    m.user_id as user_id_theo_ten,
    count(*)  as so_dong
from {{ ref('stg_send_sample') }} s
join {{ ref('pic_user_map') }} m on m.pic_trong_send_sample = s.pic
where s.user_id_nguon is not null
  and s.user_id_nguon is distinct from nullif(trim(m.user_id),'')::numeric::int
group by s.pic, s.user_id_nguon, m.user_id
