-- Nhân sự nội bộ từ Postgres `krm` (public.users) — nguồn GỐC cho danh tính PIC.
--
-- LƯU Ý về `team`: đây là PHÒNG BAN CHỨC NĂNG (Affiliate / Growth / Partner / Adolph /
-- ChiShi / Ecom / PR DHC), KHÁC trục với nhóm báo cáo cũ trong `pic_team`
-- (Team c Hường / Team c Mai / TTS - Thảo / NB). Phần lớn tương ứng 1-1
-- (Team c Hường ≡ Affiliate, Team c Mai ≡ Partner, NB ≡ Adolph) nhưng nhóm TTS
-- KHÔNG có giá trị tương ứng trong enum `enum_users_team` -> còn trống.
with src as (select * from {{ source('raw','users') }})
select
    nullif(trim(id),'')::int        as user_id,
    nullif(trim(username),'')       as username,
    nullif(trim(team),'')           as team,
    nullif(trim(status),'')         as status
from src
where nullif(trim(id),'') is not null
