-- Lọc ra các creator_name PHÂN GIẢI ĐƯỢC DUY NHẤT về một creator_id.
--
-- TẠI SAO LỌC Ở ĐÂY (lúc đọc) chứ không "nướng" vào map_creator (lúc ghi):
--   Tập tên nhập nhằng CHỈ TĂNG theo thời gian — một tên sạch hôm nay có thể bị
--   creator khác dùng lại tháng sau. Lọc lúc đọc thì tên vừa trở nên nhập nhằng sẽ
--   TỰ ĐỘNG rụng khỏi đây, không còn gán nhầm người. Nướng vào lúc ghi thì bảng
--   tích luỹ giữ lại ánh xạ đã sai và không có cách nào biết.
--
-- Hôm nay có 8 tên bị loại: annaoi.beauty, bioslifehatrang, chidepthichreview,
-- embethoreview, kieucamnhu, nulamini, onnicosmetic.vn, tho_review25.
-- Chúng hiện khớp CẢ HAI creator (một trong hai chắc chắn sai); sau thay đổi thì
-- không khớp ai. Đây là đánh đổi có chủ ý.
{{ config(materialized='view') }}

select
    creator_name_key,
    min(creator_id) as creator_id    -- chỉ có 1 giá trị nhờ HAVING bên dưới
from {{ ref('map_creator') }}
group by creator_name_key
having count(distinct creator_id) = 1
