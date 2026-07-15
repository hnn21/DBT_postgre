{#
  run_date(): ngày dùng thay cho TODAY() của DAX.
  Mặc định = current_date (ngày chạy dbt). Ghi đè để test/đối chiếu bằng:
    dbt build --vars '{run_date: "2025-03-20"}'
#}
{% macro run_date() %}
  coalesce(nullif('{{ var("run_date", "") }}', '')::date, current_date)
{% endmacro %}
