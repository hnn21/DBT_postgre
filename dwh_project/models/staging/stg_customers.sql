-- Staging: làm sạch 1-1 với bảng nguồn customers.
with source as (
    select * from {{ source('raw', 'customers') }}
),

renamed as (
    select
        id           as customer_id,
        lower(email) as email,
        full_name,
        created_at::date as signup_date
    from source
)

select * from renamed
