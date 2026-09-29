#!/usr/bin/env python3
"""Summarize a run_main.sh result directory.

Writes one CSV row per measurement (<label>.log + <label>.io) and prints, per
DB/workload/FS/threads, the App (fpw/dblwr on) vs Raw (off) throughput and the
device write volume per transaction.

Usage: parse_main.py <result_dir> [out.csv]   (default: <result_dir>/summary.csv)
"""
import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

LABEL = re.compile(
    r"^(?P<db>postgres|mysql)_(?P<workload>oltp_\w+?)_(?P<fs>[a-z0-9.-]+)"
    r"_fpw_(?P<fpw>on|off)_t(?P<tables>\d+)_c(?P<threads>\d+)_r(?P<run>\d+)\.log$")
SECTOR = 512
MB = 1 << 20


def parse_log(path):
    text = path.read_text(errors="replace")
    trx = re.search(r"transactions:\s+(\d+)\s+\(([\d.]+) per sec", text)
    if not trx:
        return None
    avg = re.search(r"^\s+avg:\s+([\d.]+)", text, re.M)
    p99 = re.search(r"99th percentile:\s+([\d.]+)", text)
    return {"transactions": int(trx.group(1)), "tps": float(trx.group(2)),
            "avg_ms": float(avg.group(1)) if avg else None,
            "p99_ms": float(p99.group(1)) if p99 else None}


