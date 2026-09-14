-- Bảng rộng KẾT QUẢ: tái tạo bảng `data` của Power BI = cột gốc performance_list
-- + 14 cột tính toán. Materialized = table (schema marts) trên server đích.
--
-- QUAN TRỌNG: `data` có ~4.87M dòng nhưng chỉ ~190k video_id (snapshot lặp).
-- Các cột phái sinh trong DAX là ROW column phụ thuộc (creator_name, prod_contain, time).
-- Vì vậy ta tính "pick" ở grain DISTINCT (creator_name, prod_contain, time) rồi JOIN
-- ngược về từng dòng — vừa ĐÚNG (không gộp nhầm theo video_id) vừa nhanh (tránh
-- subquery tương quan trên 4.87M dòng).
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key=['video_id', 'date_file_excel'],
    on_schema_change='append_new_columns',
    pre_hook=["set work_mem = '256MB'", "set jit = off", "set enable_mergejoin = off"],
    post_hook=["set enable_mergejoin = on"]
) }}
-- enable_mergejoin=off: ÉP hash join cho bước ráp cuối (enriched ⋈ picks).
-- Nếu để mặc định, planner ước tính sai và SORT cả bảng rộng 5M dòng
-- (external merge ~2GB ra đĩa, ~85% thời gian). picks là CTE materialized nhỏ
-- (≤~170k dòng) nên các join range nội bộ vẫn nhanh dù chạy bằng hash. post_hook
-- bật lại để không ảnh hưởng model khác dùng chung connection.

-- INCREMENTAL (cửa sổ mặc định 90 ngày, chỉnh khi chạy bằng --vars incr_days):
--   • Full-refresh: xử lý toàn bộ. Incremental: chỉ nạp lại các file gần đây.
--   • Cửa sổ N ngày vừa gồm dòng MỚI (date_file_excel mới), vừa nạp lại các dòng
--     mà duration_date còn "trôi" theo current_date (chỉ khi time >= today-60).
--     => KHÔNG đặt incr_days < 60 (sẽ bỏ sót dòng còn trôi ở mốc <=60).
--     Dòng time cũ hơn ổn định → không cần đụng. delete+insert theo
--     (video_id, date_file_excel) xoá đúng phần trong cửa sổ rồi nạp lại.
with base as (
    select * from {{ ref('stg_performance_list') }}
    {% if is_incremental() %}
    where date_file_excel >= current_date - {{ var('incr_days', 90) | int }}
    {% endif %}
),
pmap as (select * from {{ ref('stg_product_name_map') }}),
agency as (select distinct video_id from {{ ref('videos_id_agency') }}),
send as (select * from {{ ref('int_send_sample') }}),
valid as (select distinct phan_loai_creator from {{ ref('int_valid_classification') }}),

-- (1) prod_contain: lookup map theo video_id; nếu trống -> luật SWITCH của `data`
prod as (
    select
        b.*,
        p.product_contain_combo as _map_combo,
        case
            when nullif(p.product_contain, '') is not null then p.product_contain
            when b.product_name ilike '%b mix%' or b.product_name ilike '%bmix%' or b.product_name ilike '%b-mix%' then 'b mix'
            when b.product_name ilike '%son dưỡng%' then 'son dưỡng'
            when b.product_name ilike '%biotin%' then 'biotin'
            when b.product_name ilike '%kẽm%' then 'kẽm'
            when b.product_name ilike '%vitamin c%' then 'vitamin c'
            when b.product_name ilike '%vitamin tổng%' then 'vitamin tổng hợp'
            when b.product_name ilike '%canxi%' then 'canxi'
            when b.product_name ilike '%dầu tẩy trang%' then 'dầu tẩy trang'
            when b.product_name ilike '%kem chống nắng%' and b.product_name ilike '%togishi%' then 'Kem chống nắng'
            when b.product_name ilike '%vệ sinh nam%' then 'VSnam'
            when b.product_name ilike '%wash gel%' and b.product_name ilike '%togishi%' then 'VSnam'
            when b.product_name ilike '%COLD CREAM%' or b.product_name ilike '%kem lạnh%' then 'Cold cream'
            when b.product_name ilike '%FOAMING FACE WASH%' then 'FOAMING FACE WASH'
            when b.product_name ilike '%WHITENING MOISTURE GEL%' then 'WHITENING MOISTURE GEL'
            when b.product_name ilike '%adlay%' then 'ADLAY'
            when b.product_name ilike '%kem ủ%' then 'Adolph kem ủ'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%hair mask%' then 'Adolph kem ủ'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%hộp%' then 'Adolph hộp quà'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%gội%' then 'Adolph gội'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%shampoo%' then 'Adolph gội'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%xả%' then 'Adolph xả'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%tinh dầu%' then 'Adolph tinh dầu'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%sữa tắm%' then 'Adolph sữa tắm'
            else null
        end as prod_contain
    from base b
    left join pmap p on b.video_id = p.video_id
),

