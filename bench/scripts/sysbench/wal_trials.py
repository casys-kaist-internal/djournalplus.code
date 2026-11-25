#!/usr/bin/env python3
"""PG crash trials of run_recovery_vm.sh, per trial and per configuration: application crash
(CRASH_MODE=app, labels postgres_appcrash_...) or system crash (CRASH_MODE=vm, labels
postgres_recovery_...). Columns: the checkpoint interval (mean of the last three before the
kill, as the app-crash runs' gates; and every wal checkpoint in the 300 s before the last
one), the WAL rate, TPS (last 60 s, and the whole load until the kill), the restart
breakdown (mount after a system crash; redo, end-of-recovery checkpoint, other), load
replayed (replayed WAL / WAL rate), KB/txn, redo us/txn, and the restart log's
PANIC/FATAL/ERROR lines. From the libra08 app-crash workspaces of 2026-11-17..19
(bench/workspace/libra08-appcrash-*), where it read app-crash dirs only.
Args: result dirs (postgres/<ts>). A trial whose logs are incomplete is skipped (stderr)."""
import re
import statistics as st
import sys
from datetime import datetime
from pathlib import Path

TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)")
LABEL = re.compile(r"postgres_(appcrash|recovery)_(.+?)_fpw_(on|off)_t\d+_c\d+_x(\d+)(_wal\S+)?$")
ERR = re.compile(r"(PANIC|FATAL|ERROR):|\[ERROR\]")   # as run_recovery_vm.sh's restart_errors


def lsn(s):
    hi, lo = s.split("/")
    return (int(hi, 16) << 32) + int(lo, 16)


def ts(line):
    m = TS.match(line)
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() if m else None


def trial(t, m):
    label = t.name[:-6]
    crash = "app" if m.group(1) == "appcrash" else "system"
    cfg = "%s %s FPW %s%s" % (crash, m.group(2), m.group(3), (" " + m.group(5)[1:]) if m.group(5) else "")
    starts, dist, timed = [], [], 0
    for line in t.with_name(label + ".server.log").read_text(errors="replace").splitlines():
        if "checkpoint starting: wal" in line:
            starts.append(ts(line))
        elif "checkpoint starting: time" in line:
            timed += 1
        md = re.search(r"checkpoint complete.*distance=(\d+) kB", line)
        if md:
            dist.append(int(md.group(1)))
    iv3 = st.mean(b - a for a, b in zip(starts[-4:], starts[-3:]))
    win = [s for s in starts if s >= starts[-1] - 300]
    ivw = [b - a for a, b in zip(win, win[1:])]
    rate = st.mean(dist[-3:]) * 1024 / iv3                      # bytes/s
    tpss = [float(x) for x in re.findall(r"tps: ([\d.]+)", t.with_name(label + ".sysbench.log").read_text())]
    rl = t.with_name(label + ".restart.log").read_text(errors="replace")
    rs = lsn(re.search(r"redo starts at (\S+)", rl).group(1).rstrip(","))
    mdone = re.search(r"redo done at (\S+) .*elapsed: ([\d.]+) s", rl)
    redo = float(mdone.group(2))
    replayed = lsn(mdone.group(1)) - rs
    endck = float(re.search(r"checkpoint complete:.*total=([\d.]+) s", rl.split("end-of-recovery", 1)[1]).group(1))
    tt = t.read_text()
    dbs = float(re.search(r"db_start_s=([\d.]+)", tt).group(1))
    mnt = re.search(r"^mount_s=([\d.]+)", tt, re.M)            # the mount after a system crash
    atk = int(re.search(r"before_crash .*wal_since_redo=(\d+)", tt).group(1))
    tps = st.mean(tpss[-6:])
    load = replayed / rate
    return dict(cfg=cfg, x=m.group(4), n=len(starts), timed=timed, iv3=iv3,
                ivw=(st.mean(ivw), min(ivw), max(ivw), len(ivw)), mib=st.mean(dist[-3:]) / 1024,
                rate=rate, tps=tps, tps_load=st.mean(tpss), atk=atk, replayed=replayed, redo=redo, endck=endck,
                dbs=dbs, mount=float(mnt.group(1)) if mnt else None, other=dbs - redo - endck, load=load,
                kbtx=rate / tps / 1000, ustx=redo / (load * tps) * 1e6,
                errs=sum(1 for line in rl.splitlines() if ERR.search(line)))


