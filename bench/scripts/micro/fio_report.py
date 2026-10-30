#!/usr/bin/env python3
"""Results of run_fio.sh (spec v2), from fio (<prefix>.json) or atomicw (<prefix>.aw.csv).

  fio_report.py header                     the CSV header of results.csv
  fio_report.py row <run prefix>           one CSV line from <prefix>.json/.info/.err/.tau
  fio_report.py brief <run prefix>         one line for the run log
  fio_report.py gate <run prefix> [GB]     the tau gate: PASS if no pwrite takes 1 s and,
                                           after the journal (GB, default 40) fills, the last
                                           third of the run is within 5% of the middle third
  fio_report.py tables <result dir> [...] [-o tables.md]

A run prefix is <result dir>/runs/<label>. results.csv: the spec's columns
(exp ... notes, then wmode = atomicw's raw/tau/app, batch_n, commit_mean_us,
commit_p99_us: the batch commit, see atomicw.c), then tool, commit_p999_us, sync_n (fdatasyncs counted by fio), elapsed_s (fio),
elapsed_total_s (to after syncfs + umount), dev_write_bytes (start to after
umount), io_bytes, tau_fds (fio's open files under the mount with
O_TAU_UNTORN, mid-run), tau_used_max_mb and tau_running_max (the kernel's
Tau_Daemon lines, every 15 s), then from atomicw (2026-10-30 on): write_files
(files written; the rest stay open), cpu_proc_us_per_page and
cpu_host_us_per_page (CPU over the window, the process and the whole host, per
16 KiB page), host_busy_pct, slab_mb and sunreclaim_mb (at the window's end).

dev_write_gb_s is the device's written bytes from the start of fio to after
syncfs + umount over that time (GB = 10^9 bytes); dev_bytes_per_16k is KiB
written on the device per 16 KiB fio wrote, counted from the end of the ramp
(fio's io_bytes leave the ramp out) to after the umount. write_p999_us and
write_max_us are fio's write completion latencies (psync: the whole pwrite).
"""
import csv
import glob
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

COLS = ["exp", "config", "op", "threads", "files", "fdatasync_n", "dist", "rep", "mode", "runtime_s",
        "write_iops", "write_bw_mib_s", "sync_mean_us", "sync_p99_us", "write_p999_us", "write_max_us",
        "dev_write_gb_s", "dev_bytes_per_16k", "kernel", "notes",
        "wmode", "batch_n", "commit_mean_us", "commit_p99_us", "tool", "commit_p999_us",
        "sync_n", "elapsed_s", "elapsed_total_s", "dev_write_bytes", "io_bytes", "tau_fds",
        "tau_used_max_mb", "tau_running_max",
        "write_files", "cpu_proc_us_per_page", "cpu_host_us_per_page", "host_busy_pct", "slab_mb",
        "sunreclaim_mb"]
ORDER = ["EXT4_Raw", "XFS_Raw", "EXT4_App", "XFS_App", "EXT4_Data", "ZFS", "tau-EXT4", "tau-XFS"]
EXPS = ["e1", "e2", "sync1", "zoned", "bytes", "gate", "kcheck", "r1"]
OPS = ["overwrite", "prealloc", "hole", "append"]
TAU_LINE = re.compile(r"^\[ *([\d.]+)\] Tau_Daemon: Used journal (\d+)MB / \(Total\) (\d+)MB, running tau: (\d+)")
MARK = re.compile(r"^\[ *([\d.]+)\] fio-run-")


def info(prefix):
    d = {}
    for line in Path(prefix + ".info").read_text().splitlines():
        if line.startswith("exp="):
            d.update(kv.split("=", 1) for kv in line.split())
        elif "=" in line:
            k, v = line.split("=", 1)
            d[k] = v
    return d


def sectors(inf, key):
    return int(inf[key].split()[1]) if inf.get(key) else None


def tau_lines(prefix):
    """(seconds after the run's marker, used MB, total MB, running tau)"""
    p = Path(prefix + ".tau")
    if not p.exists():
        return []
    t0, out = None, []
    for line in p.read_text(errors="replace").splitlines():
        m = MARK.match(line)
        if m and t0 is None:
            t0 = float(m.group(1))
        m = TAU_LINE.match(line)
        if m:
            out.append((float(m.group(1)) - (t0 or float(m.group(1))), int(m.group(2)), int(m.group(3)),
                        int(m.group(4))))
    return out


