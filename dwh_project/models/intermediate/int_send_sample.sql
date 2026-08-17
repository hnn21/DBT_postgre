-- Table_send_sample đầy đủ: base + các cột phái sinh (prod_contain, pic_rename,
-- team, phan_loai_creator_fix, product_detail, ngay_ket_thuc). Bỏ cột `check`.
with ss as (select * from {{ ref('stg_send_sample') }}),
pt as (select * from {{ ref('stg_pic_team') }}),

derived as (
    select
        ss.*,
        -- prod_contain: luật SWITCH của Table_send_sample (thứ tự quan trọng)
        -- Giữ ĐỒNG BỘ 100% với SWITCH prod_contain trong mart_data.sql (join theo prod_contain).
        case
            when ss.ten_san_pham ilike '%b mix%' or ss.ten_san_pham ilike '%bmix%' or ss.ten_san_pham ilike '%b-mix%' then 'b mix'
            when ss.ten_san_pham ilike '%son dưỡng%' then 'son dưỡng'
            when ss.ten_san_pham ilike '%biotin%' then 'biotin'
            when ss.ten_san_pham ilike '%kẽm%' then 'kẽm'
            when ss.ten_san_pham ilike '%vitamin c%' then 'vitamin c'
            when ss.ten_san_pham ilike '%vitamin tổng%' then 'vitamin tổng hợp'
            when ss.ten_san_pham ilike '%canxi%' then 'canxi'
            when ss.ten_san_pham ilike '%dầu tẩy trang%' then 'dầu tẩy trang'
            when ss.ten_san_pham ilike '%kem chống nắng%' and ss.ten_san_pham ilike '%togishi%' then 'Kem chống nắng'
            when ss.ten_san_pham ilike '%vệ sinh nam%' then 'VSnam'
            when ss.ten_san_pham ilike '%wash gel%' and ss.ten_san_pham ilike '%togishi%' then 'VSnam'
            when ss.ten_san_pham ilike '%COLD CREAM%' or ss.ten_san_pham ilike '%kem lạnh%' then 'Cold cream'
            when ss.ten_san_pham ilike '%FOAMING FACE WASH%' then 'FOAMING FACE WASH'
            when ss.ten_san_pham ilike '%WHITENING MOISTURE GEL%' then 'WHITENING MOISTURE GEL'
            when ss.ten_san_pham ilike '%adlay%' then 'ADLAY'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%kem ủ%' then 'Adolph kem ủ'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%hộp%' then 'Adolph hộp quà'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%gội%' then 'Adolph gội'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%shampoo%' then 'Adolph gội'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%xả%' then 'Adolph xả'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%tinh dầu%' then 'Adolph tinh dầu'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%sữa tắm%' then 'Adolph sữa tắm'
            else null
        end as prod_contain,
        coalesce(pt.doi_ten, ss.pic) as pic_rename
    from ss
    left join pt on ss.pic = pt.raw_name
),

with_team as (
    select
        d.*,
        pt2.team
    from derived d
    left join pt pt2 on d.pic_rename = pt2.doi_ten
),

final as (
    select
        *,
        phan_loai_creator as phan_loai_creator_fix,
        case when sheet ilike '%adolph%' then prod_contain else ten_san_pham end as product_detail,
        lead(ngay_duyet_mau) over (partition by koc_kol, prod_contain order by ngay_duyet_mau) as _next_date
    from with_team
)

select
    *,
    case
        when _next_date is not null then (_next_date - interval '1 day')::date
        else date '2099-12-31'
    end as ngay_ket_thuc
from final
