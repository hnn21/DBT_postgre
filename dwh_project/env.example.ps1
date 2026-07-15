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

# ─── NGUỒN raw (đọc qua source()) ───────────────────────────────
# Với FDW: SRC_DB = database đích, SRC_SCHEMA = schema chứa bảng ảo (vd raw_ext).
# Với load-sẵn: trỏ tới schema đã đổ raw vào.
$env:SRC_DB     = "dwh"
$env:SRC_SCHEMA = "raw_ext"

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