def aw_row(prefix, r):
    """atomicw's CSV line into the columns; returns (io_bytes, notes, error)"""
    lines = Path(prefix + ".aw.csv").read_text().splitlines()
    a = dict(zip(lines[0].split(","), lines[1].split(","))) if len(lines) > 1 else {}
    if not a:
        return 0, [], "no atomicw output"
    unit = int(a["unit"])
    r["tool"] = "atomicw"
    r["wmode"], r["batch_n"] = a["wmode"], a["batch"]
    r["runtime_s"] = "%.1f" % float(a["duration_s"])
    r["write_iops"] = "%.0f" % float(a["iops"])
    r["write_bw_mib_s"] = "%.1f" % (float(a["iops"]) * unit / 2**20)
    r["commit_mean_us"], r["commit_p99_us"], r["commit_p999_us"] = a["commit_mean_us"], a["commit_p99_us"], a["commit_p999_us"]
    r["sync_mean_us"], r["sync_p99_us"] = a["sync_mean_us"], a["sync_p99_us"]
    r["write_p999_us"], r["write_max_us"] = a["write_p999_us"], a["write_max_us"]
    r["sync_n"] = a["batches"]
    for k in ("write_files", "cpu_proc_us_per_page", "cpu_host_us_per_page", "host_busy_pct", "slab_mb",
              "sunreclaim_mb"):    # atomicw 2026-10-30 and later
        r[k] = a.get(k, "")
    return int(a["pages"]) * unit, [a["notes"]] if a.get("notes") else [], None


def row(prefix):
    inf = info(prefix)
    r = {k: inf.get(k, "") for k in COLS[:9]}
    r["kernel"] = inf.get("kernel", "")
    if Path(prefix + ".aw.csv").exists():
        io, notes, err = aw_row(prefix, r)
        r["io_bytes"] = str(io)
        r["elapsed_s"] = inf.get("elapsed_s", "")
        r["elapsed_total_s"] = inf.get("elapsed_total_s", "")
        dev_cols(r, inf, io)
        tau_cols(r, prefix)
        e = Path(prefix + ".err").read_text(errors="replace").strip() if Path(prefix + ".err").exists() else ""
        if e:
            notes.append("stderr: " + e.splitlines()[0][:80].replace(",", ";"))
        if err:
            notes.append(err)
        r["notes"] = "; ".join(notes)
        return r
    j = json.load(open(prefix + ".json"))["jobs"][0]
    w, s = j["write"], j.get("sync", {}).get("lat_ns", {})
    r["tool"] = "fio"
    r["wmode"] = "tau" if r["config"].startswith("tau-") else "raw"
    r["batch_n"] = r["fdatasync_n"]
    r["runtime_s"] = "%.1f" % (w["runtime"] / 1000)
    r["write_iops"] = "%.0f" % w["iops"]
    r["write_bw_mib_s"] = "%.1f" % (w["bw_bytes"] / 2**20)
    if s.get("N"):
        r["sync_mean_us"] = "%.1f" % (s["mean"] / 1000)
        p99 = s.get("percentile", {}).get("99.000000")
        r["sync_p99_us"] = "%.0f" % (p99 / 1000) if p99 else ""
    c = w.get("clat_ns", {})
    p999 = c.get("percentile", {}).get("99.900000")
    r["write_p999_us"] = "%.0f" % (p999 / 1000) if p999 else ""
    r["write_max_us"] = "%.0f" % (c.get("max", 0) / 1000)
    r["io_bytes"] = str(w["io_bytes"])
    r["sync_n"] = str(s.get("N", 0))
    r["elapsed_s"] = inf.get("elapsed_s", "")
    r["elapsed_total_s"] = inf.get("elapsed_total_s", "")
    dev_cols(r, inf, w["io_bytes"])
    tau_cols(r, prefix)
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
        job = Path(prefix + ".fio").read_text()
        m2, nj = re.search(r"^size=(\d+)g", job, re.M), re.search(r"^numjobs=(\d+)", job, re.M)
        if m2 and nj and w["io_bytes"] != int(m2.group(1)) * 2**30 * int(nj.group(1)):
            notes.append("io_bytes %d of %d" % (w["io_bytes"], int(m2.group(1)) * 2**30 * int(nj.group(1))))
    r["notes"] = "; ".join(notes)
    return r


def dev_cols(r, inf, io_bytes):
    d0, dr, d2 = sectors(inf, "dev_start"), sectors(inf, "dev_ramp"), sectors(inf, "dev_end")
    if d0 is not None and d2 is not None:
        dev = (d2 - d0) * 512
        r["dev_write_bytes"] = str(dev)
        if inf.get("elapsed_total_s"):
            r["dev_write_gb_s"] = "%.2f" % (dev / float(inf["elapsed_total_s"]) / 1e9)
        base = dr if dr is not None else d0
        if io_bytes:
            r["dev_bytes_per_16k"] = "%.1f" % ((d2 - base) * 512 / io_bytes * 16)


