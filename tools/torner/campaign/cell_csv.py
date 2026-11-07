#!/usr/bin/env python3
"""cell_csv -- one CSV line per capture of the atomicity table (paper §6.2).

    cell_csv.py [--header] [--row ROW --profile PROFILE] CAPTURE_DIR...

ROW and PROFILE default to the capture's cell.json (table_guest.sh writes it).

Reads what capture.sh and explore.sh left in a capture directory --
capture.json, atoms.json, states-<strategy>.jsonl -- and says, for that
(configuration, row, profile):

  states          crash states that came up and were judged, over every strategy
  viol_content    states with a content tear (P1 other than the size rule)
  viol_size       states with a size violation (check --append, one writer)
  viol_durability states with a lost fsync'd write (P2)
  p3_dirty        states whose fsck says something the fresh file system's did not
  p3_na           states fsck did not judge: the file system would not unmount
  writes_*        the application writes the atom-* states aimed at, and how
                  many of them some state left torn, overall and per crash
                  model (O in-order prefix, R reordered cache, T torn bio)
  upper95         Wilson 95% upper bound on the per-write tear rate
  witness         the first violating state: strategy, state_spec, what broke
  reused, reuse_flush   tau, CONFIG_TAU_PROBE_TORN (tau-probe.txt): journal segments
                  handed out again over the capture, and those whose free was not
                  yet on the map log, so tau_flush_freed wrote it on the spot
  reused_win, reuse_flush_win   the same inside torner gen's timed run, the only
                  part explore crashes in -- not its prefill (tau-probe-samples.txt)
  i1_*            tau, loginv.json: gated I1 over every record of the log, no
                  crash state needed -- records checked and skipped, blocks with
                  no write in the log, records ordered by their own flush, by the
                  host commit they name, whose host commit never came, and
                  violations (torner README, `torner loginv`)
  i2_*, i3_*, i4_*  tau, loginv.json: the tail (journal blocks checked, not
                  covered when a record's tail or a FREE ended their transaction's
                  replay, home writes before the record was valid -- leads),
                  scoped revoke tags (checked, violating), the map log (segment
                  reuses checked, violations)
  i5_*            loginv.json: I5, each application write inside one durable
                  unit -- writes checked, split across units (and how many of
                  those start in gen's timed run), held in part (tau: counted,
                  not judged), in no unit.  The unit is the tau or jbd2
                  transaction; on ext4/xfs with no data journal it is the bio,
                  and i5_split counts writes spanning more than one

A 2 KiB append alternates a write that starts a block (even page) with one
inside the block the previous write allocated (odd page); --row ap2k splits
the per-write counts, and the pages any violation names, that way.
"""
import argparse
import csv
import glob
import json
import math
import os
import sys

FIELDS = ("config", "row", "profile", "tag", "kernel", "mount_opts", "mkfs_opts",
          "mode", "unit", "sector", "threads", "fsync_every", "gen_args",
          "writes", "one_bio", "split_window", "split_flush", "partial",
          "states", "unmountable", "unjudged",
          "viol_content", "viol_size", "viol_durability", "p3_dirty", "p3_na",
          "writes_targeted", "writes_torn", "torn_O", "torn_R", "torn_T",
          "upper95", "kinds", "witness", "capture",
          "reused", "reuse_flush", "reused_win", "reuse_flush_win",
          "i1_checked", "i1_skipped", "i1_missing", "i1_own", "i1_gated",
          "i1_gate_closed", "i1_violations",
          "i5_checked", "i5_split", "i5_split_run", "i5_partial", "i5_no_unit",
          "i2_blocks", "i2_uncovered", "i2_leads", "i3_tags", "i3_violations",
          "i4_reuses", "i4_violations")


def wilson_hi(k, n, z=1.96):
    if n == 0:
        return float("nan")
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (c + r) / d


def sector_of(gen_args):
    a = gen_args.split()
    for i, x in enumerate(a):
        if x == "--sector" and i + 1 < len(a):
            return a[i + 1]
    return "4096"


def rows_of(cap):
    for path in sorted(glob.glob(os.path.join(cap, "states-*.jsonl"))):
        strat = os.path.basename(path)[len("states-"):-len(".jsonl")]
        with open(path) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                r.setdefault("strategy", strat)
                yield r


