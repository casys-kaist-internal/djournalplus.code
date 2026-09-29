import os
import re
import pandas as pd
from pathlib import Path

# Set the result and output directory
RESULT_DIR = Path(os.getenv("TAUFS_BENCH_WS") + "/results/pgbench")
OUTPUT_DIR = Path(os.getenv("TAUFS_BENCH_WS") + "/DATA")
OUTPUT_CSV = OUTPUT_DIR / "pgbench_data.csv"
DEVICE_NAME = os.getenv("TAU_DEVICE_NAME")

# Prepare result containers
results = []

# 하위 디렉토리까지 모두 순회
for log_file in RESULT_DIR.rglob("*_fpw_*.summary"):
    label = log_file.stem
    if label.endswith("iostat"):
        continue  # skip iostat logs

    iostat_file = log_file.parent / f"{label}_iostat.log"

    # Parse pgbench log
    tps = None
    latency = None
    with open(log_file) as f:
        for line in f:
            if line.startswith("tps ="):
                tps_match = re.search(r"tps = ([\d\.]+)", line)
                if tps_match:
                    tps = float(tps_match.group(1))
            elif line.startswith("latency average"):
                latency_match = re.search(r"latency average = ([\d\.]+) ms", line)
                if latency_match:
                    latency = float(latency_match.group(1))

    # Parse iostat log
    total_write_mb = 0.0
    iostat_header = []
    if iostat_file.exists():
        with open(iostat_file) as f:
            for line in f:
                if line.startswith("Device"):
                    iostat_header = line.split()
                elif line.startswith(DEVICE_NAME):
                    parts = line.split()
                    try:
                        if "wMB/s" in iostat_header:
                            idx = iostat_header.index("wMB/s")
                            total_write_mb += float(parts[idx])
                        elif "wkB/s" in iostat_header:
                            idx = iostat_header.index("wkB/s")
                            total_write_mb += float(parts[idx]) / 1024
                    except (ValueError, IndexError):
                        continue

    # Parse metadata from filename
    match = re.match(r"(\w+)_fpw_(on|off)_s(\d+)_c(\d+)", label)
    if match:
        fs, fpw, scale, clients = match.groups()
        results.append({
            "filesystem": fs,
            "full_page_write": fpw,
            "scale": int(scale),
            "clients": int(clients),
            "tps": int(tps) if tps is not None else None,  # 정수로 변환
            "latency_ms": latency,  # latency는 소수점 유지
            "total_write_MB": int(total_write_mb)  # 정수로 변환
        })

# Convert to DataFrame
df = pd.DataFrame(results)

# Sort and save
if not df.empty:
    df.sort_values(by=["filesystem", "full_page_write", "scale", "clients"], inplace=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    df.to_csv(OUTPUT_CSV, index=False)
    print(f"Results saved to {OUTPUT_CSV}")
else:
    print("No valid result files found.")