def tau_cols(r, prefix):
    r["tau_fds"] = info(prefix).get("tau_fds", "")
    tl = tau_lines(prefix)
    if tl:
        r["tau_used_max_mb"] = str(max(x[1] for x in tl))
        r["tau_running_max"] = str(max(x[3] for x in tl))


def header():
    print(",".join(COLS))


def print_row(prefix):
    r = row(prefix)
    print(",".join(str(r.get(c, "")) for c in COLS))


def brief(prefix):
    r = row(prefix)
    s = "%s IOPS, %s MiB/s, %sfdatasync %s us (p99 %s), pwrite p99.9 %s us max %.0f ms, device %s GB/s, %s KiB per 16 KiB" % (
        r["write_iops"], r["write_bw_mib_s"],
        "commit %s us (p99 %s), " % (r["commit_mean_us"], r["commit_p99_us"]) if r.get("commit_mean_us") else "",
        r.get("sync_mean_us") or "-", r.get("sync_p99_us") or "-",
        r.get("write_p999_us") or "-", float(r["write_max_us"] or 0) / 1000, r.get("dev_write_gb_s") or "-",
        r.get("dev_bytes_per_16k") or "-")
    if r["mode"] == "size":
        s += ", %s s" % r["runtime_s"]
    if r["config"].startswith("tau-"):
        s += ", fds %s, journal max %s MB" % (r["tau_fds"] or "?", r.get("tau_used_max_mb") or "-")
    if r["notes"]:
        s += " [%s]" % r["notes"]
    print(s)


def bw_series(prefix):
    if Path(prefix + ".tl").exists():
        return aw_series(prefix)
    return fio_series(prefix)


def aw_series(prefix):
    """KiB/s per second from atomicw's timeline (pages per second since the
    start), the warm-up left out like fio's logs"""
    lines = Path(prefix + ".tl").read_text().splitlines()
    m = re.search(r"warm-up (\d+) s", lines[0]) if lines else None
    warm = int(m.group(1)) if m else 0
    unit = 16
    a = Path(prefix + ".aw.csv")
    if a.exists():
        ls = a.read_text().splitlines()
        if len(ls) > 1:
            unit = int(dict(zip(ls[0].split(","), ls[1].split(",")))["unit"]) // 1024
    v = [int(x.split()[1]) * unit for x in lines[1:] if len(x.split()) == 2 and int(x.split()[0]) >= warm]
    while v and v[-1] == 0:
        v.pop()
    return [float(x) for x in v]


