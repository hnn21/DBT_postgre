-- CẢNH BÁO khi bảng gửi mẫu có giá trị `pic` chưa nằm trong seed pic_user_map.
--
-- Hôm nay seed phủ 100% (56/56 giá trị). Nhưng nhân sự mới, hoặc một cách gõ tên mới,
-- sẽ làm thủng mà KHÔNG có gì báo: pic_user_id thành NULL và dòng đó mất PIC lặng lẽ.
-- severity=warn vì đây là việc bổ sung seed, không phải lỗi pipeline.
{{ config(severity='warn') }}

select
    s.pic,
    count(*) as so_dong
from {{ ref('stg_send_sample') }} s
where s.pic_user_id is null
group by s.pic
