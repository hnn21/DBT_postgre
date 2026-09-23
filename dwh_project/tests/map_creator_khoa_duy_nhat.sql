-- (creator_id, creator_name_key) phải là khoá DUY NHẤT của map_creator.
-- Viết tay thay vì dùng dbt_utils.unique_combination_of_columns để không phải
-- thêm dependency mới cho project chỉ vì một test.
select creator_id, creator_name_key, count(*) as so_dong
from {{ ref('map_creator') }}
group by creator_id, creator_name_key
having count(*) > 1
