-- Whitelist phân loại creator hợp lệ (tương đương dim_phanloai_creator trong Power BI).
with base as (
    select distinct phan_loai_creator
    from {{ ref('stg_send_sample') }}
    where phan_loai_creator is not null
      and trim(phan_loai_creator) <> ''
      and phan_loai_creator not ilike '%quà%'
      and phan_loai_creator not ilike '%nghiệm%'
      and phan_loai_creator not ilike '%house%'
),
extra as (
    select unnest(array['T','L2.1','L2.2']) as phan_loai_creator
)
select phan_loai_creator from base
union
select phan_loai_creator from extra
