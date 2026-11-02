#!/usr/bin/env python3
"""EVAL_PLAN R2 table from run_recovery.sh result directories: per trial, the
load before the crash (TPS over its last 60 s), the redo the database had to
replay (WAL since the last checkpoint's redo position when the file system
went down), and the recovery: unmount, mount (the file system's journal
recovery), database start until it accepts connections, and their sum; from the
restart log, PG's WAL replay (range, elapsed) and end-of-recovery checkpoint,
or InnoDB's redo scan range and the time from "Starting crash recovery" to the
last applied batch. Seconds; GB = 10^9 bytes. Then the mean per configuration.

Usage: recovery_report.py <result dir>...
"""
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path

TPS = re.compile(r"^\[ (\d+)s \].* tps: ([\d.]+)")
PG_TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")
MY_TS = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z")


def lsn(s):
    hi, lo = s.split("/")
    return (int(hi, 16) << 32) | int(lo, 16)


def times(path):
    v = {}
    for line in path.read_text().splitlines():
        words = line.split()
        if words and words[0] in ("before_crash", "after_restart"):
            for kv in words[1:]:
                k, _, x = kv.partition("=")
                v["%s_%s" % (words[0], k)] = x
        else:
            for kv in words:
                k, _, x = kv.partition("=")
                v[k] = x
    return v


def tps_before(path):
    pts = [(int(m.group(1)), float(m.group(2)))
           for m in map(TPS.match, path.read_text(errors="replace").splitlines()) if m]
    if not pts:
        return None
    end = pts[-1][0]
    last = [t for s, t in pts if s > end - 60]
    return statistics.mean(last) if last else None


def last_section(path, marker):
    """the lines from the last one containing marker (run_recovery_vm.sh's guest logs
    were appended across trials before 2026-11-03)"""
    lines = path.read_text(errors="replace").splitlines()
    starts = [i for i, l in enumerate(lines) if marker in l]
    return lines[starts[-1]:] if starts else lines


def pg_restart(path):
    r = {}
    for line in last_section(path, "database system was interrupted"):
        m = PG_TS.match(line)
        ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() if m else None
        if "redo starts at" in line:
            r["redo_start"] = lsn(line.split("redo starts at ")[1].split()[0])
            r["t_redo_start"] = ts
        elif "redo done at" in line:
            r["redo_done"] = lsn(line.split("redo done at ")[1].split()[0])
            e = re.search(r"elapsed: ([\d.]+) s", line)
            if e:
                r["redo_elapsed"] = float(e.group(1))
        elif "checkpoint complete" in line and "redo_done" in r and "ckpt_total" not in r:
            t = re.search(r"total=([\d.]+) s", line)
            w = re.search(r"wrote (\d+) buffers", line)
            r["ckpt_total"] = float(t.group(1)) if t else None
            r["ckpt_buffers"] = int(w.group(1)) if w else None
        elif "ready to accept connections" in line:
            r["t_ready"] = ts
    if "redo_done" in r and "redo_start" in r:
        r["replayed_gb"] = (r["redo_done"] - r["redo_start"]) / 1e9
    return r


def my_restart(path):
    r = {}
    for line in last_section(path, "starting as process"):
        m = MY_TS.match(line)
        ts = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S.%f").timestamp() if m else None
        if ts is not None and "t_first" not in r:
            r["t_first"] = ts
        if "Starting crash recovery" in line:
            r["t_recovery"] = ts
        m = re.search(r"checkpoint_lsn = (\d+)", line)
        if m:
            r["checkpoint_lsn"] = int(m.group(1))
        m = re.search(r"scanned up to log sequence number (\d+)", line)
        if m:
            r["scanned_lsn"] = int(m.group(1))
        if "Apply batch completed" in line:
            r["t_applied"] = ts
        if "ready for connections" in line:
            r["t_ready"] = ts
    if "scanned_lsn" in r and "checkpoint_lsn" in r:
        r["replayed_gb"] = (r["scanned_lsn"] - r["checkpoint_lsn"]) / 1e9
    if r.get("t_recovery") and r.get("t_applied"):
        r["apply_s"] = r["t_applied"] - r["t_recovery"]
    return r


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def rows(d):
    out = []
    for t in sorted(Path(d).glob("*.times")):
        v = times(t)
        label = t.name[:-len(".times")]
        db = "postgres" if label.startswith("postgres") else "mysql"
        restart = Path(d) / (label + ".restart.log")
        rs = (pg_restart if db == "postgres" else my_restart)(restart) if restart.exists() else {}
        since = v.get("before_crash_wal_since_redo") or v.get("before_crash_redo_since_checkpoint")
        r = {"run": "%s/%s" % (Path(d).name, label), "config": "%s %s fpw/dwb %s" % (db, v.get("fs"), v.get("fpw")),
             "tps before": tps_before(Path(d) / (label + ".sysbench.log")),
             "redo at crash GB": num(since) / 1e9 if num(since) is not None else None,
             "replayed GB": rs.get("replayed_gb"),
             "umount": num(v.get("umount_s")), "mount": num(v.get("mount_s")),
             "db start": num(v.get("db_start_s"))}
        r["mount + start"] = (r["mount"] + r["db start"]) if r["mount"] is not None and r["db start"] is not None else None
        if db == "postgres":
            r["redo elapsed"] = rs.get("redo_elapsed")
            r["end ckpt"] = rs.get("ckpt_total")
        else:
            r["redo elapsed"] = rs.get("apply_s")
        out.append(r)
    return out


COLS = ["run", "tps before", "redo at crash GB", "replayed GB", "umount", "mount", "db start",
        "mount + start", "redo elapsed", "end ckpt"]


def cell(v):
    if isinstance(v, float):
        return "%.2f" % v if abs(v) < 100 else "%.0f" % v
    return "" if v is None else str(v)


def main():
    all_rows = [r for d in sys.argv[1:] for r in rows(d)]
    print("| " + " | ".join(COLS) + " |")
    print("|---|" + "---:|" * (len(COLS) - 1))
    for r in all_rows:
        print("| " + " | ".join(cell(r.get(c)) for c in COLS) + " |")
    print("\nMean per configuration:\n")
    print("| config | trials | " + " | ".join(COLS[1:]) + " |")
    print("|---|---:|" + "---:|" * (len(COLS) - 1))
    for cfg in sorted({r["config"] for r in all_rows}):
        rs = [r for r in all_rows if r["config"] == cfg]
        cells = []
        for c in COLS[1:]:
            xs = [r[c] for r in rs if isinstance(r.get(c), float)]
            cells.append(cell(statistics.mean(xs)) if xs else "")
        print("| %s | %d | %s |" % (cfg, len(rs), " | ".join(cells)))


if __name__ == "__main__":
    main()
