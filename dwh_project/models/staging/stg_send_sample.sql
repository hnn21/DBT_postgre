with src as (select * from {{ source('raw','send_sample') }})
select
    nullif(ngay_duyet_mau,'')::date                                        as ngay_duyet_mau,
    trim(replace(replace(koc_kol, '@', ''), 'Vinhchinchu', 'vinhchinchu'))  as koc_kol,
    pic,
    trim(coalesce(nullif(phan_loai_creator, ''), 'L1'))                     as phan_loai_creator,
    nguon_yeu_cau,
    ten_san_pham,
    nullif(sl,'')::numeric::int                                             as sl,
    sheet,
    nullif(so_video,'')::numeric::int                                       as so_video,
    mst_cccd,
    ma_don_hang,
    vi_tri,
    nullif(cost,'')::numeric::int                                           as cost,
    sdt,
    campaign_id
from src
where koc_kol is not null and trim(koc_kol) <> ''
  and pic is not null and trim(pic) <> ''
