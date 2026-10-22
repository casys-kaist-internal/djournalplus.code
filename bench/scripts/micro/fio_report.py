#!/usr/bin/env python3
"""Results of run_fio.sh.

  fio_report.py header                     the CSV header of results.csv
  fio_report.py row <run prefix>           one CSV line from <prefix>.json/.info/.err/.tau
  fio_report.py brief <run prefix>         one line for the run log
  fio_report.py tables <result dir> [...] [-o tables.md]
        per experiment, operation and file count: per configuration and thread
        count the mean over runs of IOPS (± relative s.d.), fdatasync mean and
        p99; the bytes runs; the per-second bandwidth of runs with bw logs
        (BW_LOG=1); and the numbers the paper draft asks for

A run prefix is <result dir>/runs/<label>. results.csv columns: the spec's
(exp ... notes), then dev_write_bytes, app_write_bytes, bytes_per_16k (bytes
runs: device bytes from the remount to after syncfs + umount, KiB per 16 KiB
written), then sync_n (fdatasyncs counted by fio), elapsed_s (wall time of the
fio process), dev_write_bytes_run (device bytes over the fio process),
tau_fds (fio's open files under the mount with O_TAU_UNTORN, mid-run),
tau_used_max_mb and tau_running_max (the kernel's Tau_Daemon lines, every 15 s).
"""
import csv
import glob
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

COLS = ["exp", "config", "op", "threads", "files", "fdatasync_n", "rep", "mode", "runtime_s",
        "write_iops", "write_bw_mib_s", "sync_mean_us", "sync_p99_us", "io_bytes", "notes",
        "dev_write_bytes", "app_write_bytes", "bytes_per_16k", "sync_n", "elapsed_s",
        "dev_write_bytes_run", "tau_fds", "tau_used_max_mb", "tau_running_max"]
ORDER = ["EXT4_Raw", "EXT4_Data", "ZFS", "tau-EXT4", "XFS_Raw", "tau-XFS"]
OPS = ["overwrite", "prealloc", "hole", "append"]
TAU_LINE = re.compile(r"Tau_Daemon: Used journal (\d+)MB / \(Total\) (\d+)MB, running tau: (\d+)")


def info(prefix):
    d = {}
    for line in Path(prefix + ".info").read_text().split("\n"):
        for kv in line.split() if line.startswith(("exp=",)) else [line]:
            if "=" in kv:
                k, v = kv.split("=", 1)
                d[k] = v
    return d


