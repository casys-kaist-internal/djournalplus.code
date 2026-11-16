#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
explore_rows.py [--n N] [--seed S] [--all] -- rows for the redesign's search

The 11-16 redesign of the atomicity table first searches the baselines for the
conditions that tear them (rows of table_guest.sh's row_parse grammar), then
fixes a matrix of the conditions that did.  This prints row names, one per line:
every combination with --all, else N of them drawn at random (seeded), every
write operation drawn about equally often.

  operation  ow overwrite, ap append, pa preallocated, ho hole, mx mixed chain,
             ma mixed aligned
  unit       8k, 16k
  writers    1, 4                            (t4)
  cache      as gen leaves it, pr (4 KiB preread, order-0 folios), dc (cold)
  dirty      default, dl (16 KiB limit), dl8 (8 KiB, the kernel's minimum)

Feed them to full.sh as ROWS, or build Q3_CELLS / Q4_CELLS from them:
  ROWS="$(explore_rows.py --n 24 --seed 1)" QUEUES="q3 q4" ... full.sh ...
"""
import argparse
import itertools
import random

OPS = ("ow", "ap", "pa", "ho", "mx", "ma")
UNITS = ("8k", "16k")
WRITERS = ("", "t4")
CACHE = ("", "pr", "dc")
DIRTY = ("", "dl", "dl8")


def name(op, unit, *mods):
    return "-".join([op + unit] + [m for m in mods if m])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=24)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    rows = [name(*c) for c in itertools.product(OPS, UNITS, WRITERS, CACHE, DIRTY)]
    if a.all:
        print("\n".join(rows))
        return
    rnd = random.Random(a.seed)
    by_op = {op: [r for r in rows if r.startswith(op)] for op in OPS}
    for v in by_op.values():
        rnd.shuffle(v)
    out = []
    while len(out) < min(a.n, len(rows)):
        for op in OPS:
            if by_op[op] and len(out) < a.n:
                out.append(by_op[op].pop())
    print("\n".join(out))


if __name__ == "__main__":
    main()
