#!/usr/bin/env python3
"""The fast test's libra09 performance half (bench/suite/fast_perf.sh): metrics, guard, report.

Reads the run directories that fast_perf.sh made under one output directory
(<out>/sysbench/<db>/<ts>/, <out>/benchbase/<db>/<ts>/, <out>/micro/<ts>_fio_*/,
<out>/raw_fio/, <out>/checks/) and writes nothing outside <out>.

  metrics <out>                                  -> <out>/metrics.json
  guard <out> <ref out | -> <strict | device>    FP0 against the reference run; exit 0 go on, 3 stop
  report <out> [--prev <out>] [--baselines <csv>] -> <out>/REPORT.md; prints the verdict line

Verdict: FAIL on a kernel fault line (BUG:, WARNING:, Oops, general protection,
soft lockup, or a Call Trace that is not part of a hung-task report), a failed
step, τ inactive in a τ run, a SMART critical warning or new media errors, or an
unfinished run; STOPPED when the guard stopped the run; else PASS. Performance
against the previous version's fast run only warns: DB throughput ±3%, micro
IOPS ±5%, p99 ±10% (both directions).
"""
import csv
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PARSE_MAIN = ROOT / "bench/scripts/sysbench/parse_main.py"
TH_DB, TH_MICRO, TH_P99 = 0.03, 0.05, 0.10
GUARD_DB, GUARD_RAW = 0.03, 0.05
TPCC_LABEL = re.compile(r"(mysql|postgres)_tpcc_(.+?)_fpw_(on|off)_w(\d+)_c(\d+)_r(\d+)$")
TAU_FDS = re.compile(r"tau-flagged fds under \S+: (\d+) of (\d+); mount options: (\S*)")
FAULT = re.compile(r"BUG:|WARNING:|Oops|general protection|soft lockup")
HUNG = re.compile(r"blocked for more than \d+ seconds|hung_task")
CALL_TRACE = re.compile(r"Call Trace")


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def tau_fds_line(path):
    """(tau, total, tjournal) from the first log_tau_fds line of a .spec/.tau file."""
    try:
        for line in path.read_text(errors="replace").splitlines():
            m = TAU_FDS.search(line)
            if m:
                return int(m.group(1)), int(m.group(2)), "tjournal" in m.group(3).split(",")
    except OSError:
        pass
    return None


def sysbench_metrics(out):
    res = {}
    for d in sorted((out / "sysbench").glob("*/*/")):
        if not (d / "summary.csv").exists():
            p = subprocess.run([sys.executable, str(PARSE_MAIN), str(d)], capture_output=True, text=True)
            (d / "summary.txt").write_text(p.stdout + p.stderr)
        if not (d / "summary.csv").exists():
            continue
        for r in csv.DictReader(open(d / "summary.csv")):
            if r.get("threads") != "64" or r.get("fpw") != "off":
                continue
            key = f"{r['db']}/{r['fs']}"
            m = dict(tps=num(r["tps"]), avg_ms=num(r["avg_ms"]), p99_ms=num(r["p99_ms"]),
                     kb_per_trx=num(r["dev_write_kb_per_trx"]), flushes=num(r["dev_flushes"]),
                     dir=str(d.relative_to(out)))
            specs = sorted(d.glob(f"{r['db']}_*_{r['fs']}_fpw_off_t*.spec"))
            fds = tau_fds_line(specs[0]) if specs else None
            if fds:
                m.update(tau_fds=f"{fds[0]}/{fds[1]}", tjournal=fds[2])
            res[key] = m
    return res


def tpcc_summary(d):
    """{label: {row name: value}} from run_tpcc.sh's summary.md (pilot_report.py)."""
    cols, rows = None, {}
    for line in (d / "summary.md").read_text(errors="replace").splitlines():
        if not line.startswith("|"):
            continue
        c = [x.strip() for x in line.strip().strip("|").split("|")]
        if c[0] == "" and cols is None:
            cols = c[1:]
        elif cols and not set(c[0]) <= set("-"):
            rows[c[0]] = c[1:]
    out = {}
    for i, label in enumerate(cols or []):
        out[label] = {k: (v[i] if i < len(v) else "") for k, v in rows.items()}
    return out


