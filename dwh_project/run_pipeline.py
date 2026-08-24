"""
Chạy pipeline dbt tự động mỗi ngày: load_raw -> dbt build (mart_data+).

Tự nạp connections.env + set env cho dbt (thay cho load_connections.ps1),
dùng đường dẫn tuyệt đối của venv nên KHÔNG cần "activate".

CÁCH DÙNG (mở PowerShell/CMD bất kỳ, không cần activate):
    # chạy ngay 1 lần
    D:\PTDL\DBT_postgre\venv\Scripts\python.exe D:\PTDL\DBT_postgre\dwh_project\run_pipeline.py

    # đăng ký chạy TỰ ĐỘNG mỗi ngày lúc RUN_TIME (Windows Task Scheduler)
    ... run_pipeline.py --install

    # gỡ lịch tự động
    ... run_pipeline.py --uninstall

    # xem lịch đã đăng ký
    ... run_pipeline.py --status

Đổi giờ chạy / tham số build: sửa phần CONFIG bên dưới rồi chạy lại --install.
"""

import json
import os
import subprocess
import sys
from datetime import datetime

# ============================ CONFIG (CHỈNH Ở ĐÂY) ============================
RUN_TIME   = "06:00"        # giờ chạy mỗi ngày, định dạng HH:MM (24h) — dùng khi --install
LOAD_DAYS  = 7              # load_raw --days N  (performance_list N ngày; send_sample luôn full)
INCR_DAYS  = 7              # mart_data: --vars incr_days (cửa sổ ngày)
AGG_MONTHS = None           # mart_data_agg: None = mặc định (tháng hiện tại + tháng trước);
                            #   hoặc ["2026-08"] / ["2026-07", "2026-08"] để chỉ định tháng
TASK_NAME  = "dbt_daily_marts"   # tên task trong Windows Task Scheduler
# =============================================================================

# ---- Đường dẫn (suy ra từ vị trí file này: .../dwh_project/run_pipeline.py) ----
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))          # D:\PTDL\DBT_postgre\dwh_project
REPO_DIR    = os.path.dirname(PROJECT_DIR)                          # D:\PTDL\DBT_postgre
VENV_SCRIPTS = os.path.join(REPO_DIR, "venv", "Scripts")
PYTHON_EXE  = os.path.join(VENV_SCRIPTS, "python.exe")
DBT_EXE     = os.path.join(VENV_SCRIPTS, "dbt.exe")
ENV_FILE    = os.path.join(PROJECT_DIR, "connections.env")
LOG_DIR     = os.path.join(PROJECT_DIR, "logs", "daily")


def build_env():
    """Nạp connections.env + set các biến phụ trợ (tái tạo load_connections.ps1)."""
    env = os.environ.copy()
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                    v = v[1:-1]
                env[k] = v
    else:
        raise SystemExit(f"Không tìm thấy {ENV_FILE}")
    # phụ trợ cho dbt (giống load_connections.ps1)
    env["DBT_PROFILES_DIR"] = PROJECT_DIR
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    env["SRC_DB"] = env.get("DEST_DB", "")
    env["SRC_SCHEMA"] = "raw"
    env["PG_RAW_SCHEMA"] = "raw"
    env.setdefault("DEST_SCHEMA", "staging")
    return env


def dbt_vars():
    """Ghép --vars từ CONFIG. AGG_MONTHS=None -> chỉ incr_days (agg dùng mặc định 2 tháng)."""
    v = {"incr_days": INCR_DAYS}
    if AGG_MONTHS:
        v["agg_months"] = AGG_MONTHS
    return json.dumps(v)


def _run(cmd, env, log):
    """Chạy 1 lệnh, in + ghi log, raise nếu lỗi."""
    line = ">>> " + " ".join(cmd)
    print(line, flush=True); log.write(line + "\n"); log.flush()
    p = subprocess.run(cmd, cwd=PROJECT_DIR, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, encoding="utf-8", errors="replace")
    print(p.stdout, flush=True); log.write(p.stdout + "\n"); log.flush()
    if p.returncode != 0:
        raise SystemExit(f"LỖI: lệnh trả về mã {p.returncode}, dừng pipeline.")


def run_pipeline():
    env = build_env()
    os.makedirs(LOG_DIR, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = os.path.join(LOG_DIR, f"run_{stamp}.log")
    with open(log_path, "w", encoding="utf-8") as log:
        header = f"===== PIPELINE START {datetime.now():%Y-%m-%d %H:%M:%S} =====\n" \
                 f"LOAD_DAYS={LOAD_DAYS} INCR_DAYS={INCR_DAYS} AGG_MONTHS={AGG_MONTHS}\n"
        print(header, flush=True); log.write(header + "\n"); log.flush()
        # 1) EL: nạp raw
        _run([PYTHON_EXE, os.path.join("el", "load_raw.py"),
              "--tables", "performance_list", "send_sample", "--days", str(LOAD_DAYS)], env, log)
        # 2) dbt build
        _run([DBT_EXE, "build", "-s", "mart_data+", "--vars", dbt_vars()], env, log)
        done = f"===== PIPELINE OK {datetime.now():%Y-%m-%d %H:%M:%S} =====\n"
        print(done, flush=True); log.write(done); log.flush()
    print(f"Log: {log_path}", flush=True)


def install():
    """Đăng ký Task Scheduler chạy mỗi ngày lúc RUN_TIME."""
    tr = f'"{PYTHON_EXE}" "{os.path.abspath(__file__)}"'
    cmd = ["schtasks", "/Create", "/SC", "DAILY", "/ST", RUN_TIME,
           "/TN", TASK_NAME, "/TR", tr, "/F"]
    print(">>> " + " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)
    print(f"\nĐã đăng ký task '{TASK_NAME}' chạy mỗi ngày lúc {RUN_TIME}.")
    print("Task chạy khi bạn ĐÃ đăng nhập Windows. Muốn chạy cả khi chưa đăng nhập:")
    print("  mở Task Scheduler (taskschd.msc) -> task này -> Properties ->")
    print("  'Run whether user is logged on or not' (cần nhập mật khẩu Windows).")


def uninstall():
    subprocess.run(["schtasks", "/Delete", "/TN", TASK_NAME, "/F"], check=False)
    print(f"Đã gỡ task '{TASK_NAME}' (nếu tồn tại).")


def status():
    subprocess.run(["schtasks", "/Query", "/TN", TASK_NAME, "/V", "/FO", "LIST"], check=False)


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else "run"
    if arg == "--install":
        install()
    elif arg == "--uninstall":
        uninstall()
    elif arg == "--status":
        status()
    else:
        run_pipeline()
