#!/usr/bin/env python3
"""EVAL_PLAN R1 redesign: N files written of F open (run_fio.sh EXPS=r1 R1_IDLE=sparse R1_MEM=1), one row per F.

Reads the result directory's results.csv (fio_report.py row fields) and, per run, runs/<label>.taucount (bpftrace:
"t <ns>", "@a: <alloc_tau calls>", "@f: <free_tau calls>" each second) and runs/<label>.mem (/proc/meminfo and slab
lines at "== start" before the tool, "== ramp" at the ramp's end, all files open, and "== end" at the window's end).
Per F (mean over its runs unless said otherwise):
  IOPS (± relative s.d.) and its share of the reference case's (the case with F == N, all files written: 64 of 64);
  tau files: alloc_tau - free_tau, the most during the run (all F are open before the workers start);
  tau memory, computed: tau files x (16 pages + tau_t 4,096 B (kmalloc-4k) + 16 buffer_heads x 104 B) = 69.6 KiB each
    (alloc_tau() of 6.8.0tjournal-v1.1; sizes from its BTF and /proc/slabinfo);
  measured from start to ramp: (MemTotal - MemAvailable), SUnreclaim and the buffer_head and kmalloc-4k slabs;
  fdatasync p99, pwrite p99.9 and max, CPU per 16 KiB page, device KiB per 16 KiB, the umount after the run (s).
Usage: r1o_report.py <run_fio.sh result dir>
"""
import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

PAGE = 4096
PER_FILE = 16 * PAGE + 4096 + 16 * 104   # bytes per tau file, alloc_tau() on v1.1
MB = 1024 * 1024


def taucount(path):
    """[(ns, alloc, free)] per second."""
    rows, t, a, f = [], None, 0, 0
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith("t "):
                if t is not None:
                    rows.append((t, a, f))
                t = int(line.split()[1])
            elif line.startswith("@a:"):
                a = int(line.split(":")[1])
            elif line.startswith("@f:"):
                f = int(line.split(":")[1])
        if t is not None:
            rows.append((t, a, f))
    except OSError:
        pass
    return rows


def mem(path):
    """{section: {"meminfo key": kB, "slab:<name>": bytes}}"""
    out, cur = {}, None
    try:
        for line in open(path):
            m = re.match(r"^== (\w+) ", line)
            if m:
                cur = out.setdefault(m.group(1), {})
                continue
            if cur is None:
                continue
            m = re.match(r"^(\w+(?:\(\w+\))?):\s+(\d+)", line)
            if m:
                cur[m.group(1)] = int(m.group(2))
                continue
            w = line.split()
            if len(w) > 4 and w[1].isdigit() and w[3].isdigit():   # slabinfo: name active num objsize ...
                cur["slab:" + w[0]] = int(w[1]) * int(w[3])
    except OSError:
        pass
    return out


def mean(xs):
    xs = [x for x in xs if x is not None]
    return statistics.mean(xs) if xs else None


def fmt(v, spec):
    return "" if v is None else format(v, spec)


def main():
    d = Path(sys.argv[1])
    rows = [r for r in csv.DictReader(open(d / "results.csv")) if r.get("exp") == "r1"]
    if not rows:
        sys.exit(f"no r1 rows in {d}/results.csv")
    by = defaultdict(list)
    for r in rows:
        by[(int(r["files"]), int(r["write_files"] or r["files"]))].append(r)
    ref = [k for k in by if k[0] == k[1]]
    ref_iops = mean(float(r["write_iops"]) for r in by[min(ref)]) if ref else None
    print(f"# R1, {rows[0]['config']}: N written of F open ({d.name})\n")
    print("| F open | N written | runs | IOPS | ÷ IOPS(F=N) | tau files (most alive) | tau memory MiB (computed) |"
          " Δ used MiB (meminfo) | Δ SUnreclaim MiB | Δ buffer_head + kmalloc-4k MiB | fdatasync p99 µs |"
          " pwrite p99.9 µs | pwrite max ms | CPU µs/page proc / host | device KiB per 16 KiB | umount s |")
    print("|" + "---:|" * 16)
    for (f, n) in sorted(by):
        rs = by[(f, n)]
        iops = [float(r["write_iops"]) for r in rs]
        sd = 100 * statistics.stdev(iops) / statistics.mean(iops) if len(iops) > 1 else None
        alive_max, used, sunr, slabs = [], [], [], []
        for r in rs:
            lab = f"r1_{r['config']}_overwrite_t{r['threads']}_f{r['files']}_w{r['write_files'] or r['files']}_r{r['rep']}"
            tc = taucount(d / "runs" / f"{lab}.taucount")
            mm = mem(d / "runs" / f"{lab}.mem")
            if tc:
                alive_max.append(max(a - fr for _, a, fr in tc))
            s, p = mm.get("start"), mm.get("ramp")
            if s and p:
                used.append(((p["MemTotal"] - p["MemAvailable"]) - (s["MemTotal"] - s["MemAvailable"])) * 1024 / MB)
                sunr.append((p.get("SUnreclaim", 0) - s.get("SUnreclaim", 0)) * 1024 / MB)
                slabs.append(sum(p.get(k, 0) - s.get(k, 0) for k in ("slab:buffer_head", "slab:kmalloc-4k")) / MB)
        tf = mean(alive_max)
        print("| %d | %d | %d | %s%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s / %s | %s | %s |" % (
            f, n, len(rs), fmt(statistics.mean(iops), ",.0f"), f" ±{sd:.0f}%" if sd is not None else "",
            fmt(100 * statistics.mean(iops) / ref_iops, ".1f") + "%" if ref_iops else "",
            fmt(tf, ",.0f"),
            fmt(tf * PER_FILE / MB if tf is not None else None, ",.1f"),
            fmt(mean(used), ",.1f"), fmt(mean(sunr), ",.1f"), fmt(mean(slabs), ",.1f"),
            fmt(mean(float(r["sync_p99_us"]) for r in rs), ",.1f"),
            fmt(mean(float(r["write_p999_us"]) for r in rs), ",.1f"),
            fmt(max(float(r["write_max_us"]) for r in rs) / 1000, ",.1f"),
            fmt(mean(float(r["cpu_proc_us_per_page"]) for r in rs if r.get("cpu_proc_us_per_page")), ".2f"),
            fmt(mean(float(r["cpu_host_us_per_page"]) for r in rs if r.get("cpu_host_us_per_page")), ".2f"),
            fmt(mean(float(r["dev_bytes_per_16k"]) for r in rs), ".1f"),
            fmt(mean(float(r["elapsed_total_s"]) - float(r["elapsed_s"]) for r in rs), ",.0f")))
    print(f"\ntau memory per tau file: {PER_FILE:,} B (16 x {PAGE} + 4,096 + 16 x 104). Δ columns: '== ramp' minus "
          "'== start' in runs/<label>.mem (the ramp sample also holds 10 s of writes' page cache, which MemAvailable "
          "counts as available). umount s: elapsed_total_s - elapsed_s (syncfs + umount after the window).")


if __name__ == "__main__":
    main()