def violation_text(r):
    vs = r.get("violations", [])
    parts = []
    for v in vs[:3]:
        s = "%s@%s" % (v.get("kind", "?"), v.get("page_id", "?"))
        if "eof" in v:
            s += " eof=%s" % v["eof"]
        if "version_lo" in v:
            s += " v%s..%s" % (v["version_lo"], v["version_hi"])
        parts.append(s)
    for t in (r.get("focus") or {}).get("torn", [])[:3]:
        parts.append("target %s:%s %s" % (t.get("page"), t.get("version"),
                                           t.get("kind")))
    return "; ".join(parts)


def probes(cap, duration):
    """seg_reused / seg_reuse_flush over the capture, and inside gen's timed run: from
    the first sample at or before (gen's end - duration) to the first after gen ended"""
    out = {}
    try:
        kv = dict(x.split("=", 1) for x in open(os.path.join(cap, "tau-probe.txt")).read().split())
    except (OSError, ValueError):
        return out
    out.update(reused=kv.get("seg_reused", ""), reuse_flush=kv.get("seg_reuse_flush", ""))
    rows = []
    try:
        for line in open(os.path.join(cap, "tau-probe-samples.txt")):
            f = line.split()
            try:
                d = {"t": float(f[0])}
                d.update((k, int(v)) for k, v in (x.split("=", 1) for x in f[1:]))
            except (ValueError, IndexError):
                continue
            rows.append(d)
    except OSError:
        return out
    up = [i for i, d in enumerate(rows) if d.get("gen")]
    if not up:
        return out
    end = rows[min(up[-1] + 1, len(rows) - 1)]
    before = [d for d in rows[:up[-1] + 1] if d["t"] <= end["t"] - duration]
    if before and all(k in d for d in (before[-1], end)
                      for k in ("seg_reused", "seg_reuse_flush")):
        out.update(reused_win=end["seg_reused"] - before[-1]["seg_reused"],
                   reuse_flush_win=end["seg_reuse_flush"] - before[-1]["seg_reuse_flush"])
    return out


def loginv_i1(cap):
    """capture.sh's loginv verdicts (loginv.json), captures from 11-07 on."""
    try:
        j = json.load(open(os.path.join(cap, "loginv.json")))
    except (OSError, ValueError):
        return {}
    c, ck, out = j.get("coverage", {}), j.get("checks", {}), {}
    if ck.get("I5") == "run":
        if j.get("config", "").startswith(("tau-", "ext4-data")):
            out.update(i5_checked=c.get("i5_writes_checked", ""),
                       i5_split=c.get("i5_writes_split", ""),
                       i5_split_run=c.get("i5_writes_split_in_run", ""),
                       i5_partial=c.get("i5_writes_partial", ""),
                       i5_no_unit=c.get("i5_writes_in_no_unit", ""))
        else:   # no data journal: the bio is the unit
            out.update(i5_checked=c.get("app_writes_checked", ""),
                       i5_split=c.get("app_writes_spanning_multiple_bios", ""))
    for k, src, chk in (("i2_blocks", "i2_blocks", "I2"),
                        ("i2_uncovered", "i2_uncovered", "I2"),
                        ("i2_leads", "i2_leads", "I2"),
                        ("i3_tags", "i3_scoped_tags", "I3"),
                        ("i3_violations", "i3_violations", "I3"),
                        ("i4_reuses", "i4_segment_reuses", "I4"),
                        ("i4_violations", "i4_violations", "I4")):
        if ck.get(chk) == "run":
            out[k] = c.get(src, "")
    if ck.get("I1") != "run":
        return out
    keys = (("i1_checked", "i1_transactions_checked"),
            ("i1_skipped", "i1_transactions_skipped"),
            ("i1_missing", "i1_blocks_missing"),
            ("i1_own", "i1_ordered_own_flush"),
            ("i1_gated", "i1_ordered_by_host_commit"),
            ("i1_gate_closed", "i1_gate_never_open"),
            ("i1_violations", "i1_violations"))
    out.update({k: c.get(src, "") for k, src in keys})
    return out


