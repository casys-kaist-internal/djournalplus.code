#!/usr/bin/env python3
"""The writes an application crash cut short, from the guest's kprobe trace
(run_recovery_vm.sh CRASH_MODE=app; recovery_vm_guest.sh trace_prep, trace_on,
kill_db, trace_off): w_in at the file system's write_iter (inode, offset, bytes
asked), w_out at its return (bytes written, or -errno), and the markers "kill"
(just before the kill(2)) and "gone" (no process of the server left). Per task,
a w_out closes that task's last open w_in.

The trace buffer is per CPU and overwrites its oldest events when full. A task
that ran on a CPU whose events were overwritten then has a w_in whose w_out is
gone, and the task's next w_out closes it: a false cut write (2026-11-18: five
"cut" InnoDB log writer writes, 1.7-2.9 s before the kill, in the three trials
that lost events). So when the trace header says events were lost
(entries-in-buffer < entries-written), only the window where every CPU's events
are whole is read: from the latest of the CPUs' first events.

First line, key=value pairs for the trial's .times file:
  trace_writes       writes seen whole in the window (w_in and w_out)
  inflight_writes    of those, begun before "kill" and returned after it
  cut_writes         returned fewer bytes than asked but more than 0: a write the
                     kill cut short, its first part in the page cache, the rest not
  err_writes         returned 0 or an error (-4 = EINTR: nothing written)
  after_kill_writes  begun after "kill"
  open_writes        a w_in with no w_out by the end of the trace
  orphan_out         a w_out whose w_in was before the window began
  kill_to_gone_ms    from "kill" to "gone"
  lost_events        events the buffer overwrote (0: the window is the whole trace)
  window_ms          where the window begins, relative to "kill"
Then one line per cut, err and open write:
  <kind> ino= pos= count= ret= task= dt_ms=   (dt_ms: its w_in relative to "kill")
Usage: kill_trace.py <kill.trace[.zst|.gz]>
"""
import gzip
import re
import subprocess
import sys

LINE = re.compile(r"^\s*(?P<task>.+?-(?P<pid>\d+))\s+\[(?P<cpu>\d+)\]\s+\S+\s+(?P<ts>\d+\.\d+): (?P<ev>\w+): (?P<rest>.*)$")
KV = re.compile(r"(\w+)=(-?\d+)")
ENTRIES = re.compile(r"entries-in-buffer/entries-written: (\d+)/(\d+)")


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


def window(path):
    """(lost events, the first timestamp of the window where no CPU lost any)"""
    lost = 0
    first = {}
    for line in read(path):
        if line.startswith("#"):
            m = ENTRIES.search(line)
            if m:
                lost = int(m.group(2)) - int(m.group(1))
            continue
        m = LINE.match(line)
        if m and m.group("cpu") not in first:
            first[m.group("cpu")] = float(m.group("ts"))
    if not first:
        return lost, None
    return lost, (max(first.values()) if lost > 0 else min(first.values()))


def main():
    lost, t_from = window(sys.argv[1])
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
        if ts < t_from:
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
    win_ms = "%.1f" % ((t_from - t_kill) * 1e3) if t_kill is not None and t_from is not None else "?"
    flag = ""
    if t_kill is None:
        flag = " kill_marker=missing"
    elif t_from is not None and t_from > t_kill:
        flag = " kill_marker=before_window"
    print("trace_writes=%d inflight_writes=%d cut_writes=%d err_writes=%d after_kill_writes=%d open_writes=%d"
          " orphan_out=%d kill_to_gone_ms=%s lost_events=%d window_ms=%s%s"
          % (len(done), len(inflight), len(cut), len(err), len(after), len(still), orphan, gone_ms, lost,
             win_ms, flag))
    for kind, ws in (("cut", cut), ("err", err)):
        for t_in, t_out, ino, pos, count, ret, task in ws:
            print("%s ino=%s pos=%s count=%s ret=%s task=%s dt_ms=%.3f" % (kind, ino, pos, count, ret, task,
                                                                         (t_in - ref) * 1e3))
    for t_in, ino, pos, count, task in still:
        print("open ino=%s pos=%s count=%s ret=- task=%s dt_ms=%.3f" % (ino, pos, count, task, (t_in - ref) * 1e3))


if __name__ == "__main__":
    main()
