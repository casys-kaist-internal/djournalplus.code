#!/usr/bin/env python3
"""EVAL_PLAN DB2 tables from profiling runs with PROFILE=files (run_main.sh,
run_tpcc.sh): per measurement (<label>.bpftrace from file_writes.bt and
<label>.inodes, the files of the mount at the end),
  (a) the data files: how many the database has, how many were written, and
      how few take 50 / 90 / 99% of the data-file write bytes (and 90% of the
      write calls); the largest file's share; log and doublewrite bytes;
  (b) sync latency per file type (log, data, dwb): syncs, files synced, the
      fdatasync share, mean and percentiles (µs; from the 2-µs histogram below
      2 ms, the 200-µs one above).
File types as file_writes.bt: log = PG WAL segment or MySQL #ib_redo*, dwb =
*.dblwr, data = PG relation file (name starts with 1-9) or *.ibd, other.

Usage: file_report.py <result dir>...
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

TYPES = {0: "log", 1: "dwb", 2: "data", 3: "other"}
KEY2 = re.compile(r"^@(\w+)\[(\d+), (\d+)\]: (\d+)$")
HIST_HEAD = re.compile(r"^@(sync_fine|sync_coarse|sync_log2)\[(\d+)\]:\s*$")
BUCKET = re.compile(r"^\[([\d.]+[KMG]?), ([\d.]+[KMG]?|\.\.\.)\)\s+(\d+)\s*\|")
UNIT = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30}


def value(tok, log2):
    if tok == "...":
        return None
    if tok[-1] in UNIT:   # bpftrace's power-of-two suffixes (log2 histograms)
        return float(tok[:-1]) * UNIT[tok[-1]]
    return float(tok)


def parse(path):
    keyed = defaultdict(dict)   # name -> {(a, b): n}
    hists = defaultdict(list)   # (name, type) -> [(lo, hi, n)]
    cur = None
    for line in path.read_text(errors="replace").splitlines():
        line = line.rstrip()
        m = KEY2.match(line)
        if m:
            keyed[m.group(1)][(int(m.group(2)), int(m.group(3)))] = int(m.group(4))
            cur = None
            continue
        m = HIST_HEAD.match(line)
        if m:
            cur = (m.group(1), int(m.group(2)))
            continue
        m = BUCKET.match(line.strip())
        if m and cur:
            log2 = cur[0] == "sync_log2"
            lo, hi = value(m.group(1), log2), value(m.group(2), log2)
            hists[cur].append((lo, hi, int(m.group(3))))
            continue
        if not line.strip():
            cur = None
    return keyed, hists


def ftype(name):
    if name.startswith("#ib_redo") or (len(name) == 24 and name.startswith("00000001")):
        return 0
    if name.endswith(".dblwr"):
        return 1
    if name.endswith(".ibd") or name[:1] in "123456789":
        return 2
    return 3


def inode_list(path):
    """ino -> (size, path)"""
    files = {}
    if path.exists():
        for line in path.read_text(errors="replace").splitlines():
            parts = line.split(" ", 2)
            if len(parts) == 3:
                files[int(parts[0])] = (int(parts[1]), parts[2])
    return files


def cover(values, frac):
    """the fewest items whose values sum to frac of the total"""
    tot = sum(values)
    if not tot:
        return 0
    acc = 0
    for i, v in enumerate(sorted(values, reverse=True), 1):
        acc += v
        if acc >= frac * tot:
            return i
    return len(values)


def buckets(hists, t):
    """(lo, hi, n) of one file type's syncs: the 2-µs buckets below 2 ms, the
    200-µs buckets above (overflow of both: an open bucket from 200 ms)"""
    fine = [b for b in hists.get(("sync_fine", t), []) if b[1] is not None]
    coarse = [b for b in hists.get(("sync_coarse", t), [])]
    out = [b for b in fine if b[1] <= 2000]
    for lo, hi, n in coarse:
        if lo >= 2000:
            out.append((lo, hi if hi is not None else lo * 2, n))
    return out


def pct(bs, p):
    tot = sum(n for _, _, n in bs)
    if not tot:
        return None
    goal = p * tot
    acc = 0
    for lo, hi, n in bs:
        if n and acc + n >= goal:
            return lo + (hi - lo) * (goal - acc) / n
        acc += n
    return bs[-1][1]


def run_rows(label, bt, inodes):
    keyed, hists = parse(bt)
    files = inode_list(inodes)
    w_n, w_b = keyed.get("w_n", {}), keyed.get("w_bytes", {})
    s_n, s_us = keyed.get("s_n", {}), keyed.get("s_us", {})
    data_files = [ino for ino, (_, p) in files.items() if ftype(Path(p).name) == 2]
    data_bytes = [v for (ino, t), v in w_b.items() if t == 2]
    data_calls = [v for (ino, t), v in w_n.items() if t == 2]
    tot = sum(data_bytes)
    by_type = defaultdict(int)
    for (ino, t), v in w_b.items():
        by_type[t] += v
    a = {
        "run": label,
        "data files": len(data_files),
        "data GiB": sum(files[i][0] for i in data_files) / 2**30,
        "written": len(data_bytes),
        "50% B": cover(data_bytes, 0.5),
        "90% B": cover(data_bytes, 0.9),
        "99% B": cover(data_bytes, 0.99),
        "90% calls": cover(data_calls, 0.9),
        "top file %": 100.0 * max(data_bytes) / tot if tot else 0,
        "data GB": tot / 1e9,
        "log GB": by_type[0] / 1e9,
        "dwb GB": by_type[1] / 1e9,
        "data KiB/write": tot / sum(data_calls) / 1024 if data_calls else 0,
    }
    b = []
    for t in (0, 2, 1):
        n = sum(v for (ino, tt), v in s_n.items() if tt == t)
        if not n:
            continue
        us = sum(v for (ino, tt), v in s_us.items() if tt == t)
        ds = keyed.get("sync_ds", {})
        bs = buckets(hists, t)
        b.append({
            "run": label, "type": TYPES[t], "syncs": n,
            "files": sum(1 for (ino, tt) in s_n if tt == t),
            "fdatasync %": 100.0 * ds.get((t, 1), 0) / n,
            "mean": us / n,
            "p50": pct(bs, 0.5), "p90": pct(bs, 0.9), "p99": pct(bs, 0.99), "p99.9": pct(bs, 0.999),
        })
    return a, b


def table(rows, cols):
    def cell(v):
        if isinstance(v, float):
            return "%.2f" % v if abs(v) < 10 else "%.1f" % v if abs(v) < 1000 else "%.0f" % v
        return "" if v is None else str(v)
    out = ["| " + " | ".join(cols) + " |", "|---|" + "---:|" * (len(cols) - 1)]
    for r in rows:
        out.append("| " + " | ".join(cell(r.get(c)) for c in cols) + " |")
    return out


def main():
    A, B = [], []
    for d in sys.argv[1:]:
        for bt in sorted(Path(d).glob("*.bpftrace")):
            inodes = bt.with_suffix(".inodes")
            if not inodes.exists():
                continue
            a, b = run_rows("%s/%s" % (Path(d).name, bt.stem), bt, inodes)
            A.append(a)
            B.extend(b)
    print("## (a) Data files written\n")
    print("\n".join(table(A, ["run", "data files", "data GiB", "written", "50% B", "90% B", "99% B",
                              "90% calls", "top file %", "data GB", "log GB", "dwb GB",
                              "data KiB/write"])))
    print("\n## (b) Sync latency per file type (µs)\n")
    print("\n".join(table(B, ["run", "type", "syncs", "files", "fdatasync %", "mean", "p50", "p90",
                              "p99", "p99.9"])))


if __name__ == "__main__":
    main()
