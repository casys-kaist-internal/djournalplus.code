import os
import re
import sys
import pandas as pd
from pathlib import Path

if "TAUFS_ENV_SOURCED" not in os.environ:
    print("Please source set_env.sh first. (TAUFS_ENV_SOURCED not set)")
    sys.exit(1)

# Set the result directory
RESULT_DIR = Path(os.getenv("TAUFS_BENCH_WS")+"/results/pgbench")
# Output CSV file name
OUTPUT_CSV = "pgbench_summary.csv"
DEVICE_NAME = str(Path(os.getenv("TAU_DEVICE_NAME")))    
# Prepare result containers
results = []

# Loop through pgbench result logs
for log_file in RESULT_DIR.glob("*_fpw_*.summary"):
    label = log_file.stem
    if label.endswith("iostat"):
        continue  # skip iostat logs

    iostat_file = RESULT_DIR / f"{label}_iostat.log"

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
                            total_write_mb += float(parts[idx]) / 1024  # convert KB to MB
                    except (ValueError, IndexError):
                        continue
                elif line.startswith("nvme0n1"):
                    parts = line.split()
                    try:
                        if "wMB/s" in iostat_header:
                            idx = iostat_header.index("wMB/s")
                            total_write_mb += float(parts[idx])
                        elif "wkB/s" in iostat_header:
                            idx = iostat_header.index("wkB/s")
                            total_write_mb += float(parts[idx]) / 1024  # convert KB to MB
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
            "tps": tps,
            "latency_ms": latency,
            "total_write_MB": total_write_mb
        })

# Convert to DataFrame
df = pd.DataFrame(results)

# Sort and save
if not df.empty:
    df.sort_values(by=["filesystem", "full_page_write", "scale", "clients"], inplace=True)
    df.to_csv(OUTPUT_CSV, index=False)
    print(f"Results saved to {OUTPUT_CSV}")
else:
    print("No valid result files found.")
