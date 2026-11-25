#!/usr/bin/env python3
"""PG crash trials of run_recovery_vm.sh (application or system crash): did a checkpoint
complete between the position read just before the crash and the restart? before_crash
redo_lsn (.times) against the restart's "redo starts at" (restart.log); also gone_s and the
kill trace's line (application crashes). From the libra08 app-crash workspaces of 2026-11-18
(bench/workspace/libra08-appcrash-*). Args: result dirs."""
import re
import sys
from pathlib import Path


def lsn(s):
    hi, lo = s.split("/")
    return (int(hi, 16) << 32) + int(lo, 16)


for d in sys.argv[1:]:
    for t in sorted(Path(d).glob("postgres_*.times")):
        label = t.name[:-6]
        txt = t.read_text()
        m = re.search(r"before_crash .*redo_lsn=(\S+)", txt)
        g = re.search(r"gone_s=([\d.]+)", txt)
        kt = re.search(r"after_kill_writes=(\d+).*kill_to_gone_ms=(\S+)(?:.*lost_events=(\d+))?", txt)
        rs = None
        r = t.with_name(label + ".restart.log")
        if r.exists():
            mr = re.search(r"redo starts at (\S+)", r.read_text(errors="replace"))
            rs = mr.group(1).rstrip(",") if mr else None
        same = "?"
        if m and rs:
            delta = lsn(rs) - lsn(m.group(1))
            same = "same" if delta == 0 else "MOVED %+.3f GB" % (delta / 1e9)
        print("%-62s redo@kill %-12s restart redo %-12s %-14s gone %ss after_kill_writes %s lost %s" % (
            label[:62], m.group(1) if m else "?", rs or "?", same, g.group(1) if g else "?",
            kt.group(1) if kt else "?", (kt.group(3) or "0") if kt else "?"))
