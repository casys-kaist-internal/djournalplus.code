import re
from pathlib import Path
import csv
import os

def parse_iostat_log(log_path: Path, device: str = "nvme1n1") -> float:
    total_wmb = 0.0
    current_columns = []

    with log_path.open() as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        # 헤더라인 찾기
        if line.startswith("Device") and "wMB/s" in line:
            current_columns = line.split()
            try:
                wmb_index = current_columns.index("wMB/s")
            except ValueError:
                wmb_index = None
            i += 1
            continue

        # 데이터 라인 처리
        if device in line:
            tokens = line.split()
            if len(tokens) > wmb_index and wmb_index is not None:
                try:
                    total_wmb += float(tokens[wmb_index])
                except ValueError:
                    pass
        i += 1

    return round(total_wmb, 2)

def parse_tpcc_log(log_path: Path):
    tpm = None
    nopm = None
    with log_path.open() as f:
        for line in f:
            if "TEST RESULT" in line and "PostgreSQL TPM" in line:
                match = re.search(r'(\d+)\s+NOPM.*?(\d+)\s+PostgreSQL TPM', line)
                if match:
                    nopm = int(match.group(1))
                    tpm = int(match.group(2))
                    break
    return tpm, nopm

def collect_benchmark_summary(results_root: Path, device: str = "nvme1n1", output_csv: Path = None):
    rows = []
    for bench_dir in sorted(results_root.glob("tpcc_*")):
        config = bench_dir.name
        for run_log in bench_dir.glob("hmdb_run_vu*.log"):
            vu_match = re.search(r'vu(\d+)', run_log.name)
            if not vu_match:
                continue
            vu = int(vu_match.group(1))
            tpm, nopm = parse_tpcc_log(run_log)
            iostat_log = bench_dir / f"run_vu{vu}_iostat.log"
            total_wmb = parse_iostat_log(iostat_log, device) if iostat_log.exists() else None

            rows.append({
                "config": config,
                "vu": vu,
                "tpm": tpm,
                "nopm": nopm,
                "total_write_MB": total_wmb
            })

    rows.sort(key=lambda r: (r["config"], r["vu"]))

    if output_csv:
        with output_csv.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["config", "vu", "tpm", "nopm", "total_write_MB"])
            writer.writeheader()
            writer.writerows(rows)

    return rows

# ==== 실행 ====
# 환경변수에서 경로 얻기
results_dir = Path(os.environ["TAUFS_BENCH_WS"]) / "results"
summary_csv_path = results_dir / "tpcc_iostat_summary.csv"
DEVICE_NAME = str(Path(os.getenv("TAU_DEVICE_NAME")))  

# 결과 파싱 및 저장
summary = collect_benchmark_summary(results_dir, DEVICE_NAME, output_csv=summary_csv_path)
print(f"✅ Summary saved to {summary_csv_path}")