def io_flushes(path):
    """Device flushes in a run's measured window, from its .io file (diskstats field 'flush requests')."""
    b = e = None
    try:
        for line in path.read_text().splitlines():
            f = line.split()
            if len(f) > 4 and f[1:4] and f[3].startswith("nvme"):
                if f[0] == "begin":
                    b = f
                elif f[0] == "end":
                    e = f
    except OSError:
        return None
    if b and e and len(b) > 19 and len(e) > 19:
        return float(int(e[19]) - int(b[19]))
    return None


def tpcc_metrics(out):
    res = {}
    for d in sorted((out / "benchbase").glob("*/*/")):
        if not (d / "summary.md").exists():
            continue
        for label, v in tpcc_summary(d).items():
            m = TPCC_LABEL.match(label)
            if not m or m.group(3) != "off" or m.group(5) != "64":
                continue
            db, fs, wh = m.group(1), m.group(2), m.group(4)
            lat = v.get("latency avg / p95 / p99 (ms)", "").split("/")
            r = dict(tpmc_bb=num(v.get("tpmC, BenchBase (completed NewOrder, measured)")),
                     tpmc_db=num(v.get("tpmC, database (new orders over the whole run)")),
                     p99_ms=num(lat[2]) if len(lat) == 3 else None,
                     kb_per_no=num(v.get("device writes per new order (KB)")),
                     flushes=io_flushes(d / f"{label}.io"), dir=str(d.relative_to(out)))
            fds = tau_fds_line(d / f"{db}_tpcc_{fs}_fpw_off_w{wh}.tau")
            if fds:
                r.update(tau_fds=f"{fds[0]}/{fds[1]}", tjournal=fds[2])
            res[f"{db}/{fs}"] = r
    return res


def micro_metrics(out):
    res, active = {}, {}
    for d in sorted((out / "micro").glob("*_fio_*/")):
        fs_txt = d / "fs.txt"
        if fs_txt.exists():
            cfg = None
            for line in fs_txt.read_text(errors="replace").splitlines():
                if line.startswith("== "):
                    cfg = line.split()[1]
                elif cfg and line.startswith("O_DIRECT|O_TAU_UNTORN"):
                    active.setdefault(cfg, []).append("tau active" in line)
        if not (d / "results.csv").exists():
            continue
        for r in csv.DictReader(open(d / "results.csv")):
            if r.get("rep") != "1":
                continue
            key = f"{r['exp']}/{r['config']}/{r['op']}/t{r['threads']}"
            res[key] = dict(iops=num(r["write_iops"]), sync_p99_us=num(r["sync_p99_us"]),
                            dev_bytes_per_16k=num(r["dev_bytes_per_16k"]), tau_fds=r.get("tau_fds", ""),
                            dir=str(d.relative_to(out)))
    return res, {k: all(v) for k, v in active.items()}


def raw_metrics(out):
    res = {}
    for name in ("randwrite", "write_qd1"):
        p = out / "raw_fio" / f"{name}.json"
        try:
            text = p.read_text()
            j = json.loads(text[text.index("{"):])
            w = j["jobs"][0]["write"]
            pct = w.get("clat_ns", {}).get("percentile", {})
            res[name] = dict(iops=w["iops"], p99_us=pct.get("99.000000", 0) / 1000,
                             mean_us=w.get("clat_ns", {}).get("mean", 0) / 1000)
        except (OSError, ValueError, KeyError, IndexError):
            pass
    return res


def read_env(path):
    d = {}
    try:
        for line in path.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
    except OSError:
        pass
    return d


def kernel_faults(out):
    """(fault lines, hung-task reports) in the boot's kernel log saved by FP4."""
    p = out / "checks" / "kernel_log.txt"
    if not p.exists():
        return None, None
    faults, hung, in_hung = [], 0, 0
    for line in p.read_text(errors="replace").splitlines():
        if HUNG.search(line):
            hung += 1
            in_hung = 60          # the report's Call Trace follows within its next lines
            continue
        if CALL_TRACE.search(line) and in_hung:
            in_hung -= 1
            continue
        in_hung = max(0, in_hung - 1)
        if FAULT.search(line) or CALL_TRACE.search(line):
            faults.append(line)
    return faults, hung