-- (2) prod_contain_combo, (5) Loại video  — row level
enriched as (
    select
        prod.*,
        case when _map_combo ilike '%combo%' then _map_combo else prod_contain end as prod_contain_combo,
        case when video_id in (select video_id from agency) then 'Video AI' else 'Video thường' end as "Loại video"
    from prod
),

-- ── Các grain rút gọn để tính pick ────────────────────────────────
keys_cpt as (
    select distinct creator_name, prod_contain, time
    from enriched
    where prod_contain is not null and time is not null
),

-- (3) Ngày gửi mẫu = MIN(ngay_duyet_mau) theo (creator, prod), SL>0
gui_mau_map as (
    -- Gom theo lower(koc_kol) để khớp creator KHÔNG phân biệt hoa/thường (như DAX)
    -- và tránh fan-out nếu send có cả 'Abc' lẫn 'abc'.
    select lower(s.koc_kol) as creator_key, s.prod_contain, min(s.ngay_duyet_mau) as ngay_gui_mau
    from send s
    where s.sl > 0 and s.prod_contain is not null and length(s.prod_contain) > 0
    group by lower(s.koc_kol), s.prod_contain
),

-- (7) picked classification theo (creator, prod, time): priority nhỏ nhất -> max(fix)
pl_ranked as (
    select
        k.creator_name, k.prod_contain, k.time,
        s.phan_loai_creator_fix,
        case s.phan_loai_creator_fix
            when 'S+' then 1 when 'T' then 2 when 'S' then 3 when 'M' then 4
            when 'L2' then 5 when 'L1' then 6 when 'L0' then 7
            when 'L1.2' then 8 when 'L1.1' then 9 else 999
        end as priority
    from keys_cpt k
    join send s
      on lower(s.koc_kol) = lower(k.creator_name)   -- khớp KHÔNG phân biệt hoa/thường (như DAX)
     and s.prod_contain = k.prod_contain
     and s.ngay_duyet_mau <= k.time
     and (s.ngay_ket_thuc is null or k.time <= s.ngay_ket_thuc)
),
pl_pick as (
    select creator_name, prod_contain, time,
           max(phan_loai_creator_fix) filter (where priority = min_priority) as picked
    from (
        select r.*, min(priority) over (partition by creator_name, prod_contain, time) as min_priority
        from pl_ranked r
    ) z
    group by creator_name, prod_contain, time
),
pl_pick_v as (
    select p.creator_name, p.prod_contain, p.time, p.picked,
           case when v.phan_loai_creator is not null then p.picked else null end as group_value
    from pl_pick p
    left join valid v on p.picked = v.phan_loai_creator
),

-- (11) PIC theo (creator, prod, time): bản ghi SL>0 có ngay_duyet_mau sớm nhất -> max(pic_rename)
pic_ranked as (
    select k.creator_name, k.prod_contain, k.time, s.pic_rename, s.ngay_duyet_mau
    from keys_cpt k
    join send s
      on lower(s.koc_kol) = lower(k.creator_name)   -- khớp KHÔNG phân biệt hoa/thường (như DAX)
     and s.prod_contain = k.prod_contain
     and s.sl > 0
     and length(s.prod_contain) > 0 and length(s.koc_kol) > 0
     and s.ngay_duyet_mau <= k.time
     and k.time <= s.ngay_ket_thuc
),
pic_pick as (
    select creator_name, prod_contain, time,
           max(pic_rename) filter (where ngay_duyet_mau = mn) as "PIC"
    from (
        select r.*, min(ngay_duyet_mau) over (partition by creator_name, prod_contain, time) as mn
        from pic_ranked r
    ) z
    group by creator_name, prod_contain, time
),