rows = []
for d in sys.argv[1:]:
    for t in sorted(Path(d).glob("postgres_*.times")):
        m = LABEL.match(t.name[:-6])
        if not m:
            print("skipped %s: not a PG crash-trial label" % t.name, file=sys.stderr)
            continue
        try:
            rows.append(trial(t, m))
        except (AttributeError, IndexError, OSError, ValueError, ZeroDivisionError, st.StatisticsError) as e:
            print("skipped %s: incomplete (%s: %s)" % (t.name, type(e).__name__, e), file=sys.stderr)

H = ("config", "x", "wal ckpts (time)", "ckpt every s (last 3)", "ckpt every s, last 300 s (min-max, n)", "distance MiB",
     "WAL MB/s", "TPS 60 s", "TPS load", "WAL KB/txn", "redo at kill GB", "replayed GB", "load replayed s",
     "txns replayed (k)", "mount s", "redo s", "end ckpt s", "other s", "DB start s", "redo / load", "redo us/txn",
     "restart errors")
print("| " + " | ".join(H) + " |")
print("|" + "---|" * 2 + "---:|" * (len(H) - 2))


def line(r, x):
    w = r["ivw"]
    return ("| %s | %s | %d (%d) | %.1f | %.1f (%.1f-%.1f, %d) | %.0f | %.1f | %.0f | %.0f | %.2f | %.2f | %.2f | %.1f | %.0f"
            " | %s | %.1f | %.1f | %.1f | %.1f | %.2f | %.0f | %d |"
            % (r["cfg"], x, r["n"], r["timed"], r["iv3"], w[0], w[1], w[2], w[3], r["mib"], r["rate"] / 1e6, r["tps"],
               r["tps_load"], r["kbtx"], r["atk"] / 1e9, r["replayed"] / 1e9, r["load"], r["load"] * r["tps"] / 1e3,
               "" if r["mount"] is None else "%.1f" % r["mount"], r["redo"], r["endck"], r["other"], r["dbs"],
               r.get("ratio", r["redo"] / r["load"]), r["ustx"], r["errs"]))


cfgs = []
for r in rows:
    if r["cfg"] not in cfgs:
        cfgs.append(r["cfg"])
for c in cfgs:
    rs = [r for r in rows if r["cfg"] == c]
    for r in rs:
        print(line(r, r["x"]))
    if len(rs) > 1:
        mean = {k: st.mean(r[k] for r in rs) for k in ("n", "timed", "iv3", "mib", "rate", "tps", "tps_load", "kbtx", "atk",
                                                       "replayed", "redo", "endck", "other", "dbs", "load", "ustx")}
        mean["ivw"] = (st.mean(r["ivw"][0] for r in rs), min(r["ivw"][1] for r in rs), max(r["ivw"][2] for r in rs),
                       sum(r["ivw"][3] for r in rs))
        mounts = [r["mount"] for r in rs]
        mean["mount"] = st.mean(mounts) if None not in mounts else None
        mean["errs"] = sum(r["errs"] for r in rs)                  # summed, not averaged
        mean["cfg"] = "**" + c + " mean**"
        mean["ratio"] = st.mean(r["redo"] / r["load"] for r in rs)
        print(line(mean, "%d trials" % len(rs)))
        print("  %s: DB start min-max %.1f-%.1f s%s" % (
            c, min(r["dbs"] for r in rs), max(r["dbs"] for r in rs),
            "" if mean["mount"] is None else ", mount min-max %.1f-%.1f s" % (min(mounts), max(mounts))), file=sys.stderr)
