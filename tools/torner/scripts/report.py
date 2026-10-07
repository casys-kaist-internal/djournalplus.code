#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
torner-report -- turn the JSONL from explore.sh (and loginv) into the tables
CRASH_TODO §6 asks for.

Two things this deliberately does NOT do:

  * invent a table it has no input for.  §6 lists five tables; the T1 regression
    table and the T3 injection table come from layers that are not wired up
    here, and they are printed as "no input" rather than left to look complete.

  * report a bare percentage.  These samples are small -- a few dozen states out
    of thousands -- so every rate carries a Wilson 95% interval.  "12/40 torn"
    is 30% with an interval of roughly 18-46%, and a table that printed only
    "30%" would invite a precision the run does not have.

The exposure rate also depends on the persistence model, and the two are not
comparable:

    single-drop   any subset of a BIO may persist.  The standard model, the
                  same one CrashMonkey's permuter uses.
    torn-entry    a bio larger than the device's atomic unit (4 KiB by default)
                  may persist in part.  Strictly stronger, and necessary: a
                  file system that issues an application's 16 KiB write as one
                  bio can never be shown to tear under the first model.

So the strategy is part of the row, never averaged away.

The atom-* strategies aim each state at particular application writes, and
their records say which of those writes tore.  They get a second table whose
unit is the write, not the state -- "writes torn / writes tried" -- under three
crash models of increasing strength:

    atom-order    O  in-order prefix: the log up to a point; assumes nothing
                     about the device
    atom-reorder  R  reordered cache: also drops writes still volatile at the
                     crash (after the last FLUSH, and not FUA)
    atom-tear     T  torn bio: the write in flight lands only up to a device
                     atomic-unit boundary

