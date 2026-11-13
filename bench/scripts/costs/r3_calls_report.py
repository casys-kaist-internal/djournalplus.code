#!/usr/bin/env python3
"""EVAL_PLAN R3 item 4: the calls r3_calls.bt saw, per phase.

usage: r3_calls_report.py <calls file> [...]

<calls file> is r3_calls.bt's output; <calls file>.marks holds the phase starts
in the same clock, one per line: "<phase> <CLOCK_MONOTONIC ns> <wall time>"
(profile.sh PROFILE=r3: warmup from the database's start, measure for the
5-min measurement, after from its end; run_r3_drop.sh: write, drop, after).
A call before the first mark counts in the first phase.  Prints, per phase, the
calls by operation, process and file (parent directory/name), the ones on the
database's data files flagged: PostgreSQL relation files (a number, with .N
segments and _fsm/_vm/_init forks, under base/<db oid>/), InnoDB tablespaces
(*.ibd, undo_*, ibdata*).  The totals are checked against bpftrace's own @calls.
"""
import collections
import re
import sys

EV = re.compile(r"^(\d+) (truncate|unlink|fallocate|rename) (\S+) (\d+) (\S+)(?: over (\S+))? ?(.*)$")
MAP = re.compile(r"^@calls\[(\w+), (.*), (.*), (.*)\]: (\d+)$")
PG_REL = re.compile(r"^\d+/\d+(\.\d+)?(_fsm|_vm|_init)?$")
MY_TS = re.compile(r"(\.ibd$|^[^/]+/undo_\d+$|^[^/]+/ibdata\d*$)")


def data_file(path):
    return bool(PG_REL.match(path) or MY_TS.search(path))


def report(fn):
    marks = []
    try:
        for line in open(fn + ".marks"):
            w = line.split()
            if len(w) >= 2:
                marks.append((int(w[1]), w[0]))
    except OSError:
        pass
    marks.sort()
    phases = [m[1] for m in marks] or ["all"]
    calls = collections.OrderedDict((p, collections.Counter()) for p in phases)
    first = collections.OrderedDict((p, {}) for p in phases)
    bt_total = collections.Counter()
    n = 0
    for line in open(fn, errors="replace"):
        line = line.rstrip("\n")
        m = EV.match(line)
        if m:
            ts, op, comm, path = int(m.group(1)), m.group(2), m.group(3), m.group(6) or m.group(5)
            ph = phases[0]
            for t, name in marks:
                if ts >= t:
                    ph = name
            key = (op, comm, path)
            calls[ph][key] += 1
            first[ph].setdefault(key, m.group(7))
            n += 1
            continue
        m = MAP.match(line)
        if m:
            bt_total[m.group(1)] += int(m.group(5))
    print(f"== {fn}: {n} calls" + (f", phases {' '.join(phases)}" if marks else ""))
    ours = collections.Counter()
    for ph in phases:
        for (op, _, _), c in calls[ph].items():
            ours[op] += c
    if bt_total and bt_total != ours:
        print(f"   (bpftrace @calls {dict(bt_total)} vs lines {dict(ours)}: lines lost?)")
    for ph in phases:
        tot = collections.Counter()
        dat = collections.Counter()
        for (op, comm, path), c in calls[ph].items():
            tot[op] += c
            if data_file(path):
                dat[op] += c
        print(f"-- {ph}: " + (", ".join(f"{op} {tot[op]} (data files {dat[op]})" for op in sorted(tot)) or "no calls"))
        for (op, comm, path), c in sorted(calls[ph].items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"   {c:6d}  {op:9s} {comm:16s} {path}{'  [data]' if data_file(path) else ''}  {first[ph][(op, comm, path)]}")


for f in sys.argv[1:]:
    report(f)
