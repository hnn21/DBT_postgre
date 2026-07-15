-- ═══════════════════════════════════════════════════════════════════════════
-- Chạy MỘT LẦN trên SERVER ĐÍCH (quyền superuser) để nối sang server NGUỒN.
-- Chỉ cần nếu bạn dùng CÁCH A (postgres_fdw). Bỏ qua nếu load raw sẵn.
-- Thay <...> bằng giá trị thật.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. Bật extension
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- 2. Khai báo server NGUỒN
CREATE SERVER IF NOT EXISTS src_server
  FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '<IP_SERVER_NGUON>', port '5432', dbname '<DB_NGUON>');

-- 3. Ánh xạ tài khoản: dbt_user (trên đích) -> tài khoản readonly (trên nguồn)
CREATE USER MAPPING IF NOT EXISTS FOR dbt_user
  SERVER src_server
  OPTIONS (user '<USER_NGUON>', password '<PASS_NGUON>');

-- 4. Import bảng nguồn thành bảng ảo trong schema raw_ext
CREATE SCHEMA IF NOT EXISTS raw_ext;
IMPORT FOREIGN SCHEMA public          -- schema bên nguồn
  FROM SERVER src_server
  INTO raw_ext;                       -- khớp SRC_SCHEMA=raw_ext trong env.*.ps1

-- 5. Quyền cho dbt_user
GRANT USAGE ON SCHEMA raw_ext TO dbt_user;
GRANT SELECT ON ALL TABLES IN SCHEMA raw_ext TO dbt_user;

-- (Tùy chọn) Nhiều nguồn: lặp lại bước 2-5 với src_server2 -> schema raw_ext_c,
-- rồi chạy dbt với:  dbt run --vars '{raw_schema: raw_ext_c}'
