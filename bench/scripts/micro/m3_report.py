#!/usr/bin/env python3
"""EVAL_PLAN M3 tables from a run_fio.sh result directory run with M3_TRACE=1:
per configuration, operation and thread count (mean over the runs), where one
fsync's time goes (µs per sync, exclusive phases of vfs_fsync_range that add up
to the sync: a nested phase is taken out of the enclosing one): D =
file_write_and_wait_range (data writeback and its wait), JC =
jbd2_log_wait_commit (ext4), LF = xfs_log_force_seq (XFS), FL =
blkdev_issue_flush; on the tau kernel the tau commit's parts (m3_phases_tau.bt):
TW = waits before the commit (write mutex, this file's earlier commit), TI =
waiting for a background commit, CT = building the transaction, JIO = journal
block I/O waits, REC = the commit record's I/O wait, DUR = the host commit it
names; other = the rest; D_incl = D with what nests in it, TC_incl = the whole
tau commit, calls per sync of JC, FL and DUR, check = the phases' sum over the
sync time (%); and the device's jbd2 commits (per commit: request delay, locked,
flushing, logging in ms at HZ 1000; handles, blocks; syncs per commit). From
runs/<label>.m3 (m3_phases.bt) and .info.

Usage: m3_report.py <result dir>
"""
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

MAP = re.compile(r"^@(\w+?)(?:\[(\d+)\])?: (\d+)$")
PHASES = {"other": 0, "D": 1, "JC": 2, "LF": 3, "FL": 4,
          "TW": 5, "TI": 6, "CT": 7, "JIO": 8, "REC": 9, "DUR": 10}


def parse(m3):
    v = {}
    for line in m3.read_text(errors="replace").splitlines():
        m = MAP.match(line.strip())
        if m:
            v[m.group(1) + (m.group(2) or "")] = int(m.group(3))
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
        us = lambda k: v.get(k, 0) / n / 1000
        r = {"syncs": n, "fdatasync_pct": 100.0 * v.get("sync_ds", 0) / n, "sync": us("sync_ns")}
        for name, i in PHASES.items():
            r[name] = us("x%d" % i)
        r["D_incl"] = us("inc1")
        r["TC_incl"] = us("inc5")
        r["JC_calls"] = v.get("calls2", 0) / n
        r["FL_calls"] = v.get("calls4", 0) / n
        r["DUR_calls"] = v.get("calls10", 0) / n
        r["check"] = 100.0 * sum(v.get("x%d" % i, 0) for i in PHASES.values()) / v["sync_ns"]
        c = v.get("jc_n", 0)
        for k in ("request_delay", "locked", "flushing", "logging", "handles", "blocks"):
            r["jc_" + k] = v.get("jc_" + k, 0) / c if c else None
        r["commits"] = c
        r["syncs_per_commit"] = n / c if c else None
        rows[(inf.get("config"), inf.get("op"), int(inf.get("threads", 0)))].append(r)
    cols = ["syncs", "fdatasync_pct", "sync", "D", "JC", "LF", "FL", "TW", "TI", "CT", "JIO", "REC",
            "DUR", "other", "D_incl", "TC_incl", "JC_calls", "FL_calls", "DUR_calls", "check",
            "commits", "syncs_per_commit", "jc_request_delay", "jc_locked", "jc_flushing",
            "jc_logging", "jc_handles", "jc_blocks"]
    print("| config | op | T | runs | " + " | ".join(cols) + " |")
    print("|---|---|---:|---:|" + "---:|" * len(cols))
    for k in sorted(rows, key=lambda k: (k[0] or "", k[1] or "", k[2])):
        rs = rows[k]
        cells = []
        for c in cols:
            xs = [r[c] for r in rs if r[c] is not None]
            cells.append(("%.2f" if c.endswith("_calls") else "%.1f") % statistics.mean(xs) if xs else "")
        print("| %s | %s | %d | %d | %s |" % (k[0], k[1], k[2], len(rs), " | ".join(cells)))


if __name__ == "__main__":
    main()