-- (13)(14)(15) Vị trí, Mẫu gửi, nguon_yeu_cau theo (creator, prod, time): LỌC SL>0
vm_ranked as (
    select k.creator_name, k.prod_contain, k.time, s.vi_tri, s.product_detail, s.nguon_yeu_cau, s.campaign_id, s.ngay_duyet_mau
    from keys_cpt k
    join send s
      on lower(s.koc_kol) = lower(k.creator_name)   -- khớp KHÔNG phân biệt hoa/thường (như DAX)
     and s.prod_contain = k.prod_contain
     and s.sl > 0
     and s.ngay_duyet_mau <= k.time
     and k.time <= s.ngay_ket_thuc
),
vm_pick as (
    select creator_name, prod_contain, time,
           max(vi_tri)         filter (where ngay_duyet_mau = mn) as "Vị trí",
           max(product_detail) filter (where ngay_duyet_mau = mn) as "Mẫu gửi",
           max(nguon_yeu_cau)  filter (where ngay_duyet_mau = mn) as nguon_yeu_cau,
           max(campaign_id)    filter (where ngay_duyet_mau = mn) as campaign_id
    from (
        select r.*, min(ngay_duyet_mau) over (partition by creator_name, prod_contain, time) as mn
        from vm_ranked r
    ) z
    group by creator_name, prod_contain, time
),

-- (12) Team theo PIC (FIRSTNONBLANK ~ max không rỗng)
team_map as (
    select pic_rename, max(team) as team
    from send
    where team is not null and team <> ''
    group by pic_rename
),

-- ── Gộp toàn bộ "pick" về 1 bảng hẹp cùng grain (creator, prod, time) ──
-- keys_cpt là "xương sống" (~45k dòng); các pick LEFT JOIN vào đây. Nhờ vậy
-- bước ráp cuối chỉ còn 1 join enriched⋈picks (khối nhỏ ~45k) → Postgres chọn
-- HASH JOIN, KHÔNG phải sort cả bảng rộng 5M dòng (trước đây tốn ~85% thời gian
-- do external merge sort 2GB ra đĩa). Kết quả từng cột giữ nguyên: mỗi dòng
-- enriched có đúng 1 (creator,prod,time) nên LEFT JOIN cho giá trị y hệt bản cũ.
picks as materialized (
    select
        k.creator_name, k.prod_contain, k.time,
        plv.group_value as _group_value,
        pp."PIC"        as _pic,
        vm."Vị trí"     as _vi_tri,
        vm."Mẫu gửi"    as _mau_gui,
        vm.nguon_yeu_cau as _nguon_yeu_cau,
        vm.campaign_id   as _campaign_id
    from keys_cpt k
    left join pl_pick_v plv
      on k.creator_name = plv.creator_name and k.prod_contain = plv.prod_contain and k.time = plv.time
    left join pic_pick pp
      on k.creator_name = pp.creator_name and k.prod_contain = pp.prod_contain and k.time = pp.time
    left join vm_pick vm
      on k.creator_name = vm.creator_name and k.prod_contain = vm.prod_contain and k.time = vm.time
),

-- ── Ráp về từng dòng ──────────────────────────────────────────────
j as (
    select
        e.*,
        gm.ngay_gui_mau                 as "Ngày gửi mẫu",
        pk._group_value                 as _group_value,
        pk._pic                         as _pic,
        pk._vi_tri                      as _vi_tri,
        pk._mau_gui                     as _mau_gui,
        pk._nguon_yeu_cau               as _nguon_yeu_cau,
        pk._campaign_id                 as _campaign_id
    from enriched e
    left join gui_mau_map gm
      on lower(e.creator_name) = gm.creator_key and e.prod_contain = gm.prod_contain
    left join picks pk
      on e.creator_name = pk.creator_name and e.prod_contain = pk.prod_contain and e.time = pk.time
),

