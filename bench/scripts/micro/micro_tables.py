#!/usr/bin/env python3
"""Tables from run_micro.sh results: for every (pattern, file count), per
configuration and thread count, the mean over repetitions of IOPS (± relative
standard deviation), fdatasync latency mean and p99, and device KB written per
op. Runs whose window was cut by exhausted offsets are marked with *.

Usage: micro_tables.py <result dir> [<result dir> ...] [-o tables.md]
"""
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ORDER = ["EXT4_Raw", "EXT4_Data", "XFS_Raw", "ZFS", "tau-EXT4", "tau-XFS"]


def main():
    args = sys.argv[1:]
    out = None
    if "-o" in args:
        i = args.index("-o")
        out = Path(args[i + 1])
        del args[i:i + 2]
    rows = []
    for d in args:
        with open(Path(d) / "results.csv") as f:
            rows += list(csv.DictReader(f))
    groups = defaultdict(list)
    for r in rows:
        groups[(r["pattern"], int(r["files"]), r["config"], int(r["threads"]))].append(r)
    md = ["# atomicw results", "",
          "Mean over repetitions; IOPS ± relative s.d.; * = window cut by exhausted offsets.", ""]
    keys = sorted({(p, f) for p, f, _, _ in groups},
                  key=lambda k: (["overwrite", "prealloc", "hole", "append"].index(k[0]), k[1]))
    for pattern, files in keys:
        cfgs = [c for c in ORDER if any(k[0] == pattern and k[1] == files and k[2] == c for k in groups)]
        cfgs += sorted({k[2] for k in groups if k[0] == pattern and k[1] == files} - set(cfgs))
        threads = sorted({k[3] for k in groups if k[0] == pattern and k[1] == files})

        def cell(c, t, fn):
            g = groups.get((pattern, files, c, t))
            return fn(g) if g else "–"

        def iops(g):
            v = [float(r["iops"]) for r in g]
            m = statistics.mean(v)
            sd = statistics.stdev(v) / m * 100 if len(v) > 1 and m else 0
            star = "*" if any(r["exhausted"] == "1" for r in g) else ""
            return f"{m:,.0f} ±{sd:.0f}%{star}"

        def mean_of(field, scale=1.0, fmt="{:,.0f}"):
            return lambda g: fmt.format(statistics.mean(float(r[field]) for r in g) * scale)

        for title, fn in [
            ("IOPS", iops),
            ("fdatasync mean (µs)", mean_of("lat_mean_us")),
            ("fdatasync p99 (µs)", mean_of("lat_p99_us")),
            ("device KB written per op", mean_of("dev_bytes_per_op", 1 / 1024, "{:.1f}")),
        ]:
            md.append(f"## {pattern}, {files} files: {title}\n")
            md.append("| threads | " + " | ".join(cfgs) + " |")
            md.append("|---|" + "---|" * len(cfgs))
            for t in threads:
                md.append(f"| {t} | " + " | ".join(cell(c, t, fn) for c in cfgs) + " |")
            md.append("")
    text = "\n".join(md)
    if out:
        out.write_text(text + "\n")
    print(text)


if __name__ == "__main__":
    main()