def collect(out):
    out = Path(out)
    micro, active = micro_metrics(out)
    kcheck = {k: v for k, v in sysbench_metrics(out).items() if "kcheck" in k}
    sb = {k: v for k, v in sysbench_metrics(out).items() if "kcheck" not in k}
    steps = []
    p = out / "checks" / "steps.tsv"
    if p.exists():
        for line in p.read_text().splitlines():
            f = line.split("\t")
            if len(f) >= 4:
                steps.append(dict(step=f[0], rc=int(f[1]), t0=int(f[2]), t1=int(f[3])))
    faults, hung = kernel_faults(out)
    return dict(
        version=read_env(out / "checks" / "run.env").get("VERSION", ""),
        run=read_env(out / "checks" / "run.env"),
        status=(out / "STATUS").read_text().strip() if (out / "STATUS").exists() else "",
        fp0=dict(raw=raw_metrics(out), kcheck=next(iter(kcheck.values()), None)),
        sysbench=sb, tpcc=tpcc_metrics(out), micro=micro, micro_tau_active=active,
        steps=steps, fp4=read_env(out / "checks" / "fp4.env"),
        kernel_faults=faults, hung_tasks=hung)


def cmd_metrics(out):
    m = collect(out)
    Path(out, "metrics.json").write_text(json.dumps(m, indent=1, sort_keys=True))
    return m


def load(out):
    p = Path(out) / "metrics.json"
    return json.loads(p.read_text()) if p.exists() else None


def delta(cur, ref):
    if cur is None or not ref:
        return None
    return (cur - ref) / ref


def pct(x):
    return "" if x is None else f"{x * 100:+.1f}%"


def cmd_guard(out, ref_out, mode):
    cur = cmd_metrics(out)
    k = (cur["fp0"].get("kcheck") or {}).get("tps")
    w = (cur["fp0"]["raw"].get("randwrite") or {}).get("iops")
    print(f"guard: KCHECK PG EXT4 Raw 64 {k} TPS, raw 16 KiB randwrite QD32x4 {w} IOPS")
    ref = load(ref_out) if ref_out != "-" else None
    if not ref or not (ref["fp0"].get("kcheck") or {}).get("tps"):
        print("guard: no reference run yet: this run records the reference (no stop)")
        return 0 if k else 3
    rk = ref["fp0"]["kcheck"]["tps"]
    rw = (ref["fp0"]["raw"].get("randwrite") or {}).get("iops")
    dk, dw = delta(k, rk), delta(w, rw)
    k_ok = dk is not None and abs(dk) <= GUARD_DB
    w_ok = dw is not None and abs(dw) <= GUARD_RAW
    print(f"guard: reference {ref_out}: KCHECK {rk} TPS ({pct(dk)}, limit ±3%), raw {rw} IOPS ({pct(dw)}, limit ±5%)")
    go = k_ok if mode == "strict" else w_ok
    if not k_ok and w_ok:
        print("guard: the device holds (raw within ±5%) but the stock EXT4 path moved on this kernel")
    elif k_ok and not w_ok:
        print("guard: KCHECK holds but the raw device moved")
    print(f"guard ({mode}): {'go on' if go else 'STOP: the beta baselines may no longer apply'}")
    return 0 if go else 3


def tau_ok(m):
    if "tau_fds" not in m:
        return False
    t, n = (int(x) for x in m["tau_fds"].split("/"))
    return t > 0 and m.get("tjournal", False)


def micro_tau_ok(key, m):
    if not key.split("/")[1].startswith("tau-"):
        return True
    t = m.get("tau_fds", "")
    return bool(re.fullmatch(r"(\d+)/\1", t)) and int(t.split("/")[0]) > 0


def baselines(path):
    b = {}
    if path and Path(path).exists():
        for r in csv.DictReader(open(path)):
            b[(r["bench"], r["db"], r["fs"], r["protection"], r["metric"])] = (float(r["value"]), r["source"])
    return b


