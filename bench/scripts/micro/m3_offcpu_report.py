#!/usr/bin/env python3
"""EVAL_PLAN M3, CT split into on-CPU and off-CPU (final_tau/full/PLAN_m3ct_v1.1.md): tables from a run_fio.sh result
directory run with M3_TRACE=1 M3_OFFCPU=1 (m3_phases.bt + m3_phases_tau.bt + m3_offcpu_tau.bt in one program), one
row per configuration, operation and thread count (one run each).

Per cell, from runs/<label>.m3, .info and results.csv, against the reference run (--ref, a run of the same cells with
the M3 tracer alone):
  - run quality: IOPS and its change against the reference;
  - per fdatasync, us: sync and CT (and the reference's), CT on-CPU (= CT - CT off-CPU), CT off-CPU as the sleep and the
    wait for a CPU; JIO and REC with their off-CPU; switches per sync in CT, JIO and REC;
  - CT off-CPU by what it waited on, from the sleep sites (wbt, tags, folio writeback, runnable, other, lost);
  - the top CT, JIO and REC sleep sites; the write path (outside syncs, stacks with __x64_sys_pwrite64);
  - the tau commits per class (3 in M3's CT, 2 the process elsewhere, 1 other threads) and the revoke path
    (commit.c:742 and 1003);
  - the checks of the plan's section 5.
A kfunc stack lacks the direct caller of the probed function (the trampoline runs before the function's frame), and
a function that has kretfunc probes shows as "f+N, <trampoline>, f+5" (the body, then the entry): the sleep-site
signatures drop the bpf frames and repeats. The full stacks go to m3ct_stacks.txt.

Usage: m3_offcpu_report.py <result dir> --ref <reference result dir> [--manifest <MANIFEST.txt>] [--queue <file>]
       [--gate [--cells N] [--max-lost-pct P]]
Writes <result dir>/m3ct.md (also printed) and m3ct_stacks.txt. --gate: the m3ct_check gate (plan section 7, step 2);
exit status 2 if it fails. --cells: the cells the gate expects (default 2). --max-lost-pct: the lost-stack share of CT
off-CPU the gate allows (default 0: none).
"""
import argparse
import csv
import hashlib
import re
import sys
from collections import defaultdict
from pathlib import Path

PHASE = {0: "other", 1: "D", 2: "JC", 3: "LF", 4: "FL", 5: "TW", 6: "TI", 7: "CT", 8: "JIO", 9: "REC", 10: "DUR",
         12: "out"}
STATE = {0: "R", 0x100: "R+", 1: "S", 2: "D", 4: "T", 8: "t", 0x10: "X", 0x20: "Z", 0x40: "P", 0x80: "I"}
HZ = 999
TOL = 64                                   # commits in flight at SIGINT, at most one per thread
COMMIT = re.compile(r"^tau_(bh|io)_commit_transaction(\.cold)?$")
SCALAR = re.compile(r"^@(\w+):\s?(.*)$")
KEYED = re.compile(r"^@(\w+)\[([^\]]*)\]:\s?(.*)$")
STACKKEY = re.compile(r"^@(\w+)\[(.*)$")
STATS = re.compile(r"^count (\d+), average (-?\d+), total (-?\d+)$")
HIST = re.compile(r"^\[(\S+?)(?:, (\S+?))?[\])]\s+(\d+) \|")


