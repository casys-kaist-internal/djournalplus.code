#!/usr/bin/env python3
"""Did the kill reach every PG process? Per application-crash trial of a result dir
(run_recovery_vm.sh CRASH_MODE=app, postgres_*.times with crash_mode=app; other trials are
listed as skipped): kill_how, gone_s, killed_processes, late, kill_us (from .times); the
"unexpected postmaster exit" lines in the server log (a child that exited on its own after the
postmaster: 64 in every trial up to 11-18, 0 with every process killed); from the kill trace,
whether its window holds the kill marker, the last w_in after the marker and the w_in more
than 100 ms after it; cut / EINTR / in-flight writes from kill_trace.txt. Exit 1 when a trial
was not killed whole (kill_how not each_pm_stopped, or a self-exit line), or with --trace when
a trace that holds the kill shows a write begun more than 100 ms after it. From the libra08
app-crash workspace of 2026-11-18 (bench/workspace/libra08-appcrash-pgkill-1118).
Args: [--trace] <result dir>..."""
import gzip
import re
import sys
from pathlib import Path

LINE = re.compile(r"^\s*(?P<task>.+?)-(?P<pid>\d+)\s+\[(?P<cpu>\d+)\]\s+\S+\s+(?P<ts>[\d.]+):\s+(?P<ev>\w+):(?P<rest>.*)$")


def trace(p):
    first, kill = {}, None
    ws = []
    with gzip.open(p, "rt", errors="replace") as f:
        for line in f:
            if line.startswith("#"):
                continue
            m = LINE.match(line)
            if not m:
                continue
            ts, cpu = float(m.group("ts")), int(m.group("cpu"))
            first.setdefault(cpu, ts)
            if m.group("ev") == "tracing_mark_write":
                if m.group("rest").strip() == "kill" and kill is None:
                    kill = ts
            elif m.group("ev") == "w_in":
                ws.append(ts)
    if kill is None:
        return dict(window="no kill marker")
    start = max(first.values())
    after = [t - kill for t in ws if t > kill]
    return dict(window="holds the kill" if start <= kill else "starts %.3f s after the kill" % (start - kill),
                holds=start <= kill, last_ms=max(after) * 1e3 if after else 0.0,
                n_after=len(after), n_late=sum(1 for a in after if a > 0.1))


bad = 0
check_trace = "--trace" in sys.argv
for d in [a for a in sys.argv[1:] if a != "--trace"]:
    for t in sorted(Path(d).glob("postgres_*.times")):
        label = t.name[:-6]
        tt = t.read_text()
        if not re.search(r"^crash_mode=app\b", tt, re.M):
            print("skip %s: not an application crash" % label)
            continue
        kv = dict(x.partition("=")[::2] for x in " ".join(l for l in tt.splitlines() if "kill_epoch=" in l).split())
        sl = t.with_name(label + ".server.log")
        selfexit = sl.read_text(errors="replace").count("unexpected postmaster exit") if sl.exists() else -1
        kt = t.with_name(label + ".kill_trace.txt")
        ktv = dict(x.partition("=")[::2] for x in kt.read_text().split()) if kt.exists() else {}
        tr = t.with_name(label + ".kill.trace.gz")
        tv = trace(tr) if tr.exists() else dict(window="no trace")
        ok = kv.get("kill_how") == "each_pm_stopped" and selfexit == 0
        if check_trace and tv.get("holds") and tv["n_late"] > 0:
            ok = False
        bad += not ok
        print("%s %s: kill_how=%s gone_s=%s killed=%s late=%s kill_us=%s self-exit lines %d; trace %s%s; cut %s eintr %s inflight %s lost %s db_start_s=%s" % (
            "ok " if ok else "BAD", label, kv.get("kill_how"), kv.get("gone_s"), kv.get("killed_processes"), kv.get("late"),
            kv.get("kill_us"), selfexit, tv["window"],
            ", last w_in %.1f ms after the kill, %d w_in after it, %d later than 100 ms" % (tv["last_ms"], tv["n_after"], tv["n_late"]) if "last_ms" in tv else "",
            ktv.get("cut_writes"), ktv.get("err_writes"), ktv.get("inflight_writes"), ktv.get("lost_events"),
            (re.search(r"db_start_s=([\d.]+)", tt) or [None, "?"])[1]))
sys.exit(1 if bad else 0)