`torner atoms` output (atoms.json from capture.sh, --atoms) adds the structural
table: how each application write reached the device in the first place.
"""
import argparse
import collections
import json
import math
import os
import sys

MODEL = {
    "single-drop": "subset of bios",
    "prefix": "subset of bios",
    "reverse": "subset of bios",
    "random-subset": "subset of bios",
    "torn-entry": "partial bio (atom)",
    "atom-order": "in-order prefix (O)",
    "atom-reorder": "reordered cache (R)",
    "atom-tear": "torn bio (T)",
}


def wilson(k, n, z=1.96):
    """95% interval for a proportion; sane at k=0 and k=n, unlike normal approx."""
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, centre - half), min(1.0, centre + half))


def pct(x):
    return "%.1f" % (100 * x)


def load_states(paths):
    rows = []
    for path in paths:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError as e:
                    print("report: %s: skipping unparseable line (%s)"
                          % (path, e), file=sys.stderr)
    return rows


def workload_threads(r):
    """`torner:<mode>:t<N>` -> "t<N>"; concurrency changes the answer, so runs
    that differ only in thread count must not be averaged together."""
    w = r.get("workload", "")
    part = w.rsplit(":", 1)[-1] if ":" in w else ""
    return part if part.startswith("t") else "?"


def group(rows):
    g = collections.OrderedDict()
    for r in rows:
        key = (r.get("config", "?"), workload_threads(r), r.get("strategy", "?"))
        o = r.get("oracle", {})
        s = g.setdefault(key, {"n": 0, "p1": 0, "p2": 0, "p3": 0,
                               "unmountable": 0, "judged": 0})
        s["n"] += 1
        if r.get("mount") == "failed":
            s["unmountable"] += 1
            continue
        s["judged"] += 1
        if o.get("p1") == "fail":
            s["p1"] += 1
        if o.get("p2") == "fail":
            s["p2"] += 1
        if o.get("p3") == "fail":
            s["p3"] += 1
    return g


def per_write(rows):
    """atom-* records -> per (config, threads, strategy): which application
    writes were aimed at by a state that came up and was judged, and which of
    those some state left torn.  A write aimed at only by states that did not
    come up is counted apart, never as intact."""
    g = collections.OrderedDict()
    for r in rows:
        if "targets" not in r:
            continue
        key = (r.get("config", "?"), workload_threads(r), r.get("strategy", "?"))
        s = g.setdefault(key, {"states": 0, "judged": 0, "tearing": 0,
                               "targeted": set(), "torn": set(),
                               "unjudged": set(), "shape": {}})
        s["states"] += 1
        tg = set(map(tuple, r["targets"]))
        for t, sh in zip(r["targets"], r.get("shapes", [])):
            s["shape"][tuple(t)] = sh
        if r.get("mount") != "ok" or not isinstance(r.get("focus"), dict):
            s["unjudged"] |= tg
            continue
        s["judged"] += 1
        s["targeted"] |= tg
        tt = set(map(tuple, r.get("targets_torn", [])))
        s["torn"] |= tt
        s["tearing"] += bool(tt)
    for s in g.values():
        s["unjudged"] -= s["targeted"]
    return g


SHAPES = ("split_flush", "partial", "split_window", "one_bio")


def per_write_text(w, out):
    print("Per-write atomicity -- atom-* strategies", file=out)
    print("  unit is the application write W = (page, version): torn if ANY "
          "state aimed at\n  it came up with W torn.  Writes reached only by "
          "unmountable states are 'unjudged'.\n", file=out)
    hdr = ("%-12s %-5s %-13s %-20s %7s %6s %7s %-15s %7s %8s" %
           ("config", "thr", "strategy", "crash model", "writes", "torn",
            "rate%", "95% interval", "states", "unjudged"))
    print("  " + hdr, file=out)
    print("  " + "-" * len(hdr), file=out)
    for (cfg, thr, strat), s in sorted(w.items()):
        n, k = len(s["targeted"]), len(s["torn"])
        lo, hi = wilson(k, n)
        print("  %-12s %-5s %-13s %-20s %7d %6d %7s %-15s %7d %8d" %
              (cfg, thr, strat, MODEL.get(strat, "?"), n, k,
               pct(k / n) if n else "n/a", "%s - %s" % (pct(lo), pct(hi)),
               s["judged"], len(s["unjudged"])), file=out)
        # Per shape: with --prefer-split the sample is skewed toward split
        # writes on purpose, and only these rows are rates of anything.
        if not s["shape"]:
            continue
        for sh in SHAPES:
            tw = {t for t in s["targeted"] if s["shape"].get(t) == sh}
            if not tw:
                continue
            kw = len(tw & s["torn"])
            lo, hi = wilson(kw, len(tw))
            print("  %-12s %-5s %-13s   %-18s %7d %6d %7s %-15s" %
                  ("", "", "", "- " + sh, len(tw), kw, pct(kw / len(tw)),
                   "%s - %s" % (pct(lo), pct(hi))), file=out)
    print(file=out)


def structure_text(atoms, out):
    print("How application writes reached the device -- torner atoms", file=out)
    if not atoms:
        print("  no input (pass capture's atoms.json with --atoms)\n", file=out)
        return
    hdr = ("%-12s %-5s %7s %7s %7s %7s %7s %7s %6s  %-26s" %
           ("config", "thr", "writes", "one bio", "window", "flush", "partial",
            "reorder", "split%", "states to cover O / R / T"))
    print("  " + hdr, file=out)
    print("  " + "-" * len(hdr), file=out)
    for o in atoms:
        wr, sh, pl = o.get("writes", {}), o.get("shape", {}), o.get("plans", {})
        n = wr.get("workload", 0)
        split = n - sh.get("one_bio", 0)
        cover = " / ".join(str(pl.get(k, {}).get("states", "?"))
                           for k in ("atom-order", "atom-reorder", "atom-tear"))
        print("  %-12s %-5s %7d %7d %7d %7d %7d %7d %6s  %-26s" %
              (o.get("config", "?") or "?", workload_threads(o), n,
               sh.get("one_bio", 0), sh.get("split_window", 0),
               sh.get("split_flush", 0), sh.get("partial", 0),
               sh.get("reorderable", 0), pct(split / n) if n else "n/a",
               cover), file=out)
    print("\n  window: pieces within one FLUSH window -- a crash between them "
          "needs no\n  reordering.  flush: a FLUSH lands between pieces, so part "
          "of the write is\n  durable before the rest is even issued.  Only a "
          "file system's recovery stands\n  between either and a torn write; "
          "one-bio writes tear only under model T.\n", file=out)


def table1_text(g, out):
    print("\n§2.2 Table 1 -- torn exposure by configuration", file=out)
    print("  rate is over states that came up; unmountable states are counted "
          "separately,\n  never silently dropped.\n", file=out)
    hdr = ("%-12s %-5s %-13s %-19s %6s %5s %7s %-15s" %
           ("config", "thr", "strategy", "persistence model", "states", "torn",
            "rate%", "95% interval"))
    print("  " + hdr, file=out)
    print("  " + "-" * len(hdr), file=out)
    for (cfg, thr, strat), s in sorted(g.items()):
        lo, hi = wilson(s["p1"], s["judged"])
        print("  %-12s %-5s %-13s %-19s %6d %5d %7s %-15s" %
              (cfg, thr, strat, MODEL.get(strat, "?"), s["judged"], s["p1"],
               pct(s["p1"] / s["judged"]) if s["judged"] else "n/a",
               "%s - %s" % (pct(lo), pct(hi))), file=out)
    print(file=out)


def coverage_text(g, out):
    print("§7 state coverage -- what was actually examined", file=out)
    hdr = ("%-12s %-5s %-13s %7s %7s %5s %5s %5s %12s" %
           ("config", "thr", "strategy", "states", "judged", "P1", "P2", "P3",
            "unmountable"))
    print("  " + hdr, file=out)
    print("  " + "-" * len(hdr), file=out)
    for (cfg, thr, strat), s in sorted(g.items()):
        print("  %-12s %-5s %-13s %7d %7d %5d %5d %5d %12d" %
              (cfg, thr, strat, s["n"], s["judged"], s["p1"], s["p2"], s["p3"],
               s["unmountable"]), file=out)
    print(file=out)


def invariants_text(loginvs, out):
    print("§7 invariants -- T2a", file=out)
    if not loginvs:
        print("  no input (pass loginv output with --loginv)\n", file=out)
        return
    hdr = ("%-16s %-8s %-16s %9s %9s %9s" %
           ("config", "I1", "bio containment", "tx checked", "tx skipped",
            "violations"))
    print("  " + hdr, file=out)
    print("  " + "-" * len(hdr), file=out)
    for o in loginvs:
        c = o.get("coverage", {})
        ch = o.get("checks", {})
        print("  %-16s %-8s %-16s %9s %9s %9s" %
              (o.get("config", "?"), ch.get("I1", "?"),
               ch.get("bio_containment", "?"),
               c.get("i1_transactions_checked", "-"),
               c.get("i1_transactions_skipped", "-"),
               o.get("violation_count", "-")), file=out)
    print(file=out)
    print("  application writes vs bio boundaries:", file=out)
    for o in loginvs:
        c = o.get("coverage", {})
        n = c.get("app_writes_checked", 0)
        sp = c.get("app_writes_spanning_multiple_bios", 0)
        if not n:
            continue
        print("    %-16s %d/%d writes span >1 bio (max %s), i.e. %s%% are not "
              "one bio" % (o.get("config", "?"), sp, n,
                           c.get("max_bios_per_app_write", "?"),
                           pct(sp / n)), file=out)
    print(file=out)


def missing_text(out):
    print("§7 regression (T1) -- no input: CrashMonkey results are not read "
          "by this tool", file=out)
    print("§7 fault injection (T3) -- no input: not implemented\n", file=out)


def latex_per_write(w, out):
    print("% generated by torner-report; do not edit", file=out)
    print(r"\begin{tabular}{lllrrrl}", file=out)
    print(r"\toprule", file=out)
    print(r"Configuration & Threads & Crash model & Writes & Torn & Rate & 95\% CI \\",
          file=out)
    print(r"\midrule", file=out)
    for (cfg, thr, strat), s in sorted(w.items()):
        n, k = len(s["targeted"]), len(s["torn"])
        lo, hi = wilson(k, n)
        print(r"%s & %s & %s & %d & %d & %s\%% & %s--%s\%% \\" %
              (cfg.replace("_", r"\_"), thr, MODEL.get(strat, "?"), n, k,
               pct(k / n) if n else "n/a", pct(lo), pct(hi)), file=out)
    print(r"\bottomrule", file=out)
    print(r"\end{tabular}", file=out)


def latex(g, out):
    print("% generated by torner-report; do not edit", file=out)
    print(r"\begin{tabular}{lllrrrl}", file=out)
    print(r"\toprule", file=out)
    print(r"Configuration & Threads & Model & States & Torn & Rate & 95\% CI \\",
          file=out)
    print(r"\midrule", file=out)
    for (cfg, thr, strat), s in sorted(g.items()):
        lo, hi = wilson(s["p1"], s["judged"])
        print(r"%s & %s & %s & %d & %d & %s\%% & %s--%s\%% \\" %
              (cfg.replace("_", r"\_"), thr, MODEL.get(strat, "?"), s["judged"],
               s["p1"], pct(s["p1"] / s["judged"]) if s["judged"] else "n/a",
               pct(lo), pct(hi)), file=out)
    print(r"\bottomrule", file=out)
    print(r"\end{tabular}", file=out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("states", nargs="*", help="states-*.jsonl from explore.sh")
    ap.add_argument("--loginv", action="append", default=[],
                    help="a torner loginv JSON output (repeatable)")
    ap.add_argument("--atoms", action="append", default=[],
                    help="a torner atoms JSON output, e.g. capture's atoms.json "
                         "(repeatable)")
    ap.add_argument("--latex", action="store_true",
                    help="emit LaTeX for Table 1 (and the per-write table)")
    args = ap.parse_args()

    if not args.states and not args.loginv and not args.atoms:
        ap.error("nothing to report on")

    rows = load_states(args.states)
    g = group(rows)
    w = per_write(rows)
    atoms = []
    for p in args.atoms:
        with open(p) as f:
            atoms.append(json.load(f))

    loginvs = []
    for p in args.loginv:
        with open(p) as f:
            for line in f:
                line = line.strip()
                if line:
                    loginvs.append(json.loads(line))

    if args.latex:
        latex(g, sys.stdout)
        if w:
            print()
            latex_per_write(w, sys.stdout)
        return

    print("torner-report  (%d state records from %d file(s))"
          % (len(rows), len(args.states)))
    if g:
        table1_text(g, sys.stdout)
    if w:
        per_write_text(w, sys.stdout)
    if g:
        coverage_text(g, sys.stdout)
    structure_text(atoms, sys.stdout)
    invariants_text(loginvs, sys.stdout)
    missing_text(sys.stdout)


if __name__ == "__main__":
    main()
