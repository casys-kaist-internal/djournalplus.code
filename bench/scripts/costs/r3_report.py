#!/usr/bin/env python3
"""EVAL_PLAN R3: results.jsonl of run_r3.sh / run_r3_drop.sh -> results.csv (one
row a run) and summary.md (per configuration, operation, residency and after
mode: the median and range over the repetitions).

usage: r3_report.py <result dir>

A run is void (left out of the summary, listed under it) if
  - reclaim scanned the shrinkers between the overwrite and the call (a res1g
    file may then have been checkpointed: tau takes the oldest tx whole),
  - truncate/unlink: the device was not quiet before the call (a DROP's
    database may keep writing; its "quiet" is in results.csv),
  - the trace does not account for the device's own write counter (trace_ok),
  - res1g, tau: the residency is short of the file (FILE_MB) by more than one
    segment.
"""
import csv
import json
import os
import statistics
import sys

TAU_KEYS = ("free_cond", "free_skip", "free_mark", "free_hold", "free_old", "free_home",
            "jwrite_revoke", "jwrite_record", "jwrite_blocks", "jwrite_desc", "commits",
            "dead_unpinned", "dead_released", "dead_held", "dead_freed", "dead_forced",
            "flush_submit", "cp_runs", "cpq_policy", "cpq_pressure", "cpq_memory", "shrink_scan")
GROUP = ("dbms", "config", "op", "state", "after", "phase")
COLS = ("lat_ms", "sync_other_bytes", "sync_home_bytes", "sync_reqs", "sync_flush", "sync_fua",
        "after_other_bytes", "after_home_bytes", "after_reuse_bytes", "dev_sync_bytes", "dev_after_bytes",
        "resident_mib", "used_before", "used_after_call", "used_end", "seg_return_ms",
        "host_commit_ms", "age_at_call_s", "quiet_wait_s", "file_bytes", "home_bytes_mapped",
        "server_ms", "trace_ok", "quiet", "window_s")


def void_reason(r):
    why = []
    if r.get("reclaim"):
        why.append("reclaim " + ",".join(f"{k}+{v}" for k, v in r["reclaim"].items()))
    if not r.get("quiet", True) and r.get("op") in ("truncate", "unlink"):
        why.append("not quiet")
    if not r.get("trace_ok", True):
        why.append(f"trace {r.get('traced_bytes')} vs device {r.get('dev_sync_bytes', 0) + r.get('dev_after_bytes', 0)}")
    if (r.get("state") == "res1g" and str(r.get("config", "")).startswith("tau-")
            and r.get("resident_mib") is not None and r.get("seg_mb")
            and r["resident_mib"] + r["seg_mb"] < r.get("file_bytes", 0) / 2**20):
        why.append(f"resident {r['resident_mib']} MiB < file")
    return "; ".join(why)


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float)) and not isinstance(x, bool)]
    if not xs:
        return None
    return statistics.median(xs), min(xs), max(xs)


def fmt(m, scale=1.0, nd=1):
    if m is None:
        return "-"
    a, lo, hi = (x / scale for x in m)
    if lo == hi:
        return f"{a:.{nd}f}"
    return f"{a:.{nd}f} ({lo:.{nd}f}-{hi:.{nd}f})"


def main():
    d = sys.argv[1]
    rows = [json.loads(l) for l in open(os.path.join(d, "results.jsonl")) if l.strip()]
    for r in rows:
        r["void"] = void_reason(r)
        pc = r.get("probe_call", {}) or {}
        pa = r.get("probe_after", {}) or {}
        for k in TAU_KEYS:
            if k in pc or k in pa or r.get("probe_call") is not None:
                r[f"p_{k}"] = pc.get(k, 0)
                r[f"pa_{k}"] = pa.get(k, 0)
    keys = [k for k in GROUP if any(k in r for r in rows)]
    probe_cols = sorted({k for r in rows for k in r if k.startswith(("p_", "pa_"))})
    cols = keys + ["rep"] + [c for c in COLS if any(c in r for r in rows)] + probe_cols + ["void"]
    with open(os.path.join(d, "results.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in rows:
            w.writerow([r.get(c, "") if not isinstance(r.get(c), (dict, list)) else json.dumps(r.get(c)) for c in cols])

    groups = {}
    for r in rows:
        if not r["void"]:
            groups.setdefault(tuple(r.get(k, "") for k in keys), []).append(r)
    out = [f"# R3 summary: {os.path.basename(os.path.abspath(d))}", "",
           "Median (min-max) over the repetitions; sizes in KiB; times in ms. sync = during the",
           "call, after = from its return to the end of the window (segments back, >= AFTER_MIN s,",
           "then syncfs); home = writes to the blocks the file(s) had before the call (until the",
           "host's first commit after it; later ones are another file's reuse, in results.csv),",
           "other = the rest (journals, metadata: a truncate's revoke tags are in sync other).", ""]
    head = [*keys, "n", "lat_ms", "sync other KiB", "sync home KiB", "sync flush/fua", "after other KiB",
            "after home KiB", "resident MiB", "seg back ms", "host commit ms", "server ms"]
    out.append("| " + " | ".join(head) + " |")
    out.append("|" + "---|" * len(head))
    for g, rs in sorted(groups.items()):
        out.append("| " + " | ".join([*map(str, g), str(len(rs)),
            fmt(med([r["lat_ms"] for r in rs]), 1, 3),
            fmt(med([r.get("sync_other_bytes") for r in rs]), 1024),
            fmt(med([r.get("sync_home_bytes") for r in rs]), 1024),
            f"{fmt(med([r.get('sync_flush') for r in rs]), 1, 0)}/{fmt(med([r.get('sync_fua') for r in rs]), 1, 0)}",
            fmt(med([r.get("after_other_bytes") for r in rs]), 1024),
            fmt(med([r.get("after_home_bytes") for r in rs]), 1024),
            fmt(med([r.get("resident_mib") for r in rs]), 1, 0),
            fmt(med([r.get("seg_return_ms") for r in rs]), 1, 0),
            fmt(med([r.get("host_commit_ms") for r in rs]), 1, 0),
            fmt(med([r.get("server_ms") for r in rs]), 1, 1)]) + " |")
    if probe_cols:
        out += ["", "tau probe counters during the call (median; CONFIG_TAU_PROBE_TORN kernels only):", ""]
        pk = [k for k in TAU_KEYS if any(f"p_{k}" in r for r in rows)]
        out.append("| " + " | ".join([*keys, *pk]) + " |")
        out.append("|" + "---|" * (len(keys) + len(pk)))
        for g, rs in sorted(groups.items()):
            out.append("| " + " | ".join([*map(str, g)] + [fmt(med([r.get(f"p_{k}") for r in rs]), 1, 0) for k in pk]) + " |")
        out += ["", "...and in the after window (holds and dead files let go):", ""]
        out.append("| " + " | ".join([*keys, *pk]) + " |")
        out.append("|" + "---|" * (len(keys) + len(pk)))
        for g, rs in sorted(groups.items()):
            out.append("| " + " | ".join([*map(str, g)] + [fmt(med([r.get(f"pa_{k}") for r in rs]), 1, 0) for k in pk]) + " |")
    voids = [r for r in rows if r["void"]]
    out += ["", f"Void runs: {len(voids)}"]
    for r in voids:
        out.append(f"- {' '.join(str(r.get(k, '')) for k in keys)} r{r.get('rep')}: {r['void']}")
    with open(os.path.join(d, "summary.md"), "w") as f:
        f.write("\n".join(out) + "\n")
    print("\n".join(out))


if __name__ == "__main__":
    main()
