#!/usr/bin/env python3
import argparse
import os
import re
import csv

# Regex pattern for parsing filenames
FILENAME_PATTERN = re.compile(
    r"^(?P<database>postgres|mysql)_"                         # database
    r"(?P<workload>oltp_write_only)_"           # workload
    r"(?P<filesystem>ext4|xfs|zfs|ext4-dj)_"                              # filesystem
    r"fpw_(?P<fpw>on|off)_"                                   # full_page_write
    r"t(?P<table>\d+)_"                                       # table
    r"c(?P<clients>\d+)(?:_r1\.log|summary)$"                                # clients
)

def list_log_files(directory: str):
    """Return list of .log filenames inside the given directory, excluding iostat.log"""
    return [
        os.path.join(directory, entry)
        for entry in os.listdir(directory)
        if (entry.endswith(".log") or entry.endswith(".summary")) and "iostat" not in entry
    ]

def parse_log_filename(filename: str):
    """Parse benchmark log filename and return extracted fields"""
    base = os.path.basename(filename)
    match = FILENAME_PATTERN.match(base)
    if not match:
        raise ValueError(f"Invalid filename format: {base}")
    return {
        "database": match.group("database"),
        "workload": match.group("workload"),
        "filesystem": match.group("filesystem"),
        "full_page_write": match.group("fpw"),
        "table": int(match.group("table")),
        "clients": int(match.group("clients"))
    }

def parse_log_content(filepath: str):
    """Parse a log file and extract tps and latency metrics"""
    with open(filepath, "r") as f:
        content = f.read()

    tps_match = re.search(r"transactions:\s+\d+\s+\(([\d\.]+) per sec\.\)", content)
    if not tps_match:
        raise ValueError(f"TPS not found in {filepath}")
    tps = float(tps_match.group(1))

    min_match = re.search(r"min:\s+([\d\.]+)", content)
    avg_match = re.search(r"avg:\s+([\d\.]+)", content)
    max_match = re.search(r"max:\s+([\d\.]+)", content)
    p99_match = re.search(r"99th percentile:\s+([\d\.]+)", content)

    if not all([min_match, avg_match, max_match, p99_match]):
        raise ValueError(f"Latency values missing in {filepath}")

    return {
        "tps": tps,
        "latency_ms_min": float(min_match.group(1)),
        "latency_ms_avg": float(avg_match.group(1)),
        "latency_ms_max": float(max_match.group(1)),
        "latency_ms_p99": float(p99_match.group(1))
    }

def main():
    parser = argparse.ArgumentParser(description="Benchmark log parser")
    parser.add_argument("directories", nargs="+", help="One or more directories containing log files")
    parser.add_argument("output", help="Output CSV file path")
    args = parser.parse_args()

    all_files = []
    for d in args.directories:
        all_files.extend(list_log_files(d))

    results = []
    for filepath in all_files:
        try:
            meta = parse_log_filename(filepath)
            metrics = parse_log_content(filepath)
            row = {**meta, **metrics}
            results.append(row)
        except ValueError as e:
            print("Skipping:", e)

    # Sort results by (database, workload, filesystem, table, clients)
    results.sort(key=lambda r: (r["table"], r["workload"], r["database"], r["filesystem"], r["full_page_write"], r["clients"]))

    # CSV schema
    fieldnames = [
        "table",
        "workload",
        "database",
        "filesystem",
        "full_page_write",
        "clients",
        "tps",
        "latency_ms_min",
        "latency_ms_avg",
        "latency_ms_max",
        "latency_ms_p99"
    ]

    with open(args.output, "w", newline="") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)

if __name__ == "__main__":
    main()

