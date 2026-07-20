{#
  Ghi đè hành vi mặc định của dbt (mặc định nối <target_schema>_<custom>).
  Ở đây dùng THẲNG tên +schema đã khai (staging / intermediate / marts).
  Model/seed KHÔNG khai +schema -> rơi vào schema đích (target.schema).
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema | trim }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