class M3:
    """One .m3 file: scalars and int-keyed maps in .v (key tuple -> int or stats dict), stack-keyed maps in .stk (name
    -> list of (int key tuple, frames, value)), histograms in .hist, other lines (errors) in .notes."""

    def __init__(self, path):
        self.v = defaultdict(dict)
        self.stk = defaultdict(list)
        self.hist = defaultdict(dict)
        self.notes = []
        lines = path.read_text(errors="replace").splitlines()
        i = 0
        while i < len(lines):
            line = lines[i]
            i += 1
            if not line.startswith("@"):
                if line.strip() and not line.startswith(("Attaching", "window_", "[")):
                    self.notes.append(line.strip())
                continue
            m = KEYED.match(line) or SCALAR.match(line)
            if m:
                name = m.group(1)
                key = tuple(int(x) for x in m.group(2).split(",")) if m.re is KEYED and m.group(2).strip() else ()
                text = m.group(m.lastindex).strip()
                if text == "":                                  # a histogram follows
                    rows = []
                    while i < len(lines) and HIST.match(lines[i]):
                        h = HIST.match(lines[i])
                        rows.append((h.group(1), h.group(2) or h.group(1), int(h.group(3))))
                        i += 1
                    self.hist[name][key] = rows
                else:
                    self.v[name][key] = value(text)
                continue
            m = STACKKEY.match(line)
            if m:                                               # a key ending in a stack, one frame per line
                name, head = m.group(1), m.group(2)
                ints = tuple(int(x) for x in head.split(",") if x.strip())
                frames = []
                while i < len(lines) and not lines[i].startswith("]: "):
                    f = lines[i]
                    if f.startswith((" ", "\t")) and f.strip():
                        frames.append(f.strip())
                    elif f.strip():
                        self.notes.append(f.strip())
                    i += 1
                if i < len(lines):
                    self.stk[name].append((ints, frames, value(lines[i][3:].strip())))
                    i += 1
                continue
            self.notes.append(line)

    def get(self, name, *key, default=0):
        return self.v.get(name, {}).get(tuple(key), default)

    def total(self, name, *key):
        x = self.get(name, *key, default=None)
        return x["total"] if isinstance(x, dict) else (x or 0)

    def count(self, name, *key):
        x = self.get(name, *key, default=None)
        return x["count"] if isinstance(x, dict) else (x or 0)


def value(text):
    m = STATS.match(text)
    if m:
        return {"count": int(m.group(1)), "avg": int(m.group(2)), "total": int(m.group(3))}
    try:
        return int(text)
    except ValueError:
        return text


def fname(frame):
    return frame.split("+")[0]


def clean(frames):
    """Function names without the bpf frames and immediate repeats (a traced function shows twice around its
    trampoline)."""
    out = []
    for f in frames:
        n = fname(f)
        if n.startswith(("bpf_prog_", "bpf_trampoline_")) or n.startswith("0x"):
            continue
        if out and out[-1] == n:
            continue
        out.append(n)
    return out


def signature(frames, stop=COMMIT, depth=8):
    """The frames after finish_task_switch up to the first frame matching stop (not included), or depth frames."""
    names = clean(frames)
    if "finish_task_switch" in names:
        names = names[names.index("finish_task_switch") + 1:]
    out = []
    for n in names:
        if stop is not None and stop.match(n):
            break
        out.append(n)
    return " < ".join(out[:depth]) if out else "(none)"


def waited_on(state, names):
    if state in (0, 0x100):
        return "runnable"
    s = set(names)
    if s & {"wbt_wait", "rq_qos_wait", "__rq_qos_throttle"}:
        return "wbt"
    if "blk_mq_get_tag" in s:
        return "tags"
    if "folio_wait_writeback" in s:
        return "folio writeback"
    return "other"


def info(path):
    d = {}
    for line in path.read_text().splitlines():
        if line.startswith("exp="):
            d.update(kv.split("=", 1) for kv in line.split())
    return d


def csv_rows(rdir):
    rows = {}
    p = rdir / "results.csv"
    if p.exists():
        with p.open() as f:
            for r in csv.DictReader(f):
                rows[(r["config"], r["op"], int(r["threads"]), r["rep"])] = r
    return rows


def cells(rdir):
    """(config, op, T) -> (label, info, M3) for every .m3 of the run with syncs."""
    out = {}
    for m3 in sorted((rdir / "runs").glob("*.m3")):
        inf = info(m3.with_suffix(".info")) if m3.with_suffix(".info").exists() else {}
        out[(inf.get("config"), inf.get("op"), int(inf.get("threads", 0)))] = (m3.stem, inf, M3(m3))
    return out


def fnum(x, fmt="%.1f"):
    return "" if x is None else fmt % x


def pct(a, b):
    return None if not b else 100.0 * a / b


def md5(p):
    return hashlib.md5(p.read_bytes()).hexdigest()[:8] if p.exists() else "absent"