def row(prefix):
    inf = info(prefix)
    j = json.load(open(prefix + ".json"))["jobs"][0]
    w, s = j["write"], j.get("sync", {}).get("lat_ns", {})
    r = {k: inf.get(k, "") for k in COLS[:8]}
    r["runtime_s"] = "%.1f" % (w["runtime"] / 1000)
    r["write_iops"] = "%.0f" % w["iops"]
    r["write_bw_mib_s"] = "%.1f" % (w["bw_bytes"] / 2**20)
    r["sync_mean_us"] = "%.1f" % (s.get("mean", 0) / 1000) if s.get("N") else ""
    p99 = s.get("percentile", {}).get("99.000000")
    r["sync_p99_us"] = "%.0f" % (p99 / 1000) if p99 and s.get("N") else ""
    r["io_bytes"] = str(w["io_bytes"])
    r["sync_n"] = str(s.get("N", 0))
    r["elapsed_s"] = inf.get("elapsed_s", "")
    sec = lambda key: int(inf[key].split()[1]) if inf.get(key) else None
    if sec("dev_before") is not None and sec("dev_after") is not None:
        r["dev_write_bytes_run"] = str((sec("dev_after") - sec("dev_before")) * 512)
    if sec("dev_after_umount") is not None:
        dev = (sec("dev_after_umount") - sec("dev_before")) * 512
        r["dev_write_bytes"] = str(dev)
        r["app_write_bytes"] = str(w["io_bytes"])
        r["bytes_per_16k"] = "%.1f" % (dev / w["io_bytes"] * 16) if w["io_bytes"] else ""
    r["tau_fds"] = inf.get("tau_fds", "")
    used = [TAU_LINE.search(l) for l in open(prefix + ".tau")] if Path(prefix + ".tau").exists() else []
    used = [m for m in used if m]
    if used:
        r["tau_used_max_mb"] = str(max(int(m.group(1)) for m in used))
        r["tau_running_max"] = str(max(int(m.group(3)) for m in used))
    notes = []
    err = Path(prefix + ".err").read_text(errors="replace") if Path(prefix + ".err").exists() else ""
    m = re.search(r"tau_preload: (\d+) of (\d+) write opens", err)
    if m:
        notes.append("tau %s/%s opens" % (m.group(1), m.group(2)))
    other = [l for l in err.splitlines() if l.strip() and not l.startswith("tau_preload:")]
    if other:
        notes.append("stderr: " + other[0][:80].replace(",", ";"))
    if j.get("error"):
        notes.append("fio error %s" % j["error"])
    if r["mode"] == "size":
        want = None
        fio_job = Path(prefix + ".fio").read_text()
        m2 = re.search(r"^size=(\d+)g", fio_job, re.M)
        nj = re.search(r"^numjobs=(\d+)", fio_job, re.M)
        if m2 and nj:
            want = int(m2.group(1)) * 2**30 * int(nj.group(1))
        if want and w["io_bytes"] != want:
            notes.append("io_bytes %d of %d" % (w["io_bytes"], want))
    r["notes"] = "; ".join(notes)
    return r


def header():
    print(",".join(COLS))


def print_row(prefix):
    r = row(prefix)
    print(",".join(str(r.get(c, "")) for c in COLS))


def brief(prefix):
    r = row(prefix)
    s = "%s IOPS, %s MiB/s, fdatasync %s us (p99 %s), %s syncs" % (
        r["write_iops"], r["write_bw_mib_s"], r["sync_mean_us"] or "-", r["sync_p99_us"] or "-", r["sync_n"])
    if r["mode"] == "size":
        s += ", %s s" % r["runtime_s"]
    if r.get("bytes_per_16k"):
        s += ", %s KiB on the device per 16 KiB" % r["bytes_per_16k"]
    if r["config"].startswith("tau-"):
        s += ", fds %s, journal max %s MB" % (r["tau_fds"] or "?", r.get("tau_used_max_mb") or "-")
    if r["notes"]:
        s += " [%s]" % r["notes"]
    print(s)


