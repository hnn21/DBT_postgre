-- Table_send_sample đầy đủ: base + các cột phái sinh (creator_id, prod_contain,
-- pic_rename, phan_loai_creator_fix, product_detail, ngay_ket_thuc). Bỏ cột `check`.
--
-- ĐÃ GỠ cột `team`: nó đến từ join pic_rename = pic_team.doi_ten, mà doi_ten KHÔNG
-- duy nhất (59 dòng -> 35 tên) nên join đó NHÂN BẢN mỗi dòng gửi mẫu tới 6 lần
-- (43.940 -> 117.461 dòng). Team nay lấy từ dim_pic qua pic_user_id nên không cần nữa.
with ss as (select * from {{ ref('stg_send_sample') }}),
pt as (select * from {{ ref('stg_pic_team') }}),
cr as (select * from {{ ref('map_creator_resolve') }}),

derived as (
    select
        ss.*,
        -- Danh tính creator TikTok, suy từ tên qua kho tích luỹ map_creator.
        -- Bảng gửi mẫu chỉ có TÊN (`KOC/KOL`), không có creator_id.
        cr.creator_id,
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
            when ss.ten_san_pham ilike '%sunscreen%' and ss.ten_san_pham ilike '%togishi%' then 'Kem chống nắng'
            when ss.ten_san_pham ilike '%COLD CREAM%' or ss.ten_san_pham ilike '%kem lạnh%' then 'Cold cream'
            when ss.ten_san_pham ilike '%FOAMING FACE WASH%' then 'FOAMING FACE WASH'
            when ss.ten_san_pham ilike '%WHITENING MOISTURE GEL%' then 'WHITENING MOISTURE GEL'
            when ss.ten_san_pham ilike '%adlay%' then 'ADLAY'
            when ss.ten_san_pham ilike '%kem ủ%' then 'Adolph kem ủ'
            when ss.ten_san_pham ilike '%adolph%' and ss.ten_san_pham ilike '%hair mask%' then 'Adolph kem ủ'
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
    left join cr on cr.creator_name_key = lower(trim(ss.koc_kol))
),

final as (
    select
        *,
        phan_loai_creator as phan_loai_creator_fix,
        case when sheet ilike '%adolph%' then prod_contain else ten_san_pham end as product_detail,
        -- ⚠️ PARTITION PHẢI THEO DANH TÍNH, KHÔNG THEO TÊN.
        -- Cả tính đúng đắn của campaign_id/PIC/Vị trí dựa trên bất biến: các lần gửi
        -- mẫu của cùng (creator, sản phẩm) xếp thành dải KHÔNG CHỒNG LẤN.
        -- Nếu partition theo `koc_kol`, một creator gửi mẫu 2 lần dưới 2 tên khác nhau
        -- sẽ thành 2 chuỗi riêng, CẢ HAI cùng có ngay_ket_thuc = 2099-12-31 -> khoảng
        -- hiệu lực chồng nhau -> video khớp cả 2 bản ghi và lấy nhầm giá trị của lần
        -- gửi mẫu CŨ HƠN. Sai im lặng, không báo lỗi. Đã đo: 97 cặp bị như vậy.
        -- coalesce chỉ để các dòng không tra ra creator_id khỏi bị dồn chung vào một
        -- partition NULL (khi đó dải hiệu lực của những creator khác nhau sẽ cắt nhau).
        lead(ngay_duyet_mau) over (
            partition by coalesce(creator_id, koc_kol), prod_contain
            order by ngay_duyet_mau
        ) as _next_date
    from derived
)

select
    *,
    case
        when _next_date is not null then (_next_date - interval '1 day')::date
        else date '2099-12-31'
    end as ngay_ket_thuc
from final
