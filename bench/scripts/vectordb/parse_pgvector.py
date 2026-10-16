#!/usr/bin/env python3
"""Summarize a run_pgvector.sh result directory.

Writes one CSV row per block (<label>.io, .progress, .sizes and VectorDBBench's
result JSON) and prints, per case and file system, the load with FPW on (App)
and off (Raw): insert time, rows/s, WAL and device writes per row.

Usage: parse_pgvector.py <result_dir> [out.csv]   (default: <result_dir>/summary.csv)
       parse_pgvector.py --timeline <label>.progress [seconds per line, default 60]
       parse_pgvector.py --compare <on>.progress <off>.progress [rows per line, default 100000]
       parse_pgvector.py --waits <result dir>/<label> [rows per line, default 1000000]
       parse_pgvector.py --stream <result dir>    (StreamingPerformanceCase runs)
"""
import csv
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "sysbench"))
from parse_main import parse_io  # noqa: E402

LABEL = re.compile(r"^pgvector_(?P<case>\w+?)_(?P<fs>[a-z0-9.-]+)_fpw_(?P<fpw>on|off)"
                   r"(?:_c(?P<conn>\d+))?_r(?P<run>\d+)$")
SECTOR = 512
MB = 1 << 20


def insert_durations(result_dir):
    """task_label -> (insert_duration s, rows) from VectorDBBench's result files."""
    out = {}
    for path in result_dir.glob("vdb_results/**/*.json"):
        data = json.loads(path.read_text())
        label = data.get("task_label")
        for res in data.get("results", []):
            m = res.get("metrics", {})
            if m.get("insert_duration"):
                out[label] = m["insert_duration"]
    return out


def progress(path):
    """Checkpoints during the load and the last row count, from <label>.progress."""
    rows = [line.split() for line in path.read_text().splitlines()[1:] if len(line.split()) in (6, 8)]
    if not rows:
        return {}
    first, last = rows[0], rows[-1]
    return {"rows": int(last[1]),
            "ckpt_timed": int(last[4]) - int(first[4]),
            "ckpt_requested": int(last[5]) - int(first[5])}


def sizes(path):
    out = {}
    for line in path.read_text().splitlines():
        tok = [t.strip() for t in line.split("|")]
        if len(tok) == 4 and tok[2].isdigit():
            out[tok[0]] = int(tok[2])
    return out


def load_samples(path):
    """(seconds of day, rows, wal_bytes, wal_fpi, ckpt_timed, ckpt_requested
    [, client_ticks, busy_ticks]) per sample."""
    samples = []
    for line in path.read_text().splitlines()[1:]:
        tok = line.split()
        if len(tok) not in (6, 8):
            continue
        h, m, s = (int(x) for x in tok[0].split(":"))
        samples.append((h * 3600 + m * 60 + s, *(int(x) for x in tok[1:])))
    return samples


def at_rows(samples, n):
    """Elapsed seconds and WAL bytes when the load reached n rows (interpolated)."""
    t0 = samples[0][0]
    for a, b in zip(samples, samples[1:]):
        if a[1] <= n <= b[1] and b[1] > a[1]:
            f = (n - a[1]) / (b[1] - a[1])
            ta, tb = (a[0] - t0) % 86400, (b[0] - t0) % 86400
            return ta + f * (tb - ta), a[2] + f * (b[2] - a[2])
    return None


