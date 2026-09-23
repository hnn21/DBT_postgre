-- Dimension PIC cho Power BI: join dim_pic[user_id] -> mart_data_agg[pic_user_id].
--
-- ⚠️ `team_phong_ban` hiện CHƯA ĐỦ: nhóm TTS không có giá trị tương ứng trong enum
-- `enum_users_team` của DB krm, nên các user đó còn trống team. Cần xử lý ở nguồn
-- (ALTER TYPE ... ADD VALUE 'TTS', hoặc gộp vào Growth) — không xử lý được từ dbt.
select
    user_id,
    username,
    team as team_phong_ban,
    status
from {{ ref('stg_users') }}
