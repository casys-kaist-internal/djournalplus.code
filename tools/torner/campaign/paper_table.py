#!/usr/bin/env python3
"""paper_table -- the atomicity table (paper §6.2) from table.csv files.

    paper_table.py [--latex] table.csv...

One cell per (row, configuration), every profile and capture of it merged: a
cell is violated (x) when any judged crash state broke a write -- content, size
or durability -- and holds (v) otherwise, with n = states judged and the
per-write Wilson 95% upper bound of the atom-* writes.  Below the grid, every
violated cell's first witness, and the counts behind each cell.
"""
import argparse
import csv
import math
import sys

# ap2k is one 2 KiB append workload: odd pages land inside the block the page
# before allocated (the paper's row), even pages start a block (a row of its own)
ROWS = (("ow4k", "Overwrite, single block"), ("ow16k", "Overwrite, multi-block"),
        ("ap2k:in", "Append, within a block"), ("ap2k:new", "Append, 2 KiB into a new block"),
        ("ap4k", "Append, single block"),
        ("ap16k", "Append, multi-block"), ("prealloc", "Preallocated write"),
        ("hole", "Write to a hole"))
COLS = (("ext4", "EXT4"), ("xfs", "XFS"), ("zfs-16k-tp", "ZFS"),
        ("ext4-data", "EXT4_Data"), ("tau-ext4", "τ-EXT4"), ("tau-xfs", "τ-XFS"),
        ("ext4-dioread-lock", "EXT4 dioread_lock"), ("ext4-nodelalloc", "EXT4 nodelalloc"))


def wilson_hi(k, n, z=1.96):
    if n == 0:
        return float("nan")
    p = k / n
    d = 1 + z * z / n
    return (p + z * z / (2 * n) + z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / d


def num(r, k):
    try:
        return int(r.get(k) or 0)
    except ValueError:
        return 0


def load(paths):
    cells = {}
    for p in paths:
        with open(p) as f:
            for r in csv.DictReader(f):
                if r.get("tag"):
                    continue    # a control run, reported apart
                cells.setdefault((r["row"], r["config"]), []).append(r)
    return cells


def kind_counts(rs):
    """per-kind counts cell_csv.py puts in "kinds" for ap2k, summed over rows"""
    t = {}
    for r in rs:
        for tok in r.get("kinds", "").split():
            k, _, v = tok.partition("=")
            if k in ("newblock", "inblock"):
                a, _, b = v.partition("/")
                t[k + "_torn"] = t.get(k + "_torn", 0) + int(a or 0)
                t[k + "_targeted"] = t.get(k + "_targeted", 0) + int(b or 0)
            elif k in ("viol_pages_newblock", "viol_pages_inblock"):
                t[k] = t.get(k, 0) + int(v or 0)
    return t


def merge(rs):
    m = {k: sum(num(r, k) for r in rs) for k in
         ("states", "viol_content", "viol_size", "viol_durability", "writes",
          "writes_targeted", "writes_torn", "torn_O", "torn_R", "torn_T",
          "unmountable", "unjudged", "p3_dirty")}
    m["bad"] = m["viol_content"] + m["viol_size"] + m["viol_durability"] + m["writes_torn"]
    m["witness"] = next((r["witness"] for r in rs if r.get("witness")), "")
    m["profiles"] = "/".join(sorted({r["profile"] for r in rs}))
    m["kernel"] = "; ".join(sorted({r["kernel"] for r in rs}))
    m["kinds"] = kind_counts(rs)
    return m


def split_ap2k(m, which):
    """the ap2k cell seen through one kind of write: "in" or "new" """
    k = m["kinds"]
    viol = m["viol_content"] + m["viol_size"] + m["viol_durability"]
    if not k or (viol and "viol_pages_inblock" not in k):
        return m        # an older CSV: the violations were not told apart
    side = "inblock" if which == "in" else "newblock"
    s = dict(m)
    s["writes_targeted"] = k.get(side + "_targeted", 0)
    s["writes_torn"] = k.get(side + "_torn", 0)
    pages = k.get("viol_pages_" + side, 0)
    s["bad"] = s["writes_torn"] + pages
    if not s["bad"]:
        s["viol_content"] = s["viol_size"] = s["viol_durability"] = 0
    return s


def mark(m):
    if m is None:
        return "-"
    if m["bad"]:
        why = [w for w, k in (("content", "viol_content"), ("size", "viol_size"),
                              ("durability", "viol_durability")) if m[k]]
        return "x (%s)" % "+".join(why or ["target torn"])
    hi = wilson_hi(0, m["writes_targeted"]) if m["writes_targeted"] else float("nan")
    return "v n=%d%s" % (m["states"], "" if math.isnan(hi) else " <%.1f%%" % (100 * hi))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tables", nargs="+")
    ap.add_argument("--latex", action="store_true")
    a = ap.parse_args()
    cells = load(a.tables)
    cols = [c for c in COLS if any(k[1] == c[0] for k in cells)]
    grid = {k: merge(v) for k, v in cells.items()}
    for (rk, ck) in [k for k in grid if k[0] == "ap2k"]:
        grid[("ap2k:in", ck)] = split_ap2k(grid[(rk, ck)], "in")
        grid[("ap2k:new", ck)] = split_ap2k(grid[(rk, ck)], "new")
        del grid[(rk, ck)]
    if a.latex:
        print("\\begin{tabular}{l%s}" % ("c" * len(cols)))
        print(" & ".join(["Write"] + [c[1] for c in cols]) + " \\\\ \\hline")
        for rk, rn in ROWS:
            ms = [grid.get((rk, c[0])) for c in cols]
            print(" & ".join([rn] + ["--" if m is None else
                                     ("\\xmark" if m["bad"] else "\\cmark") for m in ms]) + " \\\\")
        print("\\end{tabular}")
        return
    w = max(len(rn) for _, rn in ROWS)
    print("| %s | %s |" % ("write".ljust(w), " | ".join(c[1] for c in cols)))
    print("|%s|%s|" % ("-" * (w + 2), "|".join("-" * (len(c[1]) + 2) for c in cols)))
    for rk, rn in ROWS:
        print("| %s | %s |" % (rn.ljust(w), " | ".join(mark(grid.get((rk, c[0]))) for c in cols)))
    print()
    for (rk, ck), m in sorted(grid.items()):
        print("%-9s %-18s states=%-6d writes=%-6d targeted=%-5d torn=%d (O%d R%d T%d)"
              "  content=%d size=%d durability=%d  unmountable=%d p3=%d  [%s]"
              % (rk, ck, m["states"], m["writes"], m["writes_targeted"], m["writes_torn"],
                 m["torn_O"], m["torn_R"], m["torn_T"], m["viol_content"], m["viol_size"],
                 m["viol_durability"], m["unmountable"], m["p3_dirty"], m["profiles"]))
        if m["witness"]:
            print("          witness: %s" % m["witness"][:200])


if __name__ == "__main__":
    main()