def fio_series(prefix):
    """KiB/s per second over the job logs of a run (fio logs after the ramp).
    With log_avg_msec=1000 an entry holds the bytes of the second before it
    (the entries add up to fio's io_bytes; a job blocked in a call logs
    nothing until it completes again): each entry's bytes are spread over
    (t - 1 s, t] in 1-s bins, then summed over the jobs."""
    per = defaultdict(float)
    for f in glob.glob(prefix + "_bw.*.log"):
        for line in open(f):
            p = line.split(",")
            if len(p) < 2:
                continue
            t, kib = int(p[0]), float(p[1])
            s = t - 1000
            while s < t:
                e = min(t, (s // 1000 + 1) * 1000)
                per[s // 1000] += kib * (e - s) / 1000
                s = e
    return [per[k] for k in sorted(per)]


def flatness(prefix):
    """(2nd half / 1st half, last third / middle third, min 1 s / median) or None"""
    v = bw_series(prefix)
    if len(v) < 9:
        return None
    v = v[1:-2]                   # partial seconds at both ends
    h, t = len(v) // 2, len(v) // 3
    med = statistics.median(v)
    return (statistics.mean(v[h:]) / statistics.mean(v[:h]),
            statistics.mean(v[2 * t:]) / statistics.mean(v[t:2 * t]),
            min(v) / med if med else 0)


def gate(prefix, cap_gb=40):
    r = row(prefix)
    inf = info(prefix)
    ramp = 0
    m = re.search(r"^ramp_time=(\d+)", Path(prefix + ".fio").read_text(), re.M)
    if m:
        ramp = int(m.group(1))
    v = bw_series(prefix)
    n = len(v)
    third = n // 3
    mid, last = v[third:2 * third], v[2 * third:3 * third]
    ratio = statistics.mean(last) / statistics.mean(mid) if mid and last else 0
    wmax = float(r["write_max_us"] or 0) / 1e6
    full = [x for x in tau_lines(prefix) if x[1] >= cap_gb * 1024 * 0.99]
    full_at = full[0][0] - ramp if full else None     # seconds into the measured window
    ok_lat, ok_flat = wmax < 1.0, abs(ratio - 1) <= 0.05
    ok_full = full_at is not None and full_at <= third
    print("gate %s (%s): %s" % (inf.get("config"), inf.get("kernel"), "PASS" if ok_lat and ok_flat and ok_full else "FAIL"))
    print("  pwrite max %.3f s (limit 1 s): %s" % (wmax, "ok" if ok_lat else "FAIL"))
    print("  throughput, last third / middle third of the %d s window: %.3f (limit ±5%%): %s" % (
        n, ratio, "ok" if ok_flat else "FAIL"))
    print("  tau journal at %d GB: %s" % (cap_gb, "full %.0f s into the window" % full_at if full_at is not None
                                          else "never full in the run (no Tau_Daemon line at the cap)")
          + ("" if ok_full else ": the comparison is not after the journal filled"))
    print("  %s IOPS, fdatasync p99 %s us, pwrite p99.9 %s us, device %s GB/s, %s KiB per 16 KiB" % (
        r["write_iops"], r.get("sync_p99_us"), r.get("write_p999_us"), r.get("dev_write_gb_s"), r.get("dev_bytes_per_16k")))


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
    cfgs = [c for c in ORDER if any(r["config"] == c for r in rows)]
    kernels = sorted({r["kernel"] for r in rows})
    lines = ["# fio results", "", "Kernels: %s. Mean over runs; IOPS ± relative s.d." % ", ".join(kernels), ""]
    groups = defaultdict(list)
    for r in rows:
        axis = "files" if r["exp"] == "e2" else "threads"
        groups[(r["exp"], r["op"], r["dist"], r["fdatasync_n"], axis)].append(r)
    keyf = lambda k: (EXPS.index(k[0]) if k[0] in EXPS else 9, OPS.index(k[1]) if k[1] in OPS else 9)
    for key in sorted(groups, key=keyf):
        exp, op, dist, n, axis = key
        rs = groups[key]
        xs = sorted({int(r[axis]) for r in rs})
        title = "%s %s, %s, fdatasync every %s write%s" % (exp, op, dist, n, "" if n == "1" else "s")
        metrics = [("write_iops", "IOPS"), ("commit_mean_us", "batch commit mean (µs)"),
                   ("commit_p99_us", "batch commit p99 (µs)"), ("sync_p99_us", "fdatasync p99 (µs)"),
                   ("write_p999_us", "pwrite p99.9 (µs)"), ("write_max_us", "pwrite max (ms)"),
                   ("dev_write_gb_s", "device write GB/s (to umount)"),
                   ("dev_bytes_per_16k", "device KiB per 16 KiB")]
        if any(r["mode"] == "size" for r in rs):
            metrics.append(("runtime_s", "run time (s)"))
        for metric, name in metrics:
            lines += ["## %s: %s" % (title, name), "",
                      "| %s | %s |" % (axis, " | ".join(cfgs)), "|---|" + "---|" * len(cfgs)]
            for x in xs:
                cells = []
                for c in cfgs:
                    v = [float(r[metric]) for r in rs if r["config"] == c and int(r[axis]) == x and r[metric]]
                    if not v:
                        cells.append("")
                    elif metric == "write_iops":
                        m, sd = mean_sd(v)
                        cells.append("{:,.0f} ±{:.0f}%".format(m, sd) if len(v) > 1 else "{:,.0f}".format(m))
                    elif metric == "write_max_us":
                        cells.append("{:,.0f}".format(max(v) / 1000))
                    elif metric == "dev_write_gb_s":
                        cells.append("{:.2f}".format(statistics.mean(v)))
                    elif metric == "dev_bytes_per_16k":
                        cells.append("{:.1f}".format(statistics.mean(v)))
                    else:
                        cells.append("{:,.0f}".format(statistics.mean(v)))
                lines.append("| %d | %s |" % (x, " | ".join(cells)))
            lines.append("")
    flat = []
    for r in rows:
        if r["mode"] != "time":
            continue
        label = "%s_%s_%s_t%s_f%s_r%s" % (r["exp"], r["config"], r["op"], r["threads"], r["files"], r["rep"])
        f = flatness(str(Path(r["_dir"]) / "runs" / label))
        if f:
            flat.append((label, f))
    if flat:
        lines += ["## 1-s bandwidth: 2nd half ÷ 1st half, last third ÷ middle third, lowest second ÷ median", "",
                  "| run | 2nd ÷ 1st half | last ÷ middle third | min ÷ median |", "|---|---|---|---|"]
        for label, (a, b, c) in flat:
            mark = " ⚠" if abs(b - 1) > 0.05 or c < 0.5 else ""
            lines.append("| %s | %.2f | %.2f%s | %.2f |" % (label, a, b, mark, c))
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
    elif a[0] == "gate":
        gate(a[1], int(a[2]) if len(a) > 2 else 40)
    elif a[0] == "tables":
        out = None
        if "-o" in a:
            i = a.index("-o")
            out = a[i + 1]
            del a[i:i + 2]
        tables(a[1:], out)


if __name__ == "__main__":
    main()
