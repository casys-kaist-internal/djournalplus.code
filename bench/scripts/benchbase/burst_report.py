#!/usr/bin/env python3
"""EVAL_PLAN DB5 tables from run_burst.sh result directories: per run, the
throughput (BenchBase requests/s, 2-s windows) and the WAL directory's size on
disk (or the journal size from JOURNAL_SAMPLE_CMD) in each phase (before, during
and after the burst): mean and max, and the device write rate. Also writes
<label>.timeline.csv per run (seconds since the measurement start, throughput,
WAL GB, journal) for the figure.

Usage: burst_report.py <result dir>...
"""
import csv
import re
import statistics
import sys
from pathlib import Path


def phases(xml):
    """[(start s, end s, rate)] from the run's BenchBase configuration"""
    out, t = [], 0
    for m in re.finditer(r"<work>\s*<time>(\d+)</time>\s*<rate>(\w+)</rate>", xml.read_text()):
        out.append((t, t + int(m.group(1)), m.group(2)))
        t += int(m.group(1))
    return out


def start_epoch(run_dir):
    raw = next(run_dir.glob("*.raw.csv"), None)
    if raw is None:
        return None
    with open(raw) as f:
        next(f)
        return float(next(f).split(",")[2])


def throughput(run_dir):
    res = next((p for p in run_dir.glob("*.results.csv") if p.name.count(".") == 2), None)
    if res is None:
        return []
    with open(res) as f:
        r = csv.reader(f)
        next(r)
        return [(float(row[0]), float(row[1])) for row in r if row]


def samples(path, t0):
    out = []
    if not path.exists() or t0 is None:
        return out
    with open(path) as f:
        r = csv.DictReader(f)
        prev = None
        for row in r:
            try:
                t = float(row["epoch"]) - t0
                wal = float(row["wal_bytes"]) if row["wal_bytes"] else None
                sec = float(row["dev_sectors_written"]) if row["dev_sectors_written"] else None
            except (KeyError, ValueError):
                continue
            rate = None
            if prev and sec is not None and prev[2] is not None and t > prev[0]:
                rate = (sec - prev[2]) * 512 / (t - prev[0]) / 1e6
            out.append((t, wal, row.get("journal") or "", rate))
            prev = (t, wal, sec)
    return out


def mean(xs):
    xs = [x for x in xs if x is not None]
    return statistics.mean(xs) if xs else None


def main():
    rows = []
    for d in map(Path, sys.argv[1:]):
        for xml in sorted(d.glob("*_burst_*.xml")):
            if xml.stem.endswith("_warmup"):
                continue
            run_dir = d / xml.stem
            ph = phases(xml)
            t0 = start_epoch(run_dir)
            tp = throughput(run_dir)
            sm = samples(d / (xml.stem + ".samples.csv"), t0)
            with open(d / (xml.stem + ".timeline.csv"), "w") as f:
                w = csv.writer(f)
                w.writerow(["t_s", "throughput", "wal_gb", "journal", "dev_write_mb_s"])
                si = 0
                for t, x in tp:
                    while si + 1 < len(sm) and sm[si + 1][0] <= t:
                        si += 1
                    s = sm[si] if sm and sm[si][0] <= t + 2 else (None, None, "", None)
                    w.writerow([t, x, "%.3f" % (s[1] / 1e9) if s[1] is not None else "", s[2],
                                "%.1f" % s[3] if s[3] is not None else ""])
            for i, (a, b, rate) in enumerate(ph):
                name = ("before", "burst", "after")[i] if len(ph) == 3 else str(i)
                xs = [x for t, x in tp if a <= t < b]
                ws = [s[1] for s in sm if a <= s[0] < b and s[1] is not None]
                rows.append({"run": "%s/%s" % (d.name, xml.stem), "phase": "%s (%s)" % (name, rate),
                             "tps": mean(xs), "tps max": max(xs) if xs else None,
                             "wal GB": mean(ws) / 1e9 if ws else None,
                             "wal GB max": max(ws) / 1e9 if ws else None,
                             "dev MB/s": mean([s[3] for s in sm if a <= s[0] < b])})
    cols = ["run", "phase", "tps", "tps max", "wal GB", "wal GB max", "dev MB/s"]
    print("| " + " | ".join(cols) + " |")
    print("|---|---|" + "---:|" * (len(cols) - 2))
    for r in rows:
        print("| " + " | ".join(("%.1f" % r[c] if isinstance(r[c], float) else str(r[c] or ""))
                                for c in cols) + " |")


if __name__ == "__main__":
    main()
