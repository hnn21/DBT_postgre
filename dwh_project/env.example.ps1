# ═══════════════════════════════════════════════════════════════════════════
# MẪU cấu hình một tổ hợp NGUỒN -> ĐÍCH.
# Cách dùng: copy file này thành env.<ten>.ps1 (vd env.AtoB.ps1), điền giá trị,
# rồi chạy:   . .\env.AtoB.ps1 ; dbt run
# LƯU Ý: đừng commit file chứa mật khẩu thật (đã có .gitignore loại env.*.ps1).
# ═══════════════════════════════════════════════════════════════════════════

# --- Cho dbt biết profiles.yml nằm ngay trong thư mục project này ---
$env:DBT_PROFILES_DIR = $PSScriptRoot

# --- Bắt buộc trên Windows: ép Python đọc file UTF-8 (comment tiếng Việt) ---
$env:PYTHONUTF8 = "1"

# ─── NGUỒN raw mà dbt ĐỌC (source) ──────────────────────────────
# Trỏ tới schema trên Postgres đích chứa dữ liệu đã load (mặc định 'raw').
$env:SRC_DB     = "dwh"
$env:SRC_SCHEMA = "raw"

# ─── MySQL (chỉ dùng cho bước EL el\load_raw.py) ─────────────────
$env:MYSQL_HOST     = "27.71.20.96"
$env:MYSQL_PORT     = "3306"
$env:MYSQL_DB       = "tiktok_dashboard"
$env:MYSQL_USER     = "CHANGE_ME"
$env:MYSQL_PASSWORD = "CHANGE_ME"
$env:PG_RAW_SCHEMA  = "raw"

# ─── ĐÍCH 'dev' (nơi ghi kết quả) ───────────────────────────────
$env:DEST_HOST     = "10.0.0.2"
$env:DEST_PORT     = "5432"
$env:DEST_DB       = "dwh"
$env:DEST_USER     = "dbt_user"
$env:DEST_PASSWORD = "CHANGE_ME"
$env:DEST_SCHEMA   = "staging"

# ─── ĐÍCH 'prod' (chỉ cần nếu dùng --target prod) ───────────────
# $env:PROD_HOST     = "10.0.0.9"
# $env:PROD_DB       = "analytics"
# $env:PROD_USER     = "dbt_user"
# $env:PROD_PASSWORD = "CHANGE_ME"

Write-Host "[env] Nguon: $env:SRC_DB.$env:SRC_SCHEMA  ->  Dich(dev): $env:DEST_HOST/$env:DEST_DB" -ForegroundColor Green