def compare(on_path, off_path, bucket):
    """Insert rate and WAL per row of two loads over the same row ranges, i.e.
    at the same index size, which a time series of each load cannot show."""
    on, off = load_samples(on_path), load_samples(off_path)
    last = min(on[-1][1], off[-1][1])
    print(f"{'rows':>17} {'on rows/s':>9} {'off rows/s':>10} {'off/on':>6} {'on WAL_KB/row':>13} {'off WAL_KB/row':>14}")
    lo = 0
    while lo < last:
        hi = min(lo + bucket, last)
        a_on, b_on, a_off, b_off = at_rows(on, lo), at_rows(on, hi), at_rows(off, lo), at_rows(off, hi)
        if None in (a_on, b_on, a_off, b_off):
            lo = hi
            continue
        r_on = (hi - lo) / (b_on[0] - a_on[0])
        r_off = (hi - lo) / (b_off[0] - a_off[0])
        print(f"{lo:>8}-{hi:<8} {r_on:>9.0f} {r_off:>10.0f} {r_off / r_on:>6.2f} "
              f"{(b_on[1] - a_on[1]) / 1024 / (hi - lo):>13.1f} {(b_off[1] - a_off[1]) / 1024 / (hi - lo):>14.1f}")
        lo = hi


def waits(prefix, bucket, top=7):
    """Average number of loading backends in each wait event (from <prefix>.waits,
    one sample a second) over the same row ranges as --compare."""
    prog = load_samples(Path(prefix + ".progress"))
    t0 = prog[0][0]
    samples = []
    for line in Path(prefix + ".waits").read_text().splitlines():
        tok = line.split()
        if not tok or ":" not in tok[0]:
            continue
        h, m, x = (int(v) for v in tok[0].split(":"))
        counts = {}
        for kv in tok[1:]:
            k, _, v = kv.rpartition("=")
            counts[k] = int(v)
        samples.append(((h * 3600 + m * 60 + x - t0) % 86400, counts))
    if not samples:
        return
    total = defaultdict(int)
    for _, c in samples:
        for k, v in c.items():
            total[k] += v
    cols = sorted(total, key=total.get, reverse=True)[:top]
    print(f"{'rows':>17} " + " ".join(f"{c:>18}" for c in cols) + f" {'other':>6}")
    last = prog[-1][1]
    lo = 0
    while lo < last:
        hi = min(lo + bucket, last)
        a, b = at_rows(prog, lo), at_rows(prog, hi)
        lo_n, lo = lo, hi
        if a is None or b is None:
            continue
        seg = [c for t, c in samples if a[0] <= t < b[0]]
        if not seg:
            continue
        mean = {k: sum(c.get(k, 0) for c in seg) / len(seg) for k in total}
        other = sum(v for k, v in mean.items() if k not in cols)
        print(f"{lo_n:>8}-{hi:<8} " + " ".join(f"{mean[c]:>18.1f}" for c in cols) + f" {other:>6.1f}")


def stream(result_dir):
    """Search while inserting (StreamingPerformanceCase): per search stage, the
    single-client latency over all test queries and the concurrent QPS and
    latency, FPW on next to off for each run."""
    metrics = {}
    for path in Path(result_dir).glob("vdb_results/**/*.json"):
        data = json.loads(path.read_text())
        for res in data.get("results", []):
            if res.get("metrics", {}).get("st_search_stage_list"):
                metrics[data.get("task_label")] = res["metrics"]
    runs = defaultdict(dict)
    for label, m in metrics.items():
        lm = LABEL.match(label)
        if lm:
            runs[(lm["case"], lm["fs"], lm["run"])][lm["fpw"]] = m

    def ms(v):
        return "-" if v in (None, 0) else f"{v * 1000:.1f}"

    for (case, fs, run), by in sorted(runs.items()):
        print(f"== {case} {fs} run {run} (latency in ms; stage 100 = after the last insert, 110 = after optimize)")
        print(f"{'stage':>5} {'fpw':>4} {'recall':>6} {'1-client p95':>12} {'p99':>7} "
              f"{'conc QPS':>9} {'conc avg':>8} {'conc p95':>8} {'conc p99':>8}")
        stages = next(iter(by.values()))["st_search_stage_list"]
        for i, stage in enumerate(stages):
            for fpw in ("on", "off"):
                m = by.get(fpw)
                if not m or i >= len(m["st_search_stage_list"]):
                    continue
                qps = (m.get("st_conc_qps_list_list") or [[]])[i]
                avg = (m.get("st_conc_latency_avg_list_list") or [[]])[i]
                p95 = (m.get("st_conc_latency_p95_list_list") or [[]])[i]
                p99 = (m.get("st_conc_latency_p99_list_list") or [[]])[i]
                print(f"{stage:>5} {fpw:>4} {m['st_recall_list'][i]:>6.3f} "
                      f"{ms(m['st_serial_latency_p95_list'][i]):>12} {ms(m['st_serial_latency_p99_list'][i]):>7} "
                      f"{(f'{qps[0]:.0f}' if qps else '-'):>9} {(ms(avg[0]) if avg else '-'):>8} "
                      f"{(ms(p95[0]) if p95 else '-'):>8} {(ms(p99[0]) if p99 else '-'):>8}")


