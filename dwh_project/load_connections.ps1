# ==========================================================================
# Đọc connections.env -> đặt biến môi trường cho dbt + cấu hình phụ trợ.
# Dùng (dot-source để biến ở lại trong phiên):
#     . .\load_connections.ps1
#     dbt build
# ==========================================================================
$ErrorActionPreference = "Stop"
$envFile = Join-Path $PSScriptRoot "connections.env"
if (-not (Test-Path $envFile)) {
    Write-Error "Không tìm thấy $envFile. Hãy copy connections.env.example -> connections.env và điền thông tin."
    return
}

Get-Content $envFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { return }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { return }
    $key = $line.Substring(0, $idx).Trim()
    $val = $line.Substring($idx + 1).Trim()
    # Bỏ dấu ngoặc bao ngoài nếu có: KEY="value" hoặc KEY='value'
    if ($val.Length -ge 2) {
        $first = $val.Substring(0, 1)
        $last  = $val.Substring($val.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $val = $val.Substring(1, $val.Length - 2)
        }
    }
    Set-Item -Path "Env:$key" -Value $val
}

# ---- Cấu hình phụ trợ cho dbt ----
$env:DBT_PROFILES_DIR = $PSScriptRoot         # profiles.yml nằm cùng thư mục
$env:PYTHONUTF8       = "1"                    # để dbt đọc comment tiếng Việt trên Windows
$env:SRC_DB           = $env:DEST_DB           # dbt đọc raw từ CÙNG database Postgres đích
$env:SRC_SCHEMA       = "raw"                  # schema chứa dữ liệu đã load
$env:PG_RAW_SCHEMA    = "raw"
if (-not $env:DEST_SCHEMA) { $env:DEST_SCHEMA = "staging" }

Write-Host "[connections] MySQL=$($env:MYSQL_HOST)/$($env:MYSQL_DB)  ->  Postgres=$($env:DEST_HOST)/$($env:DEST_DB) (raw schema: $($env:SRC_SCHEMA))" -ForegroundColor Green