def summarize(cap, row, profile):
    cj = json.load(open(os.path.join(cap, "capture.json")))
    try:
        cell = json.load(open(os.path.join(cap, "cell.json")))
    except (OSError, ValueError):
        cell = {}
    row = row or cell.get("row", "")
    profile = profile or cell.get("profile", "")
    try:
        aj = json.load(open(os.path.join(cap, "atoms.json")))
    except (OSError, ValueError):
        aj = {"writes": {}, "shape": {}}
    out = {k: "" for k in FIELDS}
    out.update(config=cj.get("fs", ""), row=row, profile=profile,
               tag=cell.get("tag", "") or cell.get("cap_param", ""),
               kernel=cj.get("kernel", ""), mount_opts=cj.get("mount_opts", ""),
               mkfs_opts=cj.get("mkfs_opts", ""), mode=cj.get("mode", ""),
               unit=cj.get("unit", ""), sector=sector_of(cj.get("gen_args", "")),
               threads=cj.get("threads", ""), fsync_every=cj.get("fsync_every", ""),
               gen_args=cj.get("gen_args", "").strip(),
               writes=aj.get("writes", {}).get("workload", ""),
               capture=os.path.abspath(cap))
    for k in ("one_bio", "split_window", "split_flush", "partial"):
        out[k] = aj.get("shape", {}).get(k, "")

    states = unmount = unjudged = vc = vs = vd = p3 = p3na = 0
    targeted, torn = set(), set()
    vpages = set()      # pages any state's violation names, every strategy
    by_model = {"O": set(), "R": set(), "T": set()}
    kinds = {}
    witness = None
    for r in rows_of(cap):
        if r.get("mount") == "failed":
            unmount += 1
            continue
        o, st = r.get("oracle", {}), r.get("stats")
        if not st:
            unjudged += 1
            continue
        states += 1
        content = st.get("p1_violations", 0) - st.get("size_violations", 0)
        bad = False
        if content > 0:
            vc += 1
            bad = True
        if o.get("size") == "fail":
            vs += 1
            bad = True
        if o.get("p2") == "fail":
            vd += 1
            bad = True
        if o.get("p3") == "fail":
            p3 += 1
        elif o.get("p3") == "n/a":
            p3na += 1
        for v in r.get("violations", []):
            kinds[v.get("kind", "?")] = kinds.get(v.get("kind", "?"), 0) + 1
            if "page_id" in v:
                vpages.add(v["page_id"])
        if "targets" in r and isinstance(r.get("focus"), dict):
            tg = set(map(tuple, r["targets"]))
            targeted |= tg
            tt = set(map(tuple, r.get("targets_torn", [])))
            torn |= tt
            m = r.get("model")
            if m in by_model:
                by_model[m] |= tt
            if tt:
                bad = True
        if bad and witness is None:
            witness = "%s %s: %s" % (r.get("strategy", "?"),
                                     r.get("state_spec", "?"), violation_text(r))
    out.update(states=states, unmountable=unmount, unjudged=unjudged,
               viol_content=vc, viol_size=vs, viol_durability=vd, p3_dirty=p3,
               p3_na=p3na, writes_targeted=len(targeted), writes_torn=len(torn),
               torn_O=len(by_model["O"]), torn_R=len(by_model["R"]),
               torn_T=len(by_model["T"]),
               upper95=("%.4f" % wilson_hi(len(torn), len(targeted))
                        if targeted else ""),
               kinds=" ".join("%s=%d" % kv for kv in sorted(kinds.items())),
               witness=witness or "")
    out.update(probes(cap, float(cj.get("duration_s", 5))))
    out.update(loginv_i1(cap))
    if row == "ap2k":
        # starts a block (even page) / inside the block the last write allocated
        nb = {p for p in targeted if p[0] % 2 == 0}
        ib = targeted - nb
        vn = sum(1 for p in vpages if p % 2 == 0)
        out["kinds"] = (out["kinds"] + " " if out["kinds"] else "") + \
            "newblock=%d/%d inblock=%d/%d viol_pages_newblock=%d viol_pages_inblock=%d" % (
                len(torn & nb), len(nb), len(torn & ib), len(ib), vn, len(vpages) - vn)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captures", nargs="*")
    ap.add_argument("--row", default="")
    ap.add_argument("--profile", default="")
    ap.add_argument("--header", action="store_true")
    a = ap.parse_args()
    w = csv.DictWriter(sys.stdout, fieldnames=FIELDS)
    if a.header:
        w.writeheader()
    for cap in a.captures:
        w.writerow(summarize(cap, a.row, a.profile))


if __name__ == "__main__":
    main()
