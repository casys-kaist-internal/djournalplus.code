#!/usr/bin/env python3
"""Write this machine's benchmark summary into git.

The results stay outside git ($TAU_RESULTS, bench/workspace/results/<host>).
This reads every sysbench run there (each run's summary.csv from
parse_main.py; made first if missing) and every BenchBase TPC-C run of
run_tpcc.sh (benchbase/<db>/<run>/, read with benchbase/pilot_report.py), and
writes bench/results/<host>/SUMMARY.md: the machine, then sysbench throughput
by workload, file system and protection over the thread counts, and TPC-C
tpmC by file system, protection and warehouses over the terminal counts, each
from the newest run that measured it.  Runs in 99_Archive are left out.

Usage: export_results.py [<raw results dir>]   (default: $TAU_RESULTS)
"""
import csv
import os
import re
import statistics
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
HOST = os.uname().nodename.split(".")[0]
TPCC_LABEL = re.compile(r"(mysql|postgres)_tpcc_(.+?)_fpw_(on|off)_w(\d+)_c(\d+)_r(\d+)$")
MACHINE_KEYS = ("host", "product", "kernel", "model", "topology", "turbo",
                "cstates", "memtotal", "dimms", "test_device", "postgres",
                "mysql", "zfs")


def have_summary(run):
    """The run's summary.csv, made with parse_main.py if missing."""
    if not (run / "summary.csv").exists():
        out = subprocess.run(
            [sys.executable, str(HERE / "sysbench/parse_main.py"), str(run)],
            capture_output=True, text=True)
        if out.returncode != 0 or not (run / "summary.csv").exists():
            return False
        (run / "summary.txt").write_text(out.stdout)
    return True


def machine_lines(env):
    """The snapshot's main lines, and the test device's own line."""
    lines = env.read_text().splitlines()
    keys = {l.split(":", 1)[0].strip(): l.rstrip() for l in lines if ":" in l}
    keep = []
    for line in lines:
        key = line.split(":", 1)[0].strip()
        if key in MACHINE_KEYS:
            keep.append("    " + line.rstrip())
            if key == "test_device":
                ctrl = re.sub(r"n\d+$", "", line.split(":", 1)[1].strip())
                if ctrl in keys:
                    keep.append("    " + keys[ctrl])
    return keep


def num(x):
    try:
        return float(str(x).split()[0].rstrip("%"))
    except (ValueError, IndexError, TypeError):
        return None


def tpcc_points(raw):
    """(db, fs, fpw, warehouses) -> (run, {terminals: [(tpmC, p99 ms, device
    KB per new order), ...]}) from the newest run_tpcc.sh run that measured
    it; and the runs without measurements in that naming."""
    sys.path.insert(0, str(HERE / "benchbase"))
    import pilot_report
    points, skipped = {}, []
    for db in ("mysql", "postgres"):
        src = raw / "benchbase" / db
        for run in sorted(d for d in src.glob("20*") if d.is_dir()) if src.is_dir() else []:
            vals = defaultdict(list)
            for xml in sorted(run.glob("*_r[0-9]*.xml")):
                m = TPCC_LABEL.match(xml.stem)
                if not m or not list(run.glob("%s/*.summary.json" % xml.stem)):
                    continue
                db_, fs, fpw, wh, terminals, _ = m.groups()
                r = pilot_report.run_row(str(run), xml.stem)
                p99 = num(r["latency avg / p95 / p99 (ms)"].split(" / ")[2])
                vals[(db_, fs, fpw, int(wh), int(terminals))].append((
                    r["tpmC, database (new orders over the whole run)"], p99,
                    num(r.get("device writes per new order (KB)"))))
            if not vals:
                skipped.append("%s/%s" % (db, run.name))
            for (db_, fs, fpw, wh, terminals), v in vals.items():
                k = (db_, fs, fpw, wh)
                if k not in points or points[k][0] != run.name:
                    points[k] = (run.name, {})      # a newer run replaces it
                points[k][1][terminals] = v
    return points, skipped


def tpcc_md(points):
    if not points:
        return []
    lines = ["TPC-C (BenchBase, warehouses chosen at random per transaction, no"
             " think time): tpmC = new orders per minute counted by the database"
             " over each 5-min measurement (mean of the runs at a point); p99 and"
             " device KB per new order (KB/NO) at the most terminals.", ""]
    for db in sorted({k[0] for k in points}):
        keys = sorted(k for k in points if k[0] == db)
        terms = sorted({t for k in keys for t in points[k][1]})
        lines += ["## TPC-C %s" % db, "",
                  "| fs | protection | WH | " + " | ".join(
                      "%d term" % t for t in terms) + " | p99 ms | KB/NO | run |",
                  "|---|---|---:|" + "---:|" * len(terms) + "---:|---:|---|"]
        for k in keys:
            name, by = points[k]
            top = by[max(by)]
            cells = ["%.0f" % statistics.mean(v[0] for v in by[t]) if t in by else ""
                     for t in terms]
            p99 = [v[1] for v in top if v[1] is not None]
            kb = [v[2] for v in top if v[2] is not None]
            lines.append("| %s | %s | %d | %s | %s | %s | `%s` |" % (
                k[1], k[2], k[3], " | ".join(cells),
                "%.1f" % statistics.mean(p99) if p99 else "",
                "%.0f" % statistics.mean(kb) if kb else "", name))
        lines.append("")
    return lines


