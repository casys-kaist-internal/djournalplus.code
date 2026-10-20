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
  writes_*        the application writes the atom-* states aimed at, and how
                  many of them some state left torn, overall and per crash
                  model (O in-order prefix, R reordered cache, T torn bio)
  upper95         Wilson 95% upper bound on the per-write tear rate
  witness         the first violating state: strategy, state_spec, what broke

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
          "viol_content", "viol_size", "viol_durability", "p3_dirty",
          "writes_targeted", "writes_torn", "torn_O", "torn_R", "torn_T",
          "upper95", "kinds", "witness", "capture")


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

    states = unmount = unjudged = vc = vs = vd = p3 = 0
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
               writes_targeted=len(targeted), writes_torn=len(torn),
               torn_O=len(by_model["O"]), torn_R=len(by_model["R"]),
               torn_T=len(by_model["T"]),
               upper95=("%.4f" % wilson_hi(len(torn), len(targeted))
                        if targeted else ""),
               kinds=" ".join("%s=%d" % kv for kv in sorted(kinds.items())),
               witness=witness or "")
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