def parse_io(path):
    """Deltas (end - begin) of the device counters and of the DB counters."""
    dev = {"begin": defaultdict(dict), "end": defaultdict(dict)}
    kv = {"begin": {}, "end": {}}
    for line in path.read_text().splitlines():
        tok = line.split()
        if len(tok) < 2 or tok[0] not in dev:
            continue
        if "=" in tok[1]:
            kv[tok[0]].update(t.split("=", 1) for t in tok[1:] if "=" in t)
        elif len(tok) >= 12:   # tag major minor name + /proc/diskstats fields
            dev[tok[0]][tok[3]] = [int(x) for x in tok[4:]]
    # I/O of a multipath NVMe namespace is accounted on its path nodes (nvmeXcYnZ)
    names = [n for n in dev["end"] if n in dev["begin"]]
    paths = [n for n in names if re.match(r"nvme\d+c\d+n\d+$", n)] or names
    delta = {}
    for field, idx in (("rd_sectors", 2), ("wr_sectors", 6), ("flushes", 14)):
        vals = [dev["end"][n][idx] - dev["begin"][n][idx]
                for n in paths if len(dev["end"][n]) > idx]
        delta[field] = sum(vals) if vals else None
    for key in kv["end"].keys() & kv["begin"].keys():
        delta[key] = int(kv["end"][key]) - int(kv["begin"][key])
    return delta


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    rdir = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else rdir / "summary.csv"

    rows = []
    for log in sorted(rdir.glob("*.log")):
        m = LABEL.match(log.name)
        if not m:
            continue
        res = parse_log(log)
        if res is None:
            print(f"skip (no result): {log.name}", file=sys.stderr)
            continue
        row = {**m.groupdict(), **res}
        io = log.with_suffix(".io")
        d = parse_io(io) if io.exists() else {}
        if d.get("wr_sectors") is not None:
            row["dev_write_mb"] = round(d["wr_sectors"] * SECTOR / MB, 1)
            row["dev_read_mb"] = round(d["rd_sectors"] * SECTOR / MB, 1)
            row["dev_write_kb_per_trx"] = round(
                d["wr_sectors"] * SECTOR / 1024 / max(res["transactions"], 1), 2)
            row["dev_flushes"] = d["flushes"]
        if "cpu_idle" in d:        # all CPUs, USER_HZ ticks
            tot = sum(d[k] for k in ("cpu_user", "cpu_nice", "cpu_system", "cpu_idle",
                                     "cpu_iowait", "cpu_irq", "cpu_softirq"))
            if tot:
                row["cpu_util_pct"] = round(100 * (tot - d["cpu_idle"] - d["cpu_iowait"]) / tot, 1)
                row["cpu_iowait_pct"] = round(100 * d["cpu_iowait"] / tot, 1)
        if "pswpout" in d:         # pages of 4 KiB
            row["swap_in_mb"] = round(d["pswpin"] * 4 / 1024, 1)
            row["swap_out_mb"] = round(d["pswpout"] * 4 / 1024, 1)
        if "wal_bytes" in d:       # PostgreSQL
            row["wal_mb"] = round(d["wal_bytes"] / MB, 1)
            row["wal_fpi"] = d["wal_fpi"]
        if "Innodb_os_log_written" in d:   # MySQL (16 KiB pages)
            row["redo_mb"] = round(d["Innodb_os_log_written"] / MB, 1)
            row["dblwr_mb"] = round(d["Innodb_dblwr_pages_written"] * 16 / 1024, 1)
        if "ps_innodb_log_file_misc" in d:   # MySQL performance_schema, ps -> ms
            row["binlog_syncs"] = d.get("ps_binlog_misc")
            row["binlog_sync_ms"] = round(d.get("ps_binlog_misc_ps", 0) / 1e9, 1)
            row["redo_syncs"] = d["ps_innodb_log_file_misc"]
            row["redo_sync_ms"] = round(d["ps_innodb_log_file_misc_ps"] / 1e9, 1)
            row["dblwr_io_ms"] = round(d.get("ps_innodb_dblwr_file_wait_ps", 0) / 1e9, 1)
        rows.append(row)

    if not rows:
        sys.exit(f"no measurements found in {rdir}")
    fields = ["db", "workload", "fs", "fpw", "tables", "threads", "run", "transactions",
              "tps", "avg_ms", "p99_ms", "dev_write_mb", "dev_read_mb",
              "dev_write_kb_per_trx", "dev_flushes", "cpu_util_pct", "cpu_iowait_pct", "swap_in_mb", "swap_out_mb", "wal_mb", "wal_fpi", "redo_mb", "dblwr_mb",
              "binlog_syncs", "binlog_sync_ms", "redo_syncs", "redo_sync_ms", "dblwr_io_ms"]
    rows.sort(key=lambda r: (r["db"], r["workload"], r["fs"], r["fpw"],
                             int(r["threads"]), int(r["run"])))
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {len(rows)} rows to {out}\n")

    # App (on) vs Raw (off): mean over repeated runs
    agg = defaultdict(lambda: defaultdict(list))
    for r in rows:
        key = (r["db"], r["workload"], r["fs"], int(r["threads"]))
        agg[key][r["fpw"]].append(r)
    print(f"{'db':8} {'workload':22} {'fs':10} {'thr':>4} {'App tps':>10} {'Raw tps':>10}"
          f" {'Raw/App':>8} {'App KB/trx':>11} {'Raw KB/trx':>11}")
    for key in sorted(agg):
        on, off = agg[key].get("on", []), agg[key].get("off", [])

        def mean(rs, k):
            vals = [r[k] for r in rs if r.get(k) is not None]
            return statistics.mean(vals) if vals else None

        def fmt(v, spec):
            return format(v, spec) if v is not None else "-"

        t_on, t_off = mean(on, "tps"), mean(off, "tps")
        ratio = t_off / t_on if t_on and t_off else None
        print(f"{key[0]:8} {key[1]:22} {key[2]:10} {key[3]:>4} {fmt(t_on, '10.1f')}"
              f" {fmt(t_off, '10.1f')} {fmt(ratio, '8.2f')}"
              f" {fmt(mean(on, 'dev_write_kb_per_trx'), '11.2f')}"
              f" {fmt(mean(off, 'dev_write_kb_per_trx'), '11.2f')}")


if __name__ == "__main__":
    main()