def timeline(path, step):
    """Insert rate, WAL rate and full-page images per <step> seconds of a load,
    with the checkpoints that started in each interval."""
    samples = load_samples(path)
    if not samples:
        return
    t0 = samples[0][0]
    cpu = len(samples[0]) == 8   # client and machine CPU ticks (USER_HZ = 100)
    print(f"{'t_s':>6} {'rows':>8} {'rows/s':>7} {'WAL_MB/s':>8} {'FPI/s':>7} {'FPI/row':>7} {'ckpt':>4}"
          + (f" {'client%':>7} {'machine%':>8}" if cpu else ""))
    prev = samples[0]
    for cur in samples[1:]:
        dt = (cur[0] - prev[0]) % 86400
        if dt < step and cur is not samples[-1]:
            continue
        rows = cur[1] - prev[1]
        fpi = cur[3] - prev[3]
        ckpt = (cur[4] + cur[5]) - (prev[4] + prev[5])
        line = (f"{(cur[0] - t0) % 86400:>6} {cur[1]:>8} {rows / dt:>7.0f} {(cur[2] - prev[2]) / dt / MB:>8.1f} "
                f"{fpi / dt:>7.0f} {fpi / rows if rows else 0:>7.2f} {'+' * ckpt:>4}")
        if cpu:
            # client: % of one core; machine: % of all cores
            line += (f" {(cur[6] - prev[6]) / dt:>7.0f}"
                     f" {(cur[7] - prev[7]) / dt / (os.cpu_count() or 1):>8.0f}")
        print(line)
        prev = cur