def summary_md(raw, runs, tpcc=None):
    """runs: {db: [run dir names, oldest first]}; tpcc: tpcc_points()"""
    points = {}         # (db, workload, fs, fpw) -> (run, {threads: (tps, kb)})
    for db, names in runs.items():
        for name in names:
            vals = defaultdict(lambda: ([], []))
            with open(raw / "sysbench" / db / name / "summary.csv") as f:
                for row in csv.DictReader(f):
                    key = (row["db"], row["workload"], row["fs"], row["fpw"])
                    tps, kb = vals[key + (int(row["threads"]),)]
                    tps.append(float(row["tps"]))
                    if row.get("dev_write_kb_per_trx"):
                        kb.append(float(row["dev_write_kb_per_trx"]))
            for (db_, wl, fs, fpw, thr), (tps, kb) in vals.items():
                k = (db_, wl, fs, fpw)
                if k not in points or points[k][0] != name:
                    points[k] = (name, {})          # a newer run replaces it
                points[k][1][thr] = (statistics.mean(tps),
                                     statistics.mean(kb) if kb else None)
    lines = ["# %s: benchmark summary" % HOST, "",
             "Made by `bench/scripts/export_results.py` from the results in",
             "`bench/workspace/results/%s/{sysbench,benchbase}/<db>/<run>/` (outside git, on %s);"
             % (HOST, HOST),
             "notes on the runs in `README.md`.", ""]
    newest = max(((db, n) for db, ns in runs.items() for n in ns),
                 key=lambda x: x[1], default=None)
    if newest:
        env = raw / "sysbench" / newest[0] / newest[1] / "env.txt"
        if env.exists():
            lines += ["Machine (`env.txt` of %s/%s; full snapshot in"
                      " `bench/machines/%s.txt`):" % (newest[0], newest[1], HOST),
                      ""] + machine_lines(env) + [""]
    lines += ["Throughput in transactions/s (mean of the runs at a point);"
              " protection on = PostgreSQL",
              "full_page_writes / InnoDB doublewrite; KB/trx = device writes per"
              " transaction at the most threads.", ""]
    for db in sorted({k[0] for k in points}):
        keys = sorted(k for k in points if k[0] == db)
        thrs = sorted({t for k in keys for t in points[k][1]})
        lines += ["## sysbench %s" % db, "",
                  "| workload | fs | protection | " + " | ".join(
                      "%d thr" % t for t in thrs) + " | KB/trx | run |",
                  "|---|---|---|" + "---:|" * len(thrs) + "---:|---|"]
        for k in keys:
            name, by = points[k]
            top = by[max(by)]
            cells = ["%.0f" % by[t][0] if t in by else "" for t in thrs]
            lines.append("| %s | %s | %s | %s | %s | `%s` |" % (
                k[1].replace("oltp_", ""), k[2], k[3], " | ".join(cells),
                "%.1f" % top[1] if top[1] is not None else "", name))
        lines.append("")
    lines += tpcc_md(tpcc or {})
    out = REPO / "bench/results" / HOST
    out.mkdir(parents=True, exist_ok=True)
    (out / "SUMMARY.md").write_text("\n".join(lines))
    return out / "SUMMARY.md"


def main():
    raw = Path(sys.argv[1] if len(sys.argv) > 1 else
               os.environ.get("TAU_RESULTS",
                              REPO / "bench/workspace/results" / HOST))
    runs = {}
    for db in ("mysql", "postgres"):
        src = raw / "sysbench" / db
        # profiling runs (run_main.sh PROFILE=..., <run>_prof-<mode>) carry
        # instruments and one point only: not throughput data
        names = sorted(d.name for d in src.glob("20*")
                       if d.is_dir() and "_prof-" not in d.name) \
            if src.is_dir() else []
        kept = [n for n in names if have_summary(src / n)]
        if kept:
            runs[db] = kept
        if len(kept) < len(names):
            print("%s: no measurements in %s" % (
                db, ", ".join(sorted(set(names) - set(kept)))))
    tpcc, skipped = tpcc_points(raw)
    if skipped:
        print("benchbase: no run_tpcc.sh measurements in %s" % ", ".join(skipped))
    path = summary_md(raw, runs, tpcc)
    print("%d sysbench runs and %d TPC-C runs summarized in %s" % (
        sum(map(len, runs.values())), len({(k[0], v[0]) for k, v in tpcc.items()}), path))


if __name__ == "__main__":
    main()
