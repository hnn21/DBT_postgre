-- Mart: bảng KẾT QUẢ cuối, vật lý hóa (table) vào schema 'marts' trên server ĐÍCH.
{{ config(materialized='table') }}

select
    o.order_date,
    count(*)              as num_orders,
    count(distinct o.customer_id) as num_customers,
    sum(o.total_amount)   as revenue
from {{ ref('stg_orders') }} o
group by o.order_date
order by o.order_date