def cell_rows(rdir, ref, args):
    res, refres = csv_rows(rdir), csv_rows(ref)
    refcells = cells(ref)
    out = []
    for key, (label, inf, m) in sorted(cells(rdir).items(), key=lambda kv: (kv[0][0] or "", kv[0][1] or "", kv[0][2])):
        n = m.get("sync_n")
        if not n:
            out.append({"key": key, "label": label, "n": 0, "m": m})
            continue
        r = res.get(key + (inf.get("rep", "1"),), {})
        rr = refres.get(key + ("1",), {})
        rm = refcells.get(key, (None, None, None))[2]
        c = {"key": key, "label": label, "n": n, "m": m, "inf": inf, "csv": r}
        us = lambda ns: ns / n / 1000.0
        c["iops"] = float(r["write_iops"]) if r.get("write_iops") else None
        c["ref_iops"] = float(rr["write_iops"]) if rr.get("write_iops") else None
        c["d_iops"] = pct(c["iops"] - c["ref_iops"], c["ref_iops"]) if c["iops"] and c["ref_iops"] else None
        c["sync"] = us(m.get("sync_ns"))
        rn = rm.get("sync_n") if rm else 0
        c["ref_sync"] = rm.get("sync_ns") / rn / 1000.0 if rn else None
        c["ref_CT"] = rm.get("x", 7) / rn / 1000.0 if rn else None
        for b, nm in ((7, "CT"), (8, "JIO"), (9, "REC")):
            c[nm] = us(m.get("x", b))
            c[nm + "_off"] = us(m.total("oc_x", b))
            c[nm + "_rq"] = us(m.get("oc_r", b))
            c[nm + "_sw"] = m.count("oc_x", b) / n
        c["CT_on"] = c["CT"] - c["CT_off"]
        c["CT_sleep"] = c["CT_off"] - c["CT_rq"]
        c["insync_off"] = us(sum(m.total("oc_x", b) for b in range(11)))
        # sleep sites, per bucket
        st = defaultdict(list)
        for ints, frames, val in m.stk.get("oc_stk", []):
            b, s = ints[0], ints[1]
            rq = 0
            st[b].append({"state": s, "frames": frames, "names": clean(frames), "count": val["count"],
                          "total": val["total"], "rq": rq})
        rqmap = {(ints, tuple(fr)): val for ints, fr, val in m.stk.get("oc_stkr", [])}
        for b in st:
            for e in st[b]:
                e["rq"] = rqmap.get(((b, e["state"]), tuple(e["frames"])), 0)
        c["stacks"] = st
        ct = st.get(7, [])
        cls = defaultdict(int)
        for e in ct:
            cls["lost" if not e["frames"] else waited_on(e["state"], e["names"])] += e["total"]
        c["ct_by"] = cls
        c["ct_stack_sum"] = sum(e["total"] for e in ct)
        lost_all = sum(e["total"] for b in st for e in st[b] if not e["frames"])
        c["lost_n"] = sum(1 for b in st for e in st[b] if not e["frames"])
        c["lost_ns"] = lost_all
        c["lost_ct_pct"] = pct(cls.get("lost", 0), m.total("oc_x", 7))
        c["lost_insync_pct"] = pct(sum(e["total"] for b in range(11) for e in st.get(b, []) if not e["frames"]),
                                   sum(m.total("oc_x", b) for b in range(11)))
        c["ct_revoke_off"] = us(sum(e["total"] for e in ct
                                    if {"filemap_fdatawrite_wbc", "filemap_fdatawait_range"} & set(e["names"])))
        # the write path: outside syncs, stacks with __x64_sys_pwrite64
        fs = int(inf.get("fdatasync_n", 64) or 64)
        writes = n * fs
        out12 = st.get(12, [])
        pw = [e for e in out12 if "__x64_sys_pwrite64" in e["names"]]
        c["writes"] = writes
        c["w_off"] = sum(e["total"] for e in pw) / writes / 1000.0
        c["w_sw"] = sum(e["count"] for e in pw) / writes
        bysys = defaultdict(int)
        for e in out12:
            sysf = [x for x in e["names"] if x.startswith("__x64_sys_")]
            bysys[sysf[-1][len("__x64_sys_"):] if sysf else ("lost" if not e["frames"] else "no syscall")] += e["total"]
        c["out_by"] = bysys
        longs = [(ints, fr, val) for ints, fr, val in m.stk.get("oc_long", []) if ints[0] == 12]
        lmax = {tuple(fr): val for ints, fr, val in m.stk.get("oc_lmax", []) if ints[0] == 12}
        pwl = [(fr, val) for ints, fr, val in longs if "__x64_sys_pwrite64" in clean(fr)]
        c["w_long_n"] = sum(v["count"] for fr, v in pwl)
        c["w_long_per1k"] = c["w_long_n"] * 1024.0 / writes
        c["w_long_mean"] = (sum(v["total"] for fr, v in pwl) / c["w_long_n"] / 1000.0) if c["w_long_n"] else None
        c["w_long_max"] = max((lmax.get(tuple(fr), 0) for fr, v in pwl), default=0) / 1000.0 if pwl else None
        c["w_long"] = sorted(((v["total"], v["count"], lmax.get(tuple(fr), 0), fr) for fr, v in pwl), reverse=True)
        c["hist12"] = m.hist.get("oc_h", {}).get((12,), [])
        # tau commits and the revoke path
        for k in (1, 2, 3):
            c["rc%d" % k] = m.get("rc_n", k, 0) + m.get("rc_n", k, 1)
            c["rv%d" % k] = m.get("rc_n", k, 1)
            for s in (742, 1003):
                c["c%d_%d" % (s, k)] = m.get("rc_c", s, k)
                c["t%d_%d" % (s, k)] = m.total("rc_t", s, k)
                c["tn%d_%d" % (s, k)] = m.count("rc_t", s, k)
                c["mx%d_%d" % (s, k)] = m.get("rc_max", s, k)
        c["calls7"] = m.get("calls", 7)
        c["rv_pct3"] = pct(c["rv3"], c["rc3"])
        sites = m.stk.get("rc_wsite", [])
        c["wsites"] = sites
        c["wsite_bad"] = [fr for ints, fr, val in sites if not direct_742(fr)]
        # checks
        smp = lambda b: m.get("oc_smp", b) / HZ * 1e9            # ns on-CPU from samples
        c["chk"] = {}
        for nm, bs in (("CT", [7]), ("JIO", [8]), ("REC", [9]), ("in sync", list(range(11)))):
            der = sum(m.get("x", b) - m.total("oc_x", b) for b in bs)
            c["chk"][nm] = (sum(smp(b) for b in bs), der, pct(sum(smp(b) for b in bs), der))
        smp_all = sum(smp(b) for b in list(range(11)) + [12])
        cpu = float(r["cpu_proc_us_per_page"]) if r.get("cpu_proc_us_per_page") else None
        c["cpu_smp"] = smp_all / writes / 1000.0
        c["cpu_aw"] = cpu
        c["cpu_pct"] = pct(c["cpu_smp"], cpu) if cpu else None
        c["m3check"] = pct(sum(m.get("x", b) for b in range(11)), m.get("sync_ns"))
        c["anom"], c["nowake"], c["nest"] = m.get("oc_anom"), m.get("oc_nowake"), m.get("rc_nest")
        c["notes"] = m.notes
        out.append(c)
    return out


