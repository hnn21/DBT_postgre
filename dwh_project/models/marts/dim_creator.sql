-- Dimension creator cho Power BI: 1 dòng / creator_id, tên MỚI NHẤT.
-- Nguồn là map_creator (~54k dòng) nên rẻ, không đụng bảng lớn.
--
-- "Mới nhất" = tên có last_seen lớn nhất. Tie-break bằng creator_name để kết quả
-- TẤT ĐỊNH (cùng idiom max(...) đang dùng ở pic_pick/vm_pick trong mart_data).
with xep as (
    select
        creator_id,
        creator_name,
        last_seen,
        row_number() over (
            partition by creator_id
            order by last_seen desc, creator_name desc
        ) as rn
    from {{ ref('map_creator') }}
)
select
    creator_id,
    creator_name,
    last_seen as ten_thay_lan_cuoi
from xep
where rn = 1
