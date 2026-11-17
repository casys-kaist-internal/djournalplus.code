#!/usr/bin/env python3
"""The writes an application crash cut short, from the guest's kprobe trace
(run_recovery_vm.sh CRASH_MODE=app; recovery_vm_guest.sh trace_prep, trace_on,
kill_db, trace_off): w_in at the file system's write_iter (inode, offset, bytes
asked), w_out at its return (bytes written, or -errno), and the markers "kill"
(just before the kill(2)) and "gone" (no process of the server left). Per task,
a w_out closes that task's last open w_in.

First line, key=value pairs for the trial's .times file:
  trace_writes       writes seen whole in the trace (w_in and w_out)
  inflight_writes    of those, begun before "kill" and returned after it
  cut_writes         returned fewer bytes than asked but more than 0: a write the
                     kill cut short, its first part in the page cache, the rest not
  err_writes         returned 0 or an error (-4 = EINTR: nothing written)
  after_kill_writes  begun after "kill"
  open_writes        a w_in with no w_out by the end of the trace
  orphan_out         a w_out whose w_in was before the trace began
  kill_to_gone_ms    from "kill" to "gone"
Then one line per cut, err and open write:
  <kind> ino= pos= count= ret= task= dt_ms=   (dt_ms: its w_in relative to "kill")
Usage: kill_trace.py <kill.trace[.zst|.gz]>
"""
import gzip
import re
import subprocess
import sys

LINE = re.compile(r"^\s*(?P<task>.+?-(?P<pid>\d+))\s+\[\d+\]\s+\S+\s+(?P<ts>\d+\.\d+): (?P<ev>\w+): (?P<rest>.*)$")
KV = re.compile(r"(\w+)=(-?\d+)")


def read(path):
    if path.endswith(".zst"):
        p = subprocess.Popen(["zstd", "-dc", path], stdout=subprocess.PIPE)
        for raw in p.stdout:
            yield raw.decode(errors="replace")
        p.wait()
    elif path.endswith(".gz"):
        with gzip.open(path, "rt", errors="replace") as f:
            yield from f
    else:
        with open(path, errors="replace") as f:
            yield from f


def main():
    opened = {}  # pid -> [(t_in, ino, pos, count, task)]
    done = []    # (t_in, t_out, ino, pos, count, ret, task)
    t_kill = t_gone = None
    orphan = 0
    for line in read(sys.argv[1]):
        if line.startswith("#"):
            continue
        m = LINE.match(line)
        if not m:
            continue
        ev, ts, pid = m.group("ev"), float(m.group("ts")), m.group("pid")
        if ev == "tracing_mark_write":
            word = m.group("rest").strip()
            if word == "kill" and t_kill is None:
                t_kill = ts
            elif word == "gone":
                t_gone = ts
            continue
        kv = {k: int(v) for k, v in KV.findall(m.group("rest"))}
        if ev == "w_in":
            opened.setdefault(pid, []).append((ts, kv.get("ino"), kv.get("pos"), kv.get("count"), m.group("task")))
        elif ev == "w_out":
            st = opened.get(pid)
            if st:
                t_in, ino, pos, count, task = st.pop()
                done.append((t_in, ts, ino, pos, count, kv.get("ret"), task))
            else:
                orphan += 1
    done = [d for d in done if d[4]]  # zero-length writes say nothing
    ref = t_kill if t_kill is not None else float("nan")
    cut = [d for d in done if d[5] is not None and 0 < d[5] < d[4]]
    err = [d for d in done if d[5] is not None and d[5] <= 0]
    inflight = [d for d in done if t_kill is not None and d[0] <= t_kill < d[1]]
    after = [d for d in done if t_kill is not None and d[0] > t_kill]
    still = [w for st in opened.values() for w in st]
    gone_ms = "%.1f" % ((t_gone - t_kill) * 1e3) if t_kill is not None and t_gone is not None else "?"
    print("trace_writes=%d inflight_writes=%d cut_writes=%d err_writes=%d after_kill_writes=%d open_writes=%d"
          " orphan_out=%d kill_to_gone_ms=%s%s" % (len(done), len(inflight), len(cut), len(err), len(after),
                                                    len(still), orphan, gone_ms,
                                                    "" if t_kill is not None else " kill_marker=missing"))
    for kind, ws in (("cut", cut), ("err", err)):
        for t_in, t_out, ino, pos, count, ret, task in ws:
            print("%s ino=%s pos=%s count=%s ret=%s task=%s dt_ms=%.3f" % (kind, ino, pos, count, ret, task,
                                                                         (t_in - ref) * 1e3))
    for t_in, ino, pos, count, task in still:
        print("open ino=%s pos=%s count=%s ret=- task=%s dt_ms=%.3f" % (ino, pos, count, task, (t_in - ref) * 1e3))


if __name__ == "__main__":
    main()