def direct_742(frames):
    """True if filemap_fdatawrite_wbc was called by the commit function itself. The kfunc stack lacks the direct
    caller, so the frame after filemap_fdatawrite_wbc+5 is the caller's caller; the commit function has kretfunc
    probes, so when it is the caller that frame is its own entry through the trampoline, tau_*_commit_transaction+5.
    A call from a function nested in the commit shows the commit's body there (+N, N != 5) instead."""
    fr = [f for f in frames if not fname(f).startswith(("bpf_prog_", "bpf_trampoline_"))]
    for i, f in enumerate(fr):
        if fname(f) == "filemap_fdatawrite_wbc":
            return i + 1 < len(fr) and COMMIT.match(fname(fr[i + 1])) is not None and fr[i + 1].endswith("+5")
    return False


def queue_check(path):
    """--queue: the PM1735 queue reads (blocks '== <tag> <time>' of 'path value' lines): all the same?"""
    blocks, cur = [], None
    for line in Path(path).read_text().splitlines():
        if line.startswith("== "):
            cur = [line[3:], []]
            blocks.append(cur)
        elif cur is not None and line.strip():
            cur[1].append(line.strip())
    if not blocks:
        return "no reads", False
    same = all(b[1] == blocks[0][1] for b in blocks)
    return "%d reads, %s" % (len(blocks), "all the same" if same else "DIFFERENT"), same


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rdir")
    ap.add_argument("--ref", required=True)
    ap.add_argument("--manifest")
    ap.add_argument("--queue")
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--cells", type=int, default=2)
    ap.add_argument("--max-lost-pct", type=float, default=0.0)
    a = ap.parse_args()
    rdir, ref = Path(a.rdir), Path(a.ref)
    rows = cell_rows(rdir, ref, a)
    md, stk = [], []
    P = md.append
    env = (rdir / "env.txt").read_text(errors="replace").splitlines() if (rdir / "env.txt").exists() else []
    P("# M3 CT split: on-CPU and off-CPU (m3_offcpu_report.py)")
    P("")
    P("- result: %s" % rdir)
    P("- reference (M3 tracer alone): %s" % ref)
    for line in env:
        if re.match(r"^kernel: \S", line):                    # run_fio.sh's own line, not machine_info's
            P("- %s" % line)
    P("- tracer: m3_phases.kernel.bt %s (M3 + off-CPU in one program), m3_offcpu_tau.bt %s; this report %s"
      % (md5(rdir / "m3_phases.kernel.bt"), md5(rdir / "m3_offcpu_tau.bt"), md5(Path(__file__))))
    if a.manifest and Path(a.manifest).exists():
        for line in Path(a.manifest).read_text(errors="replace").splitlines():
            if re.match(r"^(bzImage|config|harness|bpftrace|PM1735|  /sys/|  hw queues|  multipath)", line):
                P("- %s" % line.strip())
    if a.queue and Path(a.queue).exists():
        P("- PM1735 queue reads: %s" % queue_check(a.queue)[0])
    P("- Times are per fdatasync of the cell's window (M3's counted syncs), us. Off-CPU = switch-out to switch-in; the")
    P("  wait for a CPU (rq) is wakeup to switch-in. On-CPU = M3's exclusive phase time minus its off-CPU.")
    P("")
    P("## Run quality and the CT split (us per fdatasync)")
    P("")
    P("| config | op | T | IOPS | ref IOPS | dIOPS % | syncs | sync | ref sync | CT | ref CT | CT on | CT off | "
      "CT sleep | CT rq | JIO | JIO off | REC | REC off | sw/sync CT | sw/sync JIO | sw/sync REC | off in sync |")
    P("|---|---|---:|" + "---:|" * 20)
    for c in rows:
        if not c["n"]:
            P("| %s | %s | %d | no syncs |" % c["key"])
            continue
        P("| %s | %s | %d | " % c["key"] + " | ".join([
            fnum(c["iops"], "%.0f"), fnum(c["ref_iops"], "%.0f"), fnum(c["d_iops"], "%+.1f"), "%d" % c["n"],
            fnum(c["sync"]), fnum(c["ref_sync"]), fnum(c["CT"]), fnum(c["ref_CT"]), fnum(c["CT_on"]),
            fnum(c["CT_off"]), fnum(c["CT_sleep"]), fnum(c["CT_rq"]), fnum(c["JIO"]), fnum(c["JIO_off"]),
            fnum(c["REC"]), fnum(c["REC_off"]), fnum(c["CT_sw"], "%.2f"), fnum(c["JIO_sw"], "%.2f"),
            fnum(c["REC_sw"], "%.2f"), fnum(c["insync_off"])]) + " |")
    P("")
    P("## CT off-CPU by what it waited on (us per fdatasync; % of CT off-CPU)")
    P("")
    P("From the sleep sites: wbt (wbt_wait, rq_qos_wait or __rq_qos_throttle in the stack), tags (blk_mq_get_tag),")
    P("folio writeback (folio_wait_writeback), runnable (prev_state R or preempted), other; lost: no stack (a stack-map")
    P("collision). Stacks are taken at the switch-in.")
    P("")
    cl = ["wbt", "tags", "folio writeback", "runnable", "other", "lost"]
    P("| config | op | T | CT off | " + " | ".join(cl) + " | stacks - total, ns |")
    P("|---|---|---:|---:|" + "---|" * len(cl) + "---:|")
    for c in rows:
        if not c["n"]:
            continue
        off = c["m"].total("oc_x", 7)
        cells_ = ["%.1f (%.1f%%)" % (c["ct_by"].get(k, 0) / c["n"] / 1000.0, pct(c["ct_by"].get(k, 0), off) or 0)
                  for k in cl]
        P("| %s | %s | %d | %.1f | " % (c["key"] + (c["CT_off"],)) + " | ".join(cells_) +
          " | %d |" % (c["ct_stack_sum"] - off))
    P("")
    for b, nm, top in ((7, "CT", 6), (8, "JIO", 3), (9, "REC", 3)):
        P("## Top %s sleep sites (signature: the frames after finish_task_switch up to the tau commit)" % nm)
        P("")
        P("| config | op | T | signature | state | sum ms | %% of %s off | count | mean us | rq %% |" % nm)
        P("|---|---|---:|---|---|---:|---:|---:|---:|---:|")
        for c in rows:
            if not c["n"]:
                continue
            off = c["m"].total("oc_x", b)
            agg = defaultdict(lambda: [0, 0, 0])
            for e in c["stacks"].get(b, []):
                g = agg[(signature(e["frames"]) if e["frames"] else "(lost)", STATE.get(e["state"], hex(e["state"])))]
                g[0] += e["total"]; g[1] += e["count"]; g[2] += e["rq"]
            for (sig, s), (tot, cnt, rq) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:top]:
                P("| %s | %s | %d | %s | %s | %.1f | %.1f | %d | %.1f | %.0f |" % (c["key"] + (
                    sig, s, tot / 1e6, pct(tot, off) or 0, cnt, tot / cnt / 1000.0 if cnt else 0, pct(rq, tot) or 0)))
        P("")
    P("## Write path (outside syncs, stacks with __x64_sys_pwrite64)")
    P("")
    P("Writes = M3's syncs x the batch. The share of all off-CPU outside syncs by the syscall in the stack follows.")
    P("")
    P("| config | op | T | writes | off us/write | switches/write | >=10 ms per 1,024 writes | mean ms | max ms | "
      "outside syncs, by syscall (ms) |")
    P("|---|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for c in rows:
        if not c["n"]:
            continue
        by = ", ".join("%s %.0f" % (k, v / 1e6) for k, v in sorted(c["out_by"].items(), key=lambda kv: -kv[1]))
        P("| %s | %s | %d | %d | %.2f | %.3f | %.3f | %s | %s | %s |" % (c["key"] + (
            c["writes"], c["w_off"], c["w_sw"], c["w_long_per1k"], fnum(c["w_long_mean"] and c["w_long_mean"] / 1000,
            "%.1f"), fnum(c["w_long_max"] and c["w_long_max"] / 1000, "%.1f"), by)))
    P("")
    for c in rows:
        if not c["n"] or not (c["w_long"] or c["hist12"]):
            continue
        P("%s %s T%d, write path:" % c["key"])
        for tot, cnt, mx, fr in c["w_long"][:3]:
            P("- >=10 ms: %d, mean %.1f ms, max %.1f ms: %s" % (cnt, tot / cnt / 1e6, mx / 1e6,
                                                                signature(fr, re.compile(r"^__x64_sys_pwrite64$"), 10)))
        if c["hist12"]:
            P("- off-CPU intervals outside syncs (all of them, us): " +
              ", ".join("[%s, %s) %d" % h for h in c["hist12"] if h[2]))
        P("")
    P("## Tau commits and the revoke path (commit.c:742 and 1003)")
    P("")
    P("k3: in M3's CT (the process in a counted sync); k2: the process elsewhere; k1: other threads. rv: commits whose")
    P("transaction carried revoke blocks at entry (the test at 732). m3.md's commits column counts jbd2's, not these.")
    P("")
    P("| config | op | T | commits k3/k2/k1 | rv k3/k2/k1 | rv % of k3 | 742 calls k3/k2/k1 | 1003 calls k3/k2/k1 | "
      "742 mean/max us (k3) | 1003 mean/max us (k3) | 742 us/sync | 1003 us/sync | CT | CT off in 742/1003 |")
    P("|---|---|---:|---|---|---:|---|---|---|---|---:|---:|---:|---:|")
    for c in rows:
        if not c["n"]:
            continue
        mm = lambda s: "%s / %s" % (fnum(c["t%d_3" % s] / c["tn%d_3" % s] / 1000.0 if c["tn%d_3" % s] else None),
                                     fnum(c["mx%d_3" % s] / 1000.0 if c["tn%d_3" % s] else None))
        P("| %s | %s | %d | " % c["key"] + " | ".join([
            "%d / %d / %d" % (c["rc3"], c["rc2"], c["rc1"]), "%d / %d / %d" % (c["rv3"], c["rv2"], c["rv1"]),
            fnum(c["rv_pct3"]), "%d / %d / %d" % (c["c742_3"], c["c742_2"], c["c742_1"]),
            "%d / %d / %d" % (c["c1003_3"], c["c1003_2"], c["c1003_1"]), mm(742), mm(1003),
            fnum(c["t742_3"] / c["n"] / 1000.0), fnum(c["t1003_3"] / c["n"] / 1000.0), fnum(c["CT"]),
            fnum(c["ct_revoke_off"])]) + " |")
    P("")
    P("## Checks (plan section 5)")
    P("")
    P("1. Sampled on-CPU (profile, %d Hz) against derived on-CPU (M3 phase time minus off-CPU), ms; check = sampled /"
      % HZ)
    P("   derived, %. 2. Missed events. 3. Sampled CPU of the process against its getrusage (results.csv), us per page.")
    P("4. M3's check (its phases over the sync time). 5. Revoke counts: per class the rv commits and the 742 and 1003")
    P("   calls agree within %d (in flight at the end); k3 commits within %d of M3's @calls[7]; each 742 call site is the" % (TOL, TOL))
    P("   commit itself; no nested commit.")
    P("")
    P("| config | op | T | CT smp/der ms (%) | JIO | REC | in sync | anom | nowake | lost stacks n, ms (% CT off, "
      "% in-sync off) | errors | CPU smp/aw us/page (%) | M3 check | rv/742/1003 k3, k2, k1 | k3 - calls[7] | "
      "742 sites ok | nest |")
    P("|---|---|---:|" + "---|" * 14)
    gate = []
    for c in rows:
        if not c["n"]:
            gate.append((c["key"], False, "no syncs"))
            continue
        ch = lambda nm: "%.0f / %.0f (%s)" % (c["chk"][nm][0] / 1e6, c["chk"][nm][1] / 1e6, fnum(c["chk"][nm][2]))
        rv = " , ".join("%d/%d/%d" % (c["rv%d" % k], c["c742_%d" % k], c["c1003_%d" % k]) for k in (3, 2, 1))
        bad = len(c["wsite_bad"])
        P("| %s | %s | %d | " % c["key"] + " | ".join([
            ch("CT"), ch("JIO"), ch("REC"), ch("in sync"), str(c["anom"]), str(c["nowake"]),
            "%d, %.1f (%s, %s)" % (c["lost_n"], c["lost_ns"] / 1e6, fnum(c["lost_ct_pct"], "%.2f"),
                                   fnum(c["lost_insync_pct"], "%.2f")),
            str(len(c["notes"])), "%s / %s (%s)" % (fnum(c["cpu_smp"], "%.2f"), fnum(c["cpu_aw"], "%.2f"),
                                                    fnum(c["cpu_pct"])),
            fnum(c["m3check"]), rv, "%+d" % (c["rc3"] - c["calls7"]),
            "%d of %d" % (len(c["wsites"]) - bad, len(c["wsites"])), str(c["nest"])]) + " |")
        why = []
        need = {"oc_x", "oc_smp", "rc_n"} - set(k for k in c["m"].v if c["m"].v[k])
        if need:
            why.append("maps absent: %s" % " ".join(sorted(need)))
        if c["anom"]:
            why.append("@oc_anom %d" % c["anom"])
        if a.max_lost_pct <= 0 and c["lost_n"]:
            why.append("lost stacks %d" % c["lost_n"])
        elif (c["lost_ct_pct"] or 0) > a.max_lost_pct:
            why.append("lost stacks %.2f%% of CT off-CPU" % c["lost_ct_pct"])
        cp = c["chk"]["CT"][2]
        if cp is None or not 90.0 <= cp <= 110.0:
            why.append("CT sampled/derived %s%%" % fnum(cp))
        if c["d_iops"] is None or c["d_iops"] < -10.0:
            why.append("IOPS %s%% of the reference" % fnum(100 + c["d_iops"] if c["d_iops"] is not None else None))
        for k in (3, 2, 1):
            x = (c["rv%d" % k], c["c742_%d" % k], c["c1003_%d" % k])
            if max(x) - min(x) > TOL:
                why.append("k%d rv/742/1003 %d/%d/%d" % ((k,) + x))
        if abs(c["rc3"] - c["calls7"]) > TOL:
            why.append("k3 %d vs @calls[7] %d" % (c["rc3"], c["calls7"]))
        if bad:
            why.append("%d 742 call sites not the commit" % bad)
        if c["nest"]:
            why.append("@rc_nest %d" % c["nest"])
        gate.append((c["key"], not why, "; ".join(why) or "ok"))
    P("")
    if a.queue and Path(a.queue).exists():
        txt, same = queue_check(a.queue)
        P("6. PM1735 queue settings read before and after the steps: %s." % txt)
        P("")
    notes = [(c["key"], c["notes"]) for c in rows if c.get("notes")]
    if notes:
        P("Lines of the tracer output that are not maps (errors, warnings):")
        for k, ns in notes:
            P("- %s %s T%d: %d, first: %s" % (k + (len(ns), ns[0][:160])))
        P("")
    if a.gate:
        if sum(1 for c in rows if c["n"]) != a.cells:
            gate.append((("all", "cells", 0), False, "%d cells with syncs, expected %d"
                         % (sum(1 for c in rows if c["n"]), a.cells)))
        ok = all(g[1] for g in gate)
        P("## Gate (m3ct_check): %s" % ("PASS" if ok else "FAIL"))
        P("")
        P("Both cells: the new maps present, @oc_anom 0, %s, CT sampled/derived 90-110%%, IOPS at least 90%% of the "
          "reference, check 5." % ("no lost stack" if a.max_lost_pct <= 0 else
                                   "lost stacks at most %.2f%% of CT off-CPU" % a.max_lost_pct))
        P("")
        for k, g, why in gate:
            P("- %s %s T%d: %s (%s)" % (k + ("pass" if g else "FAIL", why)))
        P("")
    # full stacks
    for c in rows:
        if not c["n"]:
            continue
        stk.append("#### %s %s T%d (%s): %d syncs" % (c["key"] + (c["label"], c["n"])))
        for b in sorted(c["stacks"]):
            off = c["m"].total("oc_x", b)
            stk.append("### bucket %d %s: off-CPU %.1f ms in %d intervals" % (b, PHASE.get(b, "?"), off / 1e6,
                                                                              c["m"].count("oc_x", b)))
            for e in sorted(c["stacks"][b], key=lambda e: -e["total"]):
                stk.append("-- %.3f ms (%.2f%%), %d, mean %.1f us, state %s, rq %.3f ms" % (
                    e["total"] / 1e6, pct(e["total"], off) or 0, e["count"], e["total"] / e["count"] / 1000.0
                    if e["count"] else 0, STATE.get(e["state"], hex(e["state"])), e["rq"] / 1e6))
                stk.extend("    " + f for f in e["frames"]) if e["frames"] else stk.append("    (lost)")
        stk.append("### 742 call sites (kstack(8) at filemap_fdatawrite_wbc)")
        for ints, fr, val in c["wsites"]:
            stk.append("-- %s calls, %s" % (val, "the commit itself" if direct_742(fr) else "NOT the commit"))
            stk.extend("    " + f for f in fr)
        stk.append("")
    (rdir / "m3ct.md").write_text("\n".join(md) + "\n")
    (rdir / "m3ct_stacks.txt").write_text("\n".join(stk) + "\n")
    print("\n".join(md))
    if a.gate and not ok:
        sys.exit(2)


if __name__ == "__main__":
    main()