def bw_series(prefix):
    """aggregate KiB/s per second over the job logs of a run (BW_LOG=1)"""
    per = defaultdict(float)
    for f in glob.glob(prefix + "_bw.*.log"):
        for line in open(f):
            p = line.split(",")
            if len(p) >= 2:
                per[int(p[0]) // 1000] += float(p[1])
    return [per[k] for k in sorted(per)]


def mean_sd(v):
    m = statistics.mean(v)
    return m, (statistics.stdev(v) / m * 100 if len(v) > 1 and m else 0)


def tables(dirs, out):
    rows = []
    for d in dirs:
        with open(Path(d) / "results.csv") as f:
            for r in csv.DictReader(f):
                r["_dir"] = d
                rows.append(r)
    lines = ["# fio results", "", "Mean over runs; IOPS ± relative s.d.", ""]
    groups = defaultdict(list)
    for r in rows:
        if r["exp"] in ("e1", "e2", "sync1"):
            groups[(r["exp"], r["op"], r["fdatasync_n"], r["exp"] == "e2" and "files" or "threads")].append(r)
    cfgs = [c for c in ORDER if any(r["config"] == c for r in rows)]
    for key in sorted(groups, key=lambda k: (["e1", "e2", "sync1"].index(k[0]),
                                            OPS.index(k[1]) if k[1] in OPS else 9)):
        exp, op, n, axis = key
        rs = groups[key]
        xs = sorted({int(r[axis]) for r in rs})
        title = "%s %s, fdatasync every %s write%s" % (exp, op, n, "" if n == "1" else "s")
        for metric, fmt in (("write_iops", "IOPS"), ("sync_mean_us", "fdatasync mean (µs)"),
                            ("sync_p99_us", "fdatasync p99 (µs)")):
            lines += ["## %s: %s" % (title, fmt), "",
                      "| %s | %s |" % (axis, " | ".join(cfgs)), "|---|" + "---|" * len(cfgs)]
            for x in xs:
                cells = []
                for c in cfgs:
                    v = [float(r[metric]) for r in rs if r["config"] == c and int(r[axis]) == x and r[metric]]
                    if not v:
                        cells.append("")
                        continue
                    m, sd = mean_sd(v)
                    cells.append("{:,.0f} ±{:.0f}%".format(m, sd) if metric == "write_iops" else "{:,.0f}".format(m))
                lines.append("| %d | %s |" % (x, " | ".join(cells)))
            lines.append("")
        if any(r["mode"] == "size" for r in rs):
            lines += ["## %s: run time (s) for %s" % (title, "the whole files"), "",
                      "| %s | %s |" % (axis, " | ".join(cfgs)), "|---|" + "---|" * len(cfgs)]
            for x in xs:
                cells = []
                for c in cfgs:
                    v = [float(r["runtime_s"]) for r in rs if r["config"] == c and int(r[axis]) == x]
                    cells.append("{:,.0f}".format(statistics.mean(v)) if v else "")
                lines.append("| %d | %s |" % (x, " | ".join(cells)))
            lines.append("")
    by = [r for r in rows if r["exp"] == "bytes"]
    if by:
        lines += ["## bytes: device KiB per 16 KiB written (overwrite, 64 jobs, to after syncfs + umount)", "",
                  "| config | KiB per 16 KiB | device GiB | written GiB |", "|---|---|---|---|"]
        for c in cfgs:
            for r in by:
                if r["config"] == c and r["bytes_per_16k"]:
                    lines.append("| %s | %s | %.1f | %.1f |" % (c, r["bytes_per_16k"], int(r["dev_write_bytes"]) / 2**30,
                                                               int(r["app_write_bytes"]) / 2**30))
        lines.append("")
    # per-second bandwidth (BW_LOG=1)
    flat = []
    for r in rows:
        label = "%s_%s_%s_t%s_f%s_r%s" % (r["exp"], r["config"], r["op"], r["threads"], r["files"], r["rep"])
        v = bw_series(str(Path(r["_dir"]) / "runs" / label))
        if len(v) >= 6:
            v = v[1:-1]           # partial first and last seconds
            h = len(v) // 2
            med = statistics.median(v)
            flat.append((label, statistics.mean(v[h:]) / statistics.mean(v[:h]), min(v) / med if med else 0,
                         len(v)))
    if flat:
        lines += ["## per-second bandwidth: second half ÷ first half, lowest second ÷ median", "",
                  "| run | 2nd ÷ 1st half | min ÷ median | seconds |", "|---|---|---|---|"]
        for label, ratio, low, n in flat:
            mark = " ⚠" if ratio < 0.9 or low < 0.5 else ""
            lines.append("| %s | %.2f%s | %.2f | %d |" % (label, ratio, mark, low, n))
        lines.append("")
    text = "\n".join(lines)
    if out:
        Path(out).write_text(text)
    print(text)


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        sys.exit(1)
    if a[0] == "header":
        header()
    elif a[0] == "row":
        print_row(a[1])
    elif a[0] == "brief":
        brief(a[1])
    elif a[0] == "tables":
        out = None
        if "-o" in a:
            i = a.index("-o")
            out = a[i + 1]
            del a[i:i + 2]
        tables(a[1:], out)


if __name__ == "__main__":
    main()