def cmd_report(out, prev_out=None, base_csv=None):
    out = Path(out)
    cur = cmd_metrics(out)
    prev = load(prev_out) if prev_out else None
    base = baselines(base_csv)
    fails, warns = [], []
    status = cur["status"]
    if not status.startswith(("done", "stopped")):
        fails.append(f"the run did not finish (STATUS '{status or 'none'}'): a reboot or a kill; see fast.log and the journal")
    for s in cur["steps"]:
        if s["rc"] != 0:
            fails.append(f"step {s['step']} failed (rc {s['rc']})")
    if cur["kernel_faults"] is None:
        fails.append("no kernel log (FP4 did not run)")
    elif cur["kernel_faults"]:
        fails.append(f"{len(cur['kernel_faults'])} kernel fault lines (checks/kernel_log.txt)")
    if cur["hung_tasks"]:
        warns.append(f"{cur['hung_tasks']} hung-task reports in the kernel log")
    for k, m in list(cur["sysbench"].items()) + list(cur["tpcc"].items()):
        if "-tau" in k and not tau_ok(m):
            fails.append(f"τ not active in {k} ({m.get('tau_fds', 'no τ fd line')}, tjournal {m.get('tjournal')})")
    for k, m in cur["micro"].items():
        if not micro_tau_ok(k, m):
            fails.append(f"τ not active in micro {k} (tau_fds {m.get('tau_fds') or 'n/a'})")
    for cfg, ok in cur["micro_tau_active"].items():
        if cfg.startswith("tau-") and not ok:
            fails.append(f"micro {cfg}: O_TAU_UNTORN was not rejected with O_DIRECT (τ not active)")
    f4 = cur["fp4"]
    if f4:
        if f4.get("smart_critical_warning_after", "0") not in ("0", "0x0", "0x00"):
            fails.append(f"SMART critical_warning {f4['smart_critical_warning_after']} after the run")
        if num(f4.get("smart_media_errors_after")) and num(f4.get("smart_media_errors_after")) > (num(f4.get("smart_media_errors_before")) or 0):
            fails.append("SMART media errors grew during the run")
        if num(f4.get("smart_err_log_after")) and num(f4.get("smart_err_log_after")) > (num(f4.get("smart_err_log_before")) or 0):
            warns.append("SMART error-log entries grew during the run")
        if f4.get("hugepages_all_free_after") != "yes":
            warns.append(f"1 GiB huge pages not all free after the run ({f4.get('hugepages_after', '?')})")
        if f4.get("linger_after") != "yes":
            warns.append("linger is off after the run")
        if f4.get("timers_ran"):
            warns.append(f"timer services ran during the run: {f4['timers_ran']}")
        if f4.get("summary_md_restored") == "failed":
            warns.append("bench/results/<host>/SUMMARY.md could not be put back after a TPC-C run (copy in checks/)")

    def cmp_rows(fam, curd, prevd, fields):
        rows = []
        for k in sorted(curd):
            c, p = curd[k], (prevd or {}).get(k) or {}
            cells = []
            for f, th, label in fields:
                d = delta(c.get(f), p.get(f))
                cells.append((c.get(f), p.get(f), d))
                if d is not None and abs(d) > th:
                    warns.append(f"{fam} {k} {label} {pct(d)} against the previous fast run (limit ±{th * 100:.0f}%)")
            rows.append((k, c, cells))
        return rows

    pv = prev or {}
    pf0 = pv.get("fp0") or {}
    for label, c, p, th in (
            ("KCHECK TPS", (cur["fp0"].get("kcheck") or {}).get("tps"), (pf0.get("kcheck") or {}).get("tps"), TH_DB),
            ("raw randwrite IOPS", (cur["fp0"]["raw"].get("randwrite") or {}).get("iops"),
             ((pf0.get("raw") or {}).get("randwrite") or {}).get("iops"), TH_MICRO)):
        d = delta(c, p)
        if d is not None and abs(d) > th:
            warns.append(f"FP0 {label} {pct(d)} against the previous fast run (limit ±{th * 100:.0f}%)")
    sb_rows = cmp_rows("sysbench", cur["sysbench"], pv.get("sysbench"),
                       [("tps", TH_DB, "TPS"), ("p99_ms", TH_P99, "p99")])
    tp_rows = cmp_rows("TPC-C", cur["tpcc"], pv.get("tpcc"),
                       [("tpmc_db", TH_DB, "tpmC"), ("p99_ms", TH_P99, "p99")])
    mi_rows = cmp_rows("micro", cur["micro"], pv.get("micro"),
                       [("iops", TH_MICRO, "IOPS"), ("sync_p99_us", TH_P99, "commit p99")])

    if status.startswith("stopped"):
        verdict = "STOPPED" if not fails else "FAIL"
    else:
        verdict = "FAIL" if fails else "PASS"
    vline = f"{verdict}" + (f" ({len(warns)} warnings)" if warns and verdict != "FAIL" else "")

    def v(x, nd=1):
        return "" if x is None else (f"{x:,.{nd}f}" if isinstance(x, (int, float)) else str(x))

    def ratio(bench, k, val, metric):
        db, fs = k.split("/")
        fs0 = fs.replace("-tau", "")
        a = base.get((bench, db, fs0, "App", metric))
        r = base.get((bench, db, fs0, "Raw", metric))
        return (f"{val / a[0]:.2f}" if a and val else "", f"{val / r[0]:.2f}" if r and val else "")

    run = cur["run"]
    L = [f"# Fast test (libra09 performance): {run.get('VERSION', '?')}", "",
         f"**Verdict: {vline}**", "",
         f"- kernel: {run.get('UNAME_R', '')} {run.get('UNAME_V', '')}; commit {run.get('KERNEL_COMMIT', '')}; "
         f"bzImage md5 {run.get('BZIMAGE_MD5', '')}",
         f"- run: {out.name} (UTC), status `{status}`, steps {run.get('STEPS', '')}, guard {run.get('GUARD', '')}",
         f"- previous fast run: {prev_out or 'none (first run: values are recorded, not compared)'}",
         f"- baselines (τ÷App, τ÷Raw): {base_csv or 'none'}; the fast protocol (10-min warm-up + 5 min, one run) is "
         "shorter than the baselines' (paper protocol), so the ratios are indicative", ""]
    if fails:
        L += ["## Failures", ""] + [f"- {x}" for x in fails] + [""]
    if warns:
        L += ["## Warnings", ""] + [f"- {x}" for x in warns] + [""]
    fp0 = cur["fp0"]
    L += ["## FP0 guard", "", "| check | value | reference | Δ |", "|---|---:|---:|---:|"]
    pf = (pv.get("fp0") or {}) if pv else {}
    rk = (pf.get("kcheck") or {}).get("tps")
    k = (fp0.get("kcheck") or {}).get("tps")
    L.append(f"| KCHECK PG EXT4 Raw sysbench 64 (TPS) | {v(k)} | {v(rk)} | {pct(delta(k, rk))} |")
    for n in ("randwrite", "write_qd1"):
        c = (fp0["raw"].get(n) or {})
        p = ((pf.get("raw") or {}).get(n) or {})
        L.append(f"| raw {n} (IOPS / p99 µs) | {v(c.get('iops'), 0)} / {v(c.get('p99_us'), 0)} | "
                 f"{v(p.get('iops'), 0)} / {v(p.get('p99_us'), 0)} | {pct(delta(c.get('iops'), p.get('iops')))} |")
    L += ["", "(The guard itself compares with REF_VERSION's run; see fast.log's guard lines.)", ""]
    L += ["## FP2 sysbench oltp_write_only 64 (PM1735)", "",
          "| config | TPS | p99 ms | KB/trx | flushes | τ fds | prev TPS (Δ) | prev p99 (Δ) | τ÷App | τ÷Raw |",
          "|---|---:|---:|---:|---:|---|---:|---:|---:|---:|"]
    for k2, c, cells in sb_rows:
        a, r = ratio("sysbench", k2, c.get("tps"), "tps")
        L.append(f"| {k2} | {v(c.get('tps'))} | {v(c.get('p99_ms'), 2)} | {v(c.get('kb_per_trx'), 2)} | "
                 f"{v(c.get('flushes'), 0)} | {c.get('tau_fds', '')} | {v(cells[0][1])} ({pct(cells[0][2])}) | "
                 f"{v(cells[1][1], 2)} ({pct(cells[1][2])}) | {a} | {r} |")
    L += ["", "## FP3 TPC-C 1,100 WH, 64 terminals (PM1735)", "",
          "tpmC: database basis (as the baselines' tables.md); BenchBase basis in brackets.", "",
          "| config | tpmC DB (BenchBase) | p99 ms | KB per new order | τ fds | prev tpmC (Δ) | prev p99 (Δ) | τ÷App | τ÷Raw |",
          "|---|---:|---:|---:|---|---:|---:|---:|---:|"]
    for k2, c, cells in tp_rows:
        a, r = ratio("tpcc", k2, c.get("tpmc_db"), "tpmc_db")
        L.append(f"| {k2} | {v(c.get('tpmc_db'), 0)} ({v(c.get('tpmc_bb'), 0)}) | {v(c.get('p99_ms'), 2)} | "
                 f"{v(c.get('kb_per_no'), 1)} | {c.get('tau_fds', '')} | {v(cells[0][1], 0)} ({pct(cells[0][2])}) | "
                 f"{v(cells[1][1], 2)} ({pct(cells[1][2])}) | {a} | {r} |")
    L += ["", "## FP1 micro (atomicw, 16 KiB, 60 s)", "",
          "| exp/config/op/threads | IOPS | commit p99 µs | device bytes per 16 KiB | τ fds | prev IOPS (Δ) | prev p99 (Δ) |",
          "|---|---:|---:|---:|---|---:|---:|"]
    for k2, c, cells in mi_rows:
        L.append(f"| {k2} | {v(c.get('iops'), 0)} | {v(c.get('sync_p99_us'), 0)} | {v(c.get('dev_bytes_per_16k'), 1)} | "
                 f"{c.get('tau_fds', '')} | {v(cells[0][1], 0)} ({pct(cells[0][2])}) | {v(cells[1][1], 0)} ({pct(cells[1][2])}) |")
    L += ["", "## FP4 hygiene", ""]
    L.append(f"- kernel log since boot: {len(cur['kernel_faults'] or [])} fault lines, {cur['hung_tasks'] or 0} hung-task reports")
    for key in ("smart_before", "smart_after", "discards_before", "discards_after", "hugepages_before", "hugepages_after",
                "linger_before", "linger_after", "timers_window", "timers_ran", "summary_md_restored"):
        if key in f4:
            L.append(f"- {key}: {f4[key]}")
    L.append("")
    L.append("Steps (UTC): " + ", ".join(f"{s['step']} rc {s['rc']} {(s['t1'] - s['t0']) // 60} min" for s in cur["steps"]))
    if base:
        L += ["", "Baselines used:", ""]
        for (bench, db, fs, prot, metric), (val, src) in sorted(base.items()):
            L.append(f"- {bench} {db} {fs} {prot} {metric} {val:,.1f}: {src}")
    (out / "REPORT.md").write_text("\n".join(L) + "\n")
    print(f"verdict: {vline}")
    for x in fails:
        print(f"  FAIL: {x}")
    for x in warns:
        print(f"  warn: {x}")
    return 0 if verdict == "PASS" else (3 if verdict == "STOPPED" else 1)


def main(argv):
    if len(argv) >= 2 and argv[0] == "metrics":
        cmd_metrics(argv[1])
        return 0
    if len(argv) == 4 and argv[0] == "guard":
        return cmd_guard(argv[1], argv[2], argv[3])
    if len(argv) >= 2 and argv[0] == "report":
        prev = base = None
        rest = argv[2:]
        while rest:
            if rest[0] == "--prev" and len(rest) > 1:
                prev, rest = rest[1], rest[2:]
            elif rest[0] == "--baselines" and len(rest) > 1:
                base, rest = rest[1], rest[2:]
            else:
                break
        return cmd_report(argv[1], prev, base)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
