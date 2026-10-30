#!/usr/bin/env python3
"""EVAL_PLAN M3 tables from a run_fio.sh result directory run with M3_TRACE=1:
per configuration, operation and thread count (mean over the runs), where one
fsync's time goes (µs per sync, nested in vfs_fsync_range): D =
file_write_and_wait_range (data writeback and its wait), JC =
jbd2_log_wait_commit (ext4), LF = xfs_log_force_seq (XFS), FL =
blkdev_issue_flush, other = the rest; and the device's jbd2 commits (per
commit: request delay, locked, flushing, logging in ms at HZ 1000; handles,
blocks; syncs per commit). From runs/<label>.m3 (m3_phases.bt) and .info.

Usage: m3_report.py <result dir>
"""
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

SCALAR = re.compile(r"^@(\w+): (\d+)$")


def parse(m3):
    v = {}
    for line in m3.read_text(errors="replace").splitlines():
        m = SCALAR.match(line.strip())
        if m:
            v[m.group(1)] = int(m.group(2))
    return v


def info(path):
    d = {}
    for line in path.read_text().splitlines():
        if line.startswith("exp="):
            d.update(kv.split("=", 1) for kv in line.split())
    return d


def main():
    runs = Path(sys.argv[1]) / "runs"
    rows = defaultdict(list)
    for m3 in sorted(runs.glob("*.m3")):
        inf = info(m3.with_suffix(".info"))
        v = parse(m3)
        n = v.get("sync_n", 0)
        if not n:
            continue
        per = lambda k: v.get(k, 0) / n
        r = {"syncs": n, "fdatasync_pct": 100.0 * v.get("sync_ds", 0) / n, "sync": per("sync_us"),
             "D": per("D_us"), "JC": per("JC_us"), "LF": per("LF_us"), "FL": per("FL_us")}
        r["other"] = r["sync"] - r["D"] - r["JC"] - r["LF"] - r["FL"]
        c = v.get("jc_n", 0)
        for k in ("request_delay", "locked", "flushing", "logging", "handles", "blocks"):
            r["jc_" + k] = v.get("jc_" + k, 0) / c if c else None
        r["commits"] = c
        r["syncs_per_commit"] = n / c if c else None
        rows[(inf.get("config"), inf.get("op"), int(inf.get("threads", 0)))].append(r)
    cols = ["syncs", "fdatasync_pct", "sync", "D", "JC", "LF", "FL", "other", "commits",
            "syncs_per_commit", "jc_request_delay", "jc_locked", "jc_flushing", "jc_logging",
            "jc_handles", "jc_blocks"]
    print("| config | op | T | runs | " + " | ".join(cols) + " |")
    print("|---|---|---:|---:|" + "---:|" * len(cols))
    for k in sorted(rows, key=lambda k: (k[0] or "", k[1] or "", k[2])):
        rs = rows[k]
        cells = []
        for c in cols:
            xs = [r[c] for r in rs if r[c] is not None]
            cells.append("%.1f" % statistics.mean(xs) if xs else "")
        print("| %s | %s | %d | %d | %s |" % (k[0], k[1], k[2], len(rs), " | ".join(cells)))


if __name__ == "__main__":
    main()