def main():
    if sys.argv[1] == "--timeline":
        timeline(Path(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 60)
        return
    if sys.argv[1] == "--stream":
        stream(sys.argv[2])
        return
    if sys.argv[1] == "--waits":
        waits(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 1000000)
        return
    if sys.argv[1] == "--compare":
        compare(Path(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4]) if len(sys.argv) > 4 else 100000)
        return
    result_dir = Path(sys.argv[1])
    out_csv = Path(sys.argv[2]) if len(sys.argv) > 2 else result_dir / "summary.csv"
    durations = insert_durations(result_dir)
    rows = []
    for io in sorted(result_dir.glob("pgvector_*.io")):
        label = io.stem
        m = LABEL.match(label)
        if not m:
            continue
        row = dict(m.groupdict(), label=label)
        d = parse_io(io)
        el = re.search(r"elapsed_s=([\d.]+) rc=(\d+)", io.read_text())
        row["elapsed_s"] = float(el.group(1)) if el else None
        row["rc"] = int(el.group(2)) if el else None
        row["insert_s"] = durations.get(label)
        nrows = re.search(r"^rows=(\d+)$", io.read_text(), re.M)
        prog = progress(io.with_suffix(".progress")) if io.with_suffix(".progress").exists() else {}
        row.update(prog)
        sz = sizes(io.with_suffix(".sizes")) if io.with_suffix(".sizes").exists() else {}
        row["table_mb"] = round(sz.get("vdbbench_table_test", 0) / MB)
        row["index_mb"] = round(sz.get("pgvector_index", 0) / MB)
        if nrows:
            row["rows"] = int(nrows.group(1))
        n = row.get("rows") or 0
        if row["insert_s"] and n:
            row["rows_per_s"] = round(n / row["insert_s"], 1)
        if d.get("wal_bytes") is not None:
            row["wal_mb"] = round(d["wal_bytes"] / MB)
            row["wal_fpi"] = d["wal_fpi"]
            row["wal_kb_per_row"] = round(d["wal_bytes"] / 1024 / max(n, 1), 2)
            row["fpi_per_row"] = round(d["wal_fpi"] / max(n, 1), 2)
        if d.get("wr_sectors") is not None:
            row["dev_write_mb"] = round(d["wr_sectors"] * SECTOR / MB)
            row["dev_write_kb_per_row"] = round(d["wr_sectors"] * SECTOR / 1024 / max(n, 1), 2)
        if d.get("cpu_idle") is not None:
            busy = sum(d.get(k, 0) for k in ("cpu_user", "cpu_nice", "cpu_system", "cpu_irq", "cpu_softirq"))
            total = busy + d["cpu_idle"] + d.get("cpu_iowait", 0)
            row["cpu_util_pct"] = round(100 * busy / total, 1) if total else None
            row["cpu_iowait_pct"] = round(100 * d.get("cpu_iowait", 0) / total, 1) if total else None
        rows.append(row)

    fields = ["label", "case", "fs", "fpw", "conn", "run", "rc", "rows", "insert_s", "elapsed_s", "rows_per_s",
              "wal_mb", "wal_fpi", "wal_kb_per_row", "fpi_per_row", "dev_write_mb", "dev_write_kb_per_row",
              "ckpt_timed", "ckpt_requested", "table_mb", "index_mb", "cpu_util_pct", "cpu_iowait_pct"]
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    groups = defaultdict(lambda: defaultdict(list))
    for r in rows:
        groups[(r["case"], r["fs"], r["conn"] or "1")][r["fpw"]].append(r)

    def mean(rs, k):
        vals = [r[k] for r in rs if r.get(k) is not None]
        return sum(vals) / len(vals) if vals else None

    def fmt(v, spec):
        return "-" if v is None else format(v, spec)

    print(f"{'case':<20} {'fs':<8} {'conn':>4} {'fpw':<4} {'n':>2} {'insert_s':>9} {'rows/s':>8} {'Raw/App':>8} "
          f"{'WAL_MB':>8} {'FPI/row':>8} {'WAL_KB/row':>10} {'dev_KB/row':>10} {'ckpts':>6} {'cpu%':>5}")
    for (case, fs, conn), by in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], int(kv[0][2]))):
        app = mean(by.get("on", []), "rows_per_s")
        for fpw in ("on", "off"):
            rs = by.get(fpw, [])
            if not rs:
                continue
            rps = mean(rs, "rows_per_s")
            ratio = rps / app if (rps and app and fpw == "off") else None
            ck = mean(rs, "ckpt_timed")
            ckr = mean(rs, "ckpt_requested")
            ckpts = None if ck is None else ck + (ckr or 0)
            print(f"{case:<20} {fs:<8} {conn:>4} {fpw:<4} {len(rs):>2} {fmt(mean(rs, 'insert_s'), '9.0f')} "
                  f"{fmt(rps, '8.0f')} {fmt(ratio, '8.2f')} {fmt(mean(rs, 'wal_mb'), '8.0f')} "
                  f"{fmt(mean(rs, 'fpi_per_row'), '8.2f')} {fmt(mean(rs, 'wal_kb_per_row'), '10.2f')} "
                  f"{fmt(mean(rs, 'dev_write_kb_per_row'), '10.2f')} {fmt(ckpts, '6.1f')} "
                  f"{fmt(mean(rs, 'cpu_util_pct'), '5.1f')}")
    print(f"\n{len(rows)} blocks -> {out_csv}")


if __name__ == "__main__":
    main()
