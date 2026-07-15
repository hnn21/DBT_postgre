-- Bảng rộng KẾT QUẢ: tái tạo bảng `data` của Power BI = cột gốc performance_list
-- + 14 cột tính toán. Materialized = table (schema marts) trên server đích.
{{ config(materialized='table') }}

with base as (select * from {{ ref('stg_performance_list') }}),
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
            when b.product_name ilike '%COLD CREAM%' or b.product_name ilike '%kem lạnh%' then 'Cold cream'
            when b.product_name ilike '%FOAMING FACE WASH%' then 'FOAMING FACE WASH'
            when b.product_name ilike '%WHITENING MOISTURE GEL%' then 'WHITENING MOISTURE GEL'
            when b.product_name ilike '%adlay%' then 'ADLAY'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%kem ủ%' then 'Adolph kem ủ'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%hộp quà%' then 'Adolph hộp quà'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%gội%' then 'Adolph gội'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%xả%' then 'Adolph xả'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%tinh dầu%' then 'Adolph tinh dầu'
            when b.product_name ilike '%adolph%' and b.product_name ilike '%sữa tắm%' then 'Adolph sữa tắm'
            else null
        end as prod_contain
    from base b
    left join pmap p on b.video_id = p.video_id
),

-- (2) prod_contain_combo, (5) Loại video
with_cols as (
    select
        prod.*,
        case when _map_combo ilike '%combo%' then _map_combo else prod_contain end as prod_contain_combo,
        case when video_id in (select video_id from agency) then 'Video AI' else 'Video thường' end as "Loại video"
    from prod
),

-- (3) Ngày gửi mẫu = MIN(ngay_duyet_mau) khớp creator+prod, SL>0
gui_mau as (
    select
        w.*,
        (select min(s.ngay_duyet_mau)
         from send s
         where s.koc_kol = w.creator_name
           and s.prod_contain = w.prod_contain
           and s.sl > 0
           and length(s.prod_contain) > 0) as "Ngày gửi mẫu"
    from with_cols w
),

-- (4) duration_date (dùng run_date thay TODAY())
duration as (
    select
        g.*,
        case
            when g."Ngày gửi mẫu" is null then -1
            when g."Ngày gửi mẫu" > g.time then -1
            else case
                when ({{ run_date() }} - g.time) <= 30 then 7
                when ({{ run_date() }} - g.time) <= 60 then 6
                when (g.time - g."Ngày gửi mẫu") <= 7 then 1
                when (g.time - g."Ngày gửi mẫu") <= 14 then 2
                when (g.time - g."Ngày gửi mẫu") <= 30 then 3
                when (g.time - g."Ngày gửi mẫu") <= 90 then 4
                else 5
            end
        end as duration_date
    from gui_mau g
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

-- (7) Phân loại Creator: TOPN theo priority nhỏ nhất trong khoảng thời gian khớp
pl_ranked as (
    select
        p.video_id,
        s.phan_loai_creator_fix,
        case s.phan_loai_creator_fix
            when 'S+' then 1 when 'T' then 2 when 'S' then 3 when 'M' then 4
            when 'L2' then 5 when 'L1' then 6 when 'L0' then 7
            when 'L1.2' then 8 when 'L1.1' then 9 else 999
        end as priority
    from pfm p
    join send s
      on s.koc_kol = p.creator_name
     and s.prod_contain = p.prod_contain
     and s.ngay_duyet_mau <= p.time
     and (s.ngay_ket_thuc is null or p.time <= s.ngay_ket_thuc)
),

pl_pick as (
    select
        video_id,
        max(phan_loai_creator_fix) filter (where priority = min_priority) as picked
    from (
        select r.*, min(priority) over (partition by video_id) as min_priority
        from pl_ranked r
    ) z
    group by video_id
),

phanloai as (
    select
        p.*,
        case
            when p.prod_contain is null or length(p.prod_contain) = 0 then 'Thiếu dữ liệu tên SP'
            else coalesce(
                case p."video_duoctinhPFM"
                    when 1 then (select v.phan_loai_creator from valid v where v.phan_loai_creator = pp.picked)
                    when 0 then 'Organic'
                end, 'Organic')
        end as "Phân loại Creator"
    from pfm p
    left join pl_pick pp on p.video_id = pp.video_id
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

-- (11) PIC: bản ghi gửi mẫu sớm nhất (SL>0) khớp creator+prod trong khoảng thời gian
pic_pick as (
    select
        g.video_id,
        max(s.pic_rename) filter (where s.ngay_duyet_mau = s.mn) as "PIC"
    from grp g
    join lateral (
        select ss.pic_rename, ss.ngay_duyet_mau,
               min(ss.ngay_duyet_mau) over () as mn
        from send ss
        where ss.koc_kol = g.creator_name
          and ss.prod_contain = g.prod_contain
          and ss.sl > 0
          and ss.prod_contain is not null and length(ss.prod_contain) > 0
          and ss.koc_kol is not null and length(ss.koc_kol) > 0
          and ss.ngay_duyet_mau <= g.time
          and g.time <= ss.ngay_ket_thuc
    ) s on true
    group by g.video_id
),

-- (13)(14) Vị trí, Mẫu gửi: bản ghi sớm nhất khớp creator+prod (KHÔNG lọc SL)
vitri_maugui_pick as (
    select
        g.video_id,
        max(s.vi_tri)         filter (where s.ngay_duyet_mau = s.mn) as "Vị trí",
        max(s.product_detail) filter (where s.ngay_duyet_mau = s.mn) as "Mẫu gửi"
    from grp g
    join lateral (
        select ss.vi_tri, ss.product_detail, ss.ngay_duyet_mau,
               min(ss.ngay_duyet_mau) over () as mn
        from send ss
        where ss.koc_kol = g.creator_name
          and ss.prod_contain = g.prod_contain
          and ss.ngay_duyet_mau <= g.time
          and g.time <= ss.ngay_ket_thuc
    ) s on true
    group by g.video_id
),

final as (
    select
        g.*,
        pp."PIC",
        -- (12) Team theo PIC (FIRSTNONBLANK ~ max không rỗng)
        (select max(s.team) from send s
         where s.pic_rename = pp."PIC" and s.team is not null and s.team <> '') as "Team",
        vm."Vị trí",
        vm."Mẫu gửi"
    from grp g
    left join pic_pick pp on g.video_id = pp.video_id
    left join vitri_maugui_pick vm on g.video_id = vm.video_id
)

select * from final
