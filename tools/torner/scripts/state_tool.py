#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Small JSON plumbing between `torner replay --enumerate`, `torner check` and the
JSONL that `torner-report` reads.  It exists so the shell harness does not do
surgery on JSON with sed, which is how fields end up silently dropped.

  state_tool.py focus < state.json
      "page version" per target of an atom-* state, for check --focus-file

  state_tool.py merge --state-file S [--check-file C] --p3 pass|fail|n/a
                      [--mount-failed DETAIL] [--check-error DETAIL]
                      [--tier T] [--config FS] [--workload W] [--run-id R]
                      [--out FILE]
      one result record: check's verdict, the state it was judged on, P3, and
      -- for atom-* states -- which of the targeted writes tore.  With --out
      the record is appended in a single write(2), so parallel states can
      share one JSONL file.
"""
import argparse
import json
import os
import sys


def cmd_focus(_args):
    st = json.loads(sys.stdin.readline())
    for page, version in st.get("targets", []):
        print(page, version)


STATE_KEYS = ("strategy", "model", "epoch", "fepoch", "crash_entry",
              "state_id", "state_spec", "progress_limit", "targets", "shapes")


def cmd_merge(args):
    with open(args.state_file) as f:
        st = json.loads(f.readline())

    rec = None
    if args.check_file:
        with open(args.check_file) as f:
            txt = f.read().strip()
        if txt:
            try:
                rec = json.loads(txt.splitlines()[-1])
            except json.JSONDecodeError:
                rec = None

    if rec is None:
        rec = {"tier": args.tier, "config": args.config,
               "workload": args.workload, "run_id": args.run_id,
               "oracle": {"p1": "n/a", "p2": "n/a", "p3": "n/a", "p4": "n/a"}}
        if args.mount_failed is not None:
            rec["mount"] = "failed"
            rec["detail"] = args.mount_failed
        else:
            # Recovery ran but the oracle could not: typically the data file
            # itself did not survive.  P3 is still known.
            rec["mount"] = "ok"
            rec["oracle"]["p3"] = args.p3
            rec["detail"] = args.check_error or "check produced no output"
    else:
        rec["mount"] = "ok"
        rec.setdefault("oracle", {})["p3"] = args.p3

    for k in STATE_KEYS:
        if k in st:
            rec[k] = st[k]
    rec["strategy"] = st.get("strategy", rec.get("strategy"))

    # Which targeted writes tore in THIS state.  Kept next to the targets so
    # the report can attribute per write without re-deriving anything.
    if "targets" in st and isinstance(rec.get("focus"), dict):
        rec["targets_torn"] = [[t["page"], t["version"]]
                               for t in rec["focus"].get("torn", [])]

    line = json.dumps(rec, separators=(",", ":")) + "\n"
    if args.out:
        fd = os.open(args.out, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode())
        finally:
            os.close(fd)
    else:
        sys.stdout.write(line)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("focus")

    m = sub.add_parser("merge")
    m.add_argument("--state-file", required=True)
    m.add_argument("--check-file")
    m.add_argument("--p3", default="n/a")
    m.add_argument("--mount-failed", default=None)
    m.add_argument("--check-error", default=None)
    m.add_argument("--tier", default="T2b")
    m.add_argument("--config", default="")
    m.add_argument("--workload", default="")
    m.add_argument("--run-id", default="")
    m.add_argument("--out", default=None)

    args = ap.parse_args()
    {"focus": cmd_focus, "merge": cmd_merge}[args.cmd](args)


if __name__ == "__main__":
    main()
