-- Staging: làm sạch 1-1 với bảng nguồn orders. Materialized = view (từ dbt_project.yml).
with source as (
    select * from {{ source('raw', 'orders') }}
),

renamed as (
    select
        id                as order_id,
        customer_id,
        total_amount,
        created_at::date  as order_date
    from source
    where total_amount is not null
)

select * from renamed
