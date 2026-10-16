#!/usr/bin/env python3
"""Summary of BenchBase TPC-C pilot directories (pilot_tpcc.sh), as markdown.

Per pilot: database size per warehouse and the load's time and client CPU;
per run (A_home, B_random): BenchBase's throughput, goodput and latency over
the measured window, its completed NewOrders as tpmC, the new orders the
database got over the whole run (districts' d_next_o_id) and the warehouses
they went to, the per-second throughput over the measured window, the JVM's
CPU (in cores) and the host's (mpstat).
Usage: pilot_report.py <pilot dir>...
"""
import glob
import json
import re
import statistics
import sys
from pathlib import Path


def kv(path):
    out = {}
    if Path(path).exists():
        for k, v in re.findall(r"(\w+)=([\d.]+)", Path(path).read_text()):
            out[k] = float(v)
    return out


def snap(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        f = line.split()
        if len(f) >= 3:
            out[(int(f[0]), int(f[1]))] = int(f[2])
    return out


def mpstat_busy(path):
    vals = []
    hdr = None
    for line in Path(path).read_text().splitlines():
        f = line.split()
        if "%idle" in f:
            hdr = f
        elif hdr and len(f) == len(hdr) and f[1] == "all":
            d = dict(zip(hdr[2:], map(float, f[2:])))
            vals.append(100 - d["%idle"] - d["%iowait"])
    return statistics.mean(vals) if vals else float("nan")


def io_counters(path):
    """FPW/DWB setting, device sectors written and the DB counters, end - begin."""
    if not Path(path).exists():
        return None, {}
    fpw, dev, db = None, {}, {}
    for line in Path(path).read_text().splitlines():
        f = line.split()
        if line.startswith("fpw="):
            fpw = line[4:].strip()
        elif len(f) > 11 and f[0] in ("begin", "end") and f[3].startswith("nvme"):
            dev.setdefault(f[3], {})[f[0]] = int(f[10])          # sectors written
        elif f and f[0] in ("begin", "end"):
            for k, v in re.findall(r"(\w+)=(\d+)", line):
                db.setdefault(k, {})[f[0]] = int(v)
    out = {k: v["end"] - v["begin"] for k, v in db.items() if "begin" in v and "end" in v}
    deltas = [v["end"] - v["begin"] for v in dev.values() if "begin" in v and "end" in v]
    if deltas:
        out["dev_bytes_written"] = max(deltas) * 512
    return fpw, out


def run_row(d, name):
    res = Path(d) / name
    summ = json.loads(Path(glob.glob(f"{res}/*.summary.json")[0]).read_text())
    hist = json.loads((Path(d) / f"{name}.histograms.json").read_text())
    xml = (Path(d) / f"{name}.xml").read_text()
    measured = int(re.search(r"<time>(\d+)</time>", xml).group(1))
    warmup = int(re.search(r"<warmup>(\d+)</warmup>", xml).group(1))
    terminals = int(re.search(r"<terminals>(\d+)</terminals>", xml).group(1))
    random_wh = re.search(r"<randomWarehouse>(\w+)</randomWarehouse>", xml).group(1)
    neworder = sum(v for k, v in hist["completed"]["HISTOGRAM"].items() if "NewOrder" in k)
    aborted = hist["aborted"]["NUM_SAMPLES"]
    b, a = snap(Path(d) / f"{name}.district_before"), snap(Path(d) / f"{name}.district_after")
    delta = {k: a[k] - b[k] for k in a}
    wh = {w for (w, _), v in delta.items() if v > 0}
    secs = [float(l.split(",")[1]) for l in open(glob.glob(f"{res}/*.results.csv")[0]).read().splitlines()[1:]]
    jvm = kv(Path(d) / f"{name}.jvm_time")
    lat = summ["Latency Distribution"]
    fpw, io = io_counters(Path(d) / f"{name}.io")
    orders = sum(delta.values()) or 1
    first = statistics.mean(secs[:60]) if len(secs) >= 60 else float("nan")
    last = statistics.mean(secs[-60:]) if len(secs) >= 60 else float("nan")
    row = {
        "run": name, "randomWarehouse": random_wh, "FPW/DWB": fpw or "off",
        "terminals": terminals,
        "warm-up + measured s": f"{warmup} + {measured}",
        "throughput (txn/s)": round(summ["Throughput (requests/second)"]),
        "goodput (txn/s)": round(summ["Goodput (requests/second)"]),
        "aborted (NewOrder 1%) /s": round(aborted / measured),
        "tpmC, BenchBase (completed NewOrder, measured)": round(neworder / measured * 60),
        "tpmC, database (new orders over the whole run)": round(sum(delta.values()) / (measured + warmup) * 60),
        "warehouses that got new orders": f"{len(wh)} of {len({w for w, _ in a})}",
        "latency avg / p95 / p99 (ms)": f"{lat['Average Latency (microseconds)'] / 1e3:.2f} / "
                                         f"{lat['95th Percentile Latency (microseconds)'] / 1e3:.2f} / "
                                         f"{lat['99th Percentile Latency (microseconds)'] / 1e3:.2f}",
        "throughput, first / last minute of the measured window": f"{first:.0f} / {last:.0f}",
        "throughput, per-second CoV": f"{statistics.pstdev(secs) / statistics.mean(secs) * 100:.1f}%",
        "BenchBase JVM CPU (cores)": f"{(jvm.get('user', 0) + jvm.get('sys', 0)) / jvm.get('elapsed', 1):.1f}",
        "host CPU busy (mpstat)": f"{mpstat_busy(Path(d) / f'{name}.mpstat'):.0f}%",
    }
    if "dev_bytes_written" in io:
        row["device writes per new order (KB)"] = f"{io['dev_bytes_written'] / orders / 1024:.1f}"
    if "wal_bytes" in io:
        row["WAL per new order (KB)"] = f"{io['wal_bytes'] / orders / 1024:.1f}"
        row["full-page images per new order"] = f"{io.get('wal_fpi', 0) / orders:.2f}"
    if "Innodb_os_log_written" in io:
        row["redo per new order (KB)"] = f"{io['Innodb_os_log_written'] / orders / 1024:.1f}"
        row["doublewrite pages per new order (batches only)"] = f"{io.get('Innodb_dblwr_pages_written', 0) / orders:.2f}"
        row["pages written per new order"] = f"{io.get('Innodb_pages_written', 0) / orders:.2f}"
    return row


def main():
    for d in sys.argv[1:]:
        db = "MySQL" if "mysql" in str(Path(d).resolve()) else "PostgreSQL"
        print(f"## {db}: `{Path(d).name}`\n")
        size = {}
        for f in sorted(Path(d).glob("size*")):
            for line in f.read_text().splitlines():
                k, v = line.split()
                size[k] = float(v)
        if "db_bytes" in size:
            wh = size["warehouses"]
            print(f"- {wh:.0f} warehouses: database {size['db_bytes'] / 1e9:.1f} GB "
                  f"({size['db_bytes'] / wh / 1e6:.0f} MB per warehouse; data directory "
                  f"{size['datadir_bytes'] / 1e9:.1f} GB with the WAL/redo); about "
                  f"{128e9 / (size['db_bytes'] / wh):.0f} warehouses for 128 GB")
        for f in sorted(Path(d).glob("load*.jvm_time")):
            load = kv(f)
            print(f"- {f.name[:-9]}: {load.get('elapsed', 0) / 60:.1f} min, BenchBase "
                  f"{(load.get('user', 0) + load.get('sys', 0)) / max(load.get('elapsed', 1), 1):.1f} cores")
        print()
        names = [Path(x).parent.name for x in sorted(glob.glob(f"{d}/*/*.summary.json"),
                                                     key=lambda x: Path(x).stat().st_mtime)]
        rows = [run_row(d, n) for n in names
                if not n.startswith("load") and not n.endswith("_warmup")]
        if not rows:
            continue
        if len(rows) > 4:   # a terminal sweep: one line per run first
            print("| run | FPW/DWB | terminals | txn/s | tpmC (BenchBase / database) | latency avg / p95 / p99 (ms) "
                  "| device KB per new order | BenchBase cores | host busy |")
            print("|---" * 9 + "|")
            for r in rows:
                print(f"| {r['run']} | {r['FPW/DWB']} | {r['terminals']} | {r['throughput (txn/s)']} "
                      f"| {r['tpmC, BenchBase (completed NewOrder, measured)']} / "
                      f"{r['tpmC, database (new orders over the whole run)']} "
                      f"| {r['latency avg / p95 / p99 (ms)']} | {r.get('device writes per new order (KB)', '')} "
                      f"| {r['BenchBase JVM CPU (cores)']} | {r['host CPU busy (mpstat)']} |")
            print()
        keys = []
        for r in rows:
            keys += [k for k in r if k not in keys]
        print("| | " + " | ".join(r["run"] for r in rows) + " |")
        print("|---" * (len(rows) + 1) + "|")
        for k in keys[1:]:
            print(f"| {k} | " + " | ".join(str(r.get(k, "")) for r in rows) + " |")
        print()


if __name__ == "__main__":
    main()