-- (4) duration_date: DẤU thỏa/không, TĨNH (không phụ thuộc run_date -> không "trôi").
--       1  = có mẫu và time >= Ngày gửi mẫu (video lên sau khi gửi mẫu = thỏa)
--      -1  = không có mẫu, hoặc time < Ngày gửi mẫu (không thỏa)
--     range_date: cho MỌI dòng (không phụ thuộc duration_date), bucket theo
--       (date_file_excel - time) = tuổi video tại thời điểm snapshot (số ngày từ
--       khi video lên sóng tới ngày file). Cũng TĨNH -> không có cột nào trôi theo run_date.
duration as (
    select
        j.*,
        case
            when j."Ngày gửi mẫu" is null then -1
            when j.time >= j."Ngày gửi mẫu" then 1
            else -1
        end as duration_date,
        case
            when j.time is null then null
            when (j.date_file_excel::date - j.time::date) <= 7   then 7
            when (j.date_file_excel::date - j.time::date) <= 14  then 14
            when (j.date_file_excel::date - j.time::date) <= 30  then 30
            when (j.date_file_excel::date - j.time::date) <= 60  then 60
            when (j.date_file_excel::date - j.time::date) <= 90  then 90
            when (j.date_file_excel::date - j.time::date) <= 180 then 180
            else 999                                   -- > 180 ngày (6 tháng+)
        end as range_date
    from j
),

-- (6) video_duoctinhPFM, (9)(10) 2 cột ĐK
pfm as (
    select
        d.*,
        case when d.video_id in (select video_id from agency) or d.duration_date > 0 then 1 else 0 end as "video_duoctinhPFM",
        case when d.duration_date > 0 then 'Có gửi mẫu' else 'Ko gửi mẫu' end as "DK Creator được gửi mẫu",
        case when d.duration_date > 0 then 'Thỏa mãn ĐK thời gian là sau khi gửi mẫu' else 'Không tính' end as "DK Time air video"
    from duration d
),

-- (7) Phân loại Creator (dùng _group_value đã validate + cờ PFM)
phanloai as (
    select
        p.*,
        case
            when p.prod_contain is null or length(p.prod_contain) = 0 then 'Thiếu dữ liệu tên SP'
            else coalesce(
                case p."video_duoctinhPFM"
                    when 1 then p._group_value
                    when 0 then 'Organic'
                end, 'Organic')
        end as "Phân loại Creator"
    from pfm p
),

-- (8) Group creator
grp as (
    select
        ph.*,
        case
            when ph."Phân loại Creator" ilike '%L0%' then 'L0'
            when ph."Phân loại Creator" ilike '%L1%' then 'L1'
            when ph."Phân loại Creator" ilike '%L2%' then 'L2'
            else ph."Phân loại Creator"
        end as "Group creator"
    from phanloai ph
),

final as (
    select
        -- 24 cột gốc (performance_list)
        g.creator_id, g.video_id, g.time, g.creator_name, g.product_name,
        g.vv, g.comment, g.share, g.new_follower, g.clicks_from_view_to_like,
        g.product_impressions, g.click_on_the_product, g.customer, g.count_order,
        g.unit_sales, g.video_revenue, g.gpm, g.gmv, g.ctr,
        g.view_to_like_ratio, g.video_viewing_rate, g.co_ratio, g.date_file_excel, g.brand,
        -- 16 cột tính toán
        g.prod_contain,
        g.prod_contain_combo,
        g."Loại video",
        g."Ngày gửi mẫu",
        g.duration_date,
        g.range_date,
        g."video_duoctinhPFM",
        g."DK Creator được gửi mẫu",
        g."DK Time air video",
        g."Phân loại Creator",
        g."Group creator",
        g._pic     as "PIC",
        tm.team    as "Team",
        g._vi_tri  as "Vị trí",
        g._mau_gui as "Mẫu gửi",
        g._nguon_yeu_cau as nguon_yeu_cau,
        g._campaign_id   as campaign_id
    from grp g
    left join team_map tm on g._pic = tm.pic_rename
)

select * from final
