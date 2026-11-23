#!/usr/bin/env python3
"""EVAL_PLAN M3 at one thread: where the fdatasync's CPU goes (final_tau/full/PLAN_m3cpu_t1.md). Tables from
run_fio.sh result directories:
  CPU pass   M3_TRACE=1 M3_CPU=1 M3_PERF=1: M3 + m3_cpu.bt in one bpftrace, and perf record on the tool
  I/O pass   M3_TRACE=1 M3_IO=1: M3 + m3_io.bt (counts only)
  untraced   no tracer: the burden reference
Per run of the CPU pass, from runs/<label>.m3, .tl, .info, results.csv, <label>.perf.txt.gz (the wrapper's
`perf script -F comm,tid,time,ip,sym --ns`) and <label>.perf.stats (`perf report --stats`):
  - M3's phases (µs per fdatasync) and, from m3_cpu.bt, each phase's off-CPU; on-CPU = M3's time minus off-CPU;
  - perf's kernel samples in the counted window [@cp_on, @cp_end], each put in a phase by the plan's frame rules
    (section 4a: the innermost phase function on the stack, as M3's nested phases) and in one of the plan's 16
    groups (the first group that matches, walking from the leaf up; the plan's patterns, as globs);
  - µs per fdatasync of a group or a function = its share of the phase's perf samples x the phase's on-CPU µs
    (all in-sync time: its share of all in-sync samples x all in-sync on-CPU);
  - the tracer's IOPS burden from atomicw's timelines (pages per second).
A cell is the median of its runs, with the range; every run has its own rows too.

Usage: m3_cpu_report.py <CPU pass dir>... [--ref <dir>...] [--notrace <dir>...] [--io <dir>...] [--pathdev MAJ:MIN]
         [--manifest <file>...] [--host <file>...] [--ksyms <file>...] [-o <md>] [--folded <dir>]
         [--gate [--min-burden B]]
  --ref: M3-only runs, the burden's reference (the first run of a cell is used); --host: the wrapper's host sampler
  files (the one of the run's kernel is used); --pathdev: the PM1735 path's dev (/proc/diskstats); --ksyms: the
  wrapper's snapshot of a boot's /proc/modules and module kallsyms (logs/ksyms_<part>.txt; the one of the run's
  kernel is used) to name the module frames perf left unresolved;
  --gate: the check step's gate (plan section 6) on the one run given; exit status 2 if it fails.
"""
import argparse
import bisect
import csv
import fnmatch
import gzip
import hashlib
import re
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

HZ = 999
SLICE_S = 5
PHASES = {0: "other", 1: "D", 2: "JC", 3: "LF", 4: "FL", 5: "TW", 6: "TI", 7: "CT", 8: "JIO+REC", 10: "DUR",
          12: "out"}
INSYNC = [0, 1, 2, 3, 4, 5, 6, 7, 8, 10]          # M3's buckets in a counted sync; its 9 (REC) is in 8 here
# The plan's frame rules (section 4a): the phase functions; the innermost one on the stack decides, as M3's nested
# phases do, and __wait_on_buffer counts only under the tau commit (M3: @inct). The plan has no rule for TI
# (tau_wait_inflight): by the rules its samples are TW's (or CT's), so the checks set perf's TW against bpftrace's
# TW + TI.
PHASE_FN = {"file_write_and_wait_range": 1, "jbd2_log_wait_commit": 2, "xfs_log_force_seq": 3,
            "blkdev_issue_flush": 4, "ext4_tau_commit": 5, "xfs_tau_commit": 5, "tau_bh_commit_transaction": 7,
            "tau_io_commit_transaction": 7, "__wait_on_buffer": 8, "ext4_tau_commit_durable": 10,
            "xfs_tau_commit_durable": 10}
COMMIT = {"tau_bh_commit_transaction", "tau_io_commit_transaction"}
# The plan's 16 groups (section 4a), its patterns as written (globs); the first group that matches, from the leaf
# up; 16 is "other".
GROUP_PATS = [
    ("IRQ and softirq", "asm_common_interrupt common_interrupt sysvec_* __do_softirq irq_exit_rcu"),
    ("memcpy and memset", "memcpy* __memcpy* memset* copy_*_user* memcpy_from_folio"),
    ("checksum", "crc32c* *_csum*"),
    ("memory", "kmem_cache_* kmalloc* kfree mempool_* alloc_buffer_head free_buffer_head __alloc_pages* folio_alloc*"),
    ("locks", "_raw_spin_* queued_spin_lock_slowpath mutex_* rwsem_* down_* up_*"),
    ("nvme", "nvme_*"),
    ("blk-mq, plug and merge", "blk_mq_* blk_*plug* blk_attempt_*merge* bio_attempt_*merge* __blk_*"),
    ("bio and submit", "bio_alloc* bio_init bio_put submit_bio* submit_bh* bio_add_*"),
    ("page cache and writeback", "filemap_* xa_* folio_* write_cache_pages *_writepages ext4_bio_write_folio "
                                 "mpage_* iomap_do_writepage iomap_submit_ioend*"),
    ("buffer heads", "*buffer* bh_* mark_buffer_* folio_set_bh"),
    ("τ journal", "tau_*"),
    ("jbd2", "jbd2_*"),
    ("XFS log", "xlog_* xfs_log_*"),
    ("file system, other", "ext4_* xfs_* iomap_*"),
    ("scheduler", "schedule* __cond_resched preempt_*"),
]
GROUPS = [(n, [re.compile(fnmatch.translate(p)) for p in pats.split()]) for n, pats in GROUP_PATS]
GROUP_NAMES = [n for n, _ in GROUPS] + ["other"]
# Not a group: samples with the tracer's own frames. They stay in their groups; the tables show their part apart.
#  - named: the trampoline's entry and exit, the hooks that run the programs (tracepoints, the profile's perf
#    event), perf's PMU switching when the traced thread is switched in or out;
#  - BPF code: perf record -p does not see the programs bpftrace loads after it starts, so their frames and the
#    trampolines' are unresolved. perf also leaves the frames of compressed modules (nvme, nvme_core: .ko.zst on
#    v1.1) unresolved; perf_samples() names those from the boot's snapshot (Ksyms) and names an unresolved frame in
#    the module area that is in no module "[bpf]" (without a snapshot: every unresolved module-area frame).
#    A function with a kretfunc runs under its trampoline: the frames read trampoline, then the function's entry
#    (+5) above it; the frame-pointer walk loses the function's caller there, and a frameless or shrink-wrapped
#    callee loses the function's body too. So a BPF frame is a wrapping trampoline, not the tracer's own code, if
#    the frame above it is a function the run's tracer wraps with a kretfunc (m3_phases.kernel.bt), or the same
#    function as below it; unless it is the leaf, the frame above it is also BPF (a program under its trampoline),
#    or the frame below it is a BPF helper (a program's frame lost).
TRACER = re.compile(r"^(bpf_prog_|__bpf_prog_enter|__bpf_prog_exit|trace_call_bpf$|bpf_trace_run|__bpf_trace_|"
                    r"perf_trace_run_bpf_submit$|bpf_overflow_handler$|perf_swevent_hrtimer$|"
                    r"__perf_event_task_sched_(in|out)$)")
BPF_FRAME = "[bpf]"
MODULES_VADDR = 0xffffffffa0000000                   # x86-64: modules and BPF JIT images from here up
# What BPF programs call (maps, time, stacks): a sample in one of them whose program frame was lost (a frameless or
# shrink-wrapped fast path keeps the caller's frame pointer) shows it right under a trampoline.
BPF_HELPER = re.compile(r"^(bpf_|__bpf_|htab_|__htab_|lookup_nulls_elem_raw|lookup_elem_raw|pcpu_freelist|"
                        r"alloc_htab_elem|free_htab_elem|percpu_array_|array_map_|stack_map_|get_perf_callchain|"
                        r"perf_callchain|ktime_get_mono_fast_ns|ktime_get_boot_fast_ns|jhash)")
# The plan's named functions (section 4a), inclusive; τ's write_buffer is a static function inlined into the commit
# (not in kallsyms), so it is in the commit's self samples (SELF).
NAMED = ["submit_bh", "submit_bio_noacct", "blk_mq_submit_bio", "blk_mq_flush_plug_list", "nvme_queue_rqs",
         "nvme_queue_rq", "tau_bh_commit_transaction", "tau_io_commit_transaction", "alloc_buffer_head",
         "ext4_bio_write_folio", "iomap_do_writepage", "write_cache_pages", "filemap_get_folios_tag"]
SELF = "tau_*_commit_transaction, self (its own code and inlined helpers, write_buffer among them)"
_group_cache, _tracer_cache = {}, {}


def group_index(fn):
    g = _group_cache.get(fn, -1)
    if g == -1:
        g = next((i for i, (_, rxs) in enumerate(GROUPS) if any(rx.match(fn) for rx in rxs)), None)
        _group_cache[fn] = g
    return g


def is_tracer_fn(fn):
    t = _tracer_cache.get(fn)
    if t is None:
        t = _tracer_cache[fn] = TRACER.match(fn) is not None
    return t


def group_of(frames):
    for f in frames:
        g = group_index(f)
        if g is not None:
            return GROUP_NAMES[g]
    return "other"


def is_bpf(f):
    return f == BPF_FRAME or f.startswith("bpf_trampoline_")


def running_bpf(frames, i, kret):
    """True if the BPF frame frames[i] is the tracer's own code running, False if it is a wrapping trampoline."""
    if i == 0 or i + 1 >= len(frames):
        return True
    up, down = frames[i + 1], frames[i - 1]
    if is_bpf(up) or BPF_HELPER.match(down):
        return True
    return not (up == down or up in kret)


def tracer_frames(frames, kret=frozenset()):
    for i, f in enumerate(frames):
        if is_tracer_fn(f):
            return True
        if is_bpf(f) and running_bpf(frames, i, kret):
            return True
    return False


def tracer_site(frames, kret=frozenset()):
    """Which probe a tracer sample belongs to: the traced function above the BPF frames (kfunc, kretfunc), a
    tracepoint, the profile, or perf's own switching."""
    for i, f in enumerate(frames):
        if f.startswith("__perf_event_task_sched"):
            return "perf: task switch"
        if f.startswith("__bpf_trace_"):
            return "tracepoint " + f[len("__bpf_trace_"):]
        if f in ("bpf_overflow_handler", "perf_swevent_hrtimer"):
            return "profile"
        if is_bpf(f) or f.startswith(("bpf_prog_", "__bpf_prog_")):
            if not is_bpf(f) and not f.startswith("bpf_prog_"):
                continue
            if is_bpf(f) and not running_bpf(frames, i, kret):
                continue                              # a wrapping trampoline
            j = i + 1
            while j < len(frames) and (is_bpf(frames[j]) or frames[j].startswith("bpf_prog_")):
                j += 1
            if j < len(frames):
                if frames[j].startswith("__bpf_trace_"):
                    return "tracepoint " + frames[j][len("__bpf_trace_"):]
                if frames[j] == "bpf_overflow_handler":
                    return "profile"
                return "k(ret)func " + frames[j]
            return "BPF, no caller"
    return "trampoline entry/exit"



def phase_of(frames):
    """The plan's frame rules: 12 without a vfs_fsync_range frame; else the innermost phase function; else 0."""
    if "vfs_fsync_range" not in frames:
        return 12
    under_commit = None
    for f in frames:                                  # leaf first
        b = PHASE_FN.get(f)
        if b is None:
            continue
        if b == 8:
            if under_commit is None:
                under_commit = any(x in COMMIT for x in frames)
            if not under_commit:
                continue
        return b
    return 0


# ---------------------------------------------------------------- bpftrace output

STATS = re.compile(r"^count (\d+), average (-?\d+), total (-?\d+)$")
HIST = re.compile(r"^\[(\S+?)(?:, (\S+?))?[\])]\s+(\d+) \|")


def key_of(text):
    out = []
    for x in text.split(","):
        x = x.strip()
        if x == "":
            continue
        try:
            out.append(int(x))
        except ValueError:
            out.append(x)
    return tuple(out)


def value_of(text):
    m = STATS.match(text)
    if m:
        return {"count": int(m.group(1)), "total": int(m.group(3))}
    try:
        return int(text)
    except ValueError:
        return text


class Trace:
    """A tracer output: maps (name -> key tuple -> value), stack-keyed maps (name -> [(key, frames, value)]),
    histograms, window lines and other lines."""

    def __init__(self, path):
        self.v = defaultdict(dict)
        self.stk = defaultdict(list)
        self.hist = defaultdict(dict)
        self.notes = []
        self.wbegin = self.wend = None
        lines = path.read_text(errors="replace").splitlines() if path.exists() else []
        i = 0
        while i < len(lines):
            line = lines[i]
            i += 1
            if line.startswith("window_begin_ns "):
                self.wbegin = int(line.split()[1])
                continue
            if line.startswith("window_end_ns "):
                self.wend = int(line.split()[1])
                continue
            if not line.startswith("@"):
                if line.strip() and not line.startswith(("Attaching", "[")):
                    self.notes.append(line.strip())
                continue
            m = re.match(r"^@(\w+)\[([^\]]*)\]:\s?(.*)$", line) or re.match(r"^@(\w+):\s?(.*)$", line)
            if m:
                name = m.group(1)
                key = key_of(m.group(2)) if m.lastindex == 3 else ()
                text = m.group(m.lastindex).strip()
                if text == "":
                    rows = []
                    while i < len(lines) and HIST.match(lines[i]):
                        h = HIST.match(lines[i])
                        rows.append((h.group(1), h.group(2) or h.group(1), int(h.group(3))))
                        i += 1
                    self.hist[name][key] = rows
                else:
                    self.v[name][key] = value_of(text)
                continue
            m = re.match(r"^@(\w+)\[(.*)$", line)
            if m:                                    # a key ending in a stack
                name, head = m.group(1), m.group(2)
                frames = []
                while i < len(lines) and not lines[i].startswith("]: "):
                    if lines[i].startswith((" ", "\t")) and lines[i].strip():
                        frames.append(lines[i].strip())
                    i += 1
                if i < len(lines):
                    self.stk[name].append((key_of(head), frames, value_of(lines[i][3:].strip())))
                    i += 1

    def get(self, name, *key, default=0):
        return self.v.get(name, {}).get(tuple(key), default)

    def total(self, name, *key):
        x = self.get(name, *key, default=None)
        return x["total"] if isinstance(x, dict) else (x or 0)

    def count(self, name, *key):
        x = self.get(name, *key, default=None)
        return x["count"] if isinstance(x, dict) else (x or 0)


# ---------------------------------------------------------------- perf script output

def perf_samples(path, ksyms=None):
    """(time ns, [kernel function names, leaf first]) per sample of a `perf script -F comm,tid,time,ip,sym --ns`
    output (gzip or text). ksyms (Ksyms of the run's boot) names unresolved frames in modules."""
    if not path.exists():
        return
    op = gzip.open if path.suffix == ".gz" else open
    t, frames = None, []
    strip = re.compile(r"(\.(isra|constprop|part|cold|lto_priv|llvm)\.?\d*)+$")
    with op(path, "rt", errors="replace") as f:
        for line in f:
            if not line.strip():
                if t is not None:
                    yield t, frames
                t, frames = None, []
                continue
            if line[0] not in " \t":
                if t is not None:
                    yield t, frames
                m = re.search(r"\s(\d+)\.(\d{9}):", line)
                t, frames = (int(m.group(1)) * 1_000_000_000 + int(m.group(2))) if m else None, []
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("ffff"):      # kernel frames only
                fn = strip.sub("", parts[1].split("+")[0])
                if fn == "[unknown]" and int(parts[0], 16) >= MODULES_VADDR:
                    nm = ksyms.name(int(parts[0], 16)) if ksyms else None
                    fn = strip.sub("", nm) if nm else BPF_FRAME
                frames.append(fn)
    if t is not None:
        yield t, frames


def perf_lost(rdir, label):
    """Lost records: perf report --stats (LOST, LOST_SAMPLES), and 'lost' in perf record's log or perf script's
    stderr. None if the stats are missing or not perf's."""
    st = rdir / "runs" / (label + ".perf.stats")
    if not st.exists() or "TOTAL events:" not in st.read_text(errors="replace"):
        return None
    n = sum(int(m.group(1)) for m in re.finditer(r"LOST(?:_SAMPLES)? events:\s+(\d+)", st.read_text(errors="replace")))
    for ext in (".perf.log", ".perf.script.err"):
        p = rdir / "runs" / (label + ext)
        if p.exists() and re.search(r"(?i)\blost\b", p.read_text(errors="replace")):
            n = max(n, 1)
    return n


# ---------------------------------------------------------------- runs

def info(path):
    d = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if line.startswith("exp="):
                d.update(kv.split("=", 1) for kv in line.split())
            elif "=" in line:
                k, v = line.split("=", 1)
                d[k] = v
    return d


def timeline(path):
    warm, v = None, {}
    if path.exists():
        for line in path.read_text().splitlines():
            if line.startswith("#"):
                m = re.search(r"warm-up (\d+) s", line)
                warm = int(m.group(1)) if m else warm
            elif len(line.split()) == 2:
                a, b = line.split()
                v[int(a)] = int(b)
    return warm, v


def mean_of(v, secs):
    xs = [v[s] for s in secs if s in v]
    return sum(xs) / len(xs) if xs else None


def csv_rows(rdir):
    rows = {}
    p = rdir / "results.csv"
    if p.exists():
        with p.open() as f:
            for r in csv.DictReader(f):
                rows[(r["config"], r["op"], int(r["threads"]), r["rep"])] = r
    return rows


def md5(p):
    return hashlib.md5(p.read_bytes()).hexdigest()[:8] if p.exists() else "absent"


def fnum(r, k):
    try:
        return float(r[k]) if r.get(k) not in (None, "") else None
    except ValueError:
        return None


class Ksyms:
    """The wrapper's snapshot of one boot's modules (logs/ksyms_<part>.txt): '# kernel K ...', /proc/modules lines
    ('name size refs deps state 0xbase') and the modules' /proc/kallsyms lines ('addr type name [module]'). It names
    an address inside a module; an address in no module is not named (BPF code: programs and trampolines are gone
    after the run)."""

    def __init__(self, path):
        self.kernel, self.mods, self.syms, self.path = None, [], defaultdict(list), path
        for line in Path(path).read_text(errors="replace").splitlines():
            if line.startswith("#"):
                m = re.search(r"kernel (\S+?);", line)
                self.kernel = m.group(1) if m else self.kernel
                continue
            q = line.split()
            m = re.search(r"\s0x([0-9a-f]{16})\b", line)
            if m and len(q) >= 6 and not re.match(r"^[0-9a-f]{16}$", q[0]):
                base = int(m.group(1), 16)
                self.mods.append((base, base + int(q[1]), q[0]))
            elif len(q) >= 4 and re.match(r"^[0-9a-f]{16}$", q[0]) and q[3].startswith("["):
                self.syms[q[3].strip("[]")].append((int(q[0], 16), q[2]))
        for v in self.syms.values():
            v.sort()

    def name(self, addr):
        for lo, hi, mod in self.mods:
            if lo <= addr < hi:
                v = self.syms.get(mod, [])
                i = bisect.bisect_right(v, (addr, "\uffff")) - 1
                return v[i][1] if i >= 0 else "[%s]" % mod
        return None


class Host:
    """The wrapper's host sampler: '# host sampler ...: kernel K; boottime-monotonic offset N ns' and then a line a
    second: '<realtime> up=<s> MemFree:<kB> ... pgscan_kswapd=N ... psi_cpu=.. psi_mem=.. psi_io=.. path_stat=..'."""

    def __init__(self, path):
        self.kernel, self.off, self.rows, self.node_of = None, 0, [], {}
        for line in Path(path).read_text(errors="replace").splitlines():
            if line.startswith("#"):
                m = re.search(r"kernel (\S+?);.*offset (-?\d+)", line)
                if m:
                    self.kernel, self.off = m.group(1), int(m.group(2))
                for n, lst in re.findall(r"node(\d+) ([\d,-]+)", line) if line.startswith("# nodes:") else []:
                    for part in filter(None, lst.split(",")):
                        a, _, b = part.partition("-")
                        for c in range(int(a), int(b or a) + 1):
                            self.node_of[c] = int(n)
                continue
            m = re.search(r"\bup=([\d.]+)", line)
            if not m:
                continue
            d = {"line": line, "up": float(m.group(1)), "f": dict(re.findall(r"(\w+)[:=](\S+)", line))}
            ps = re.search(r"path_stat=(.*)$", line)
            d["stat"] = [int(x) for x in ps.group(1).split()] if ps else []
            # CLOCK_MONOTONIC of the line: mono= (m3cpu_sampler.py), else uptime (BOOTTIME) minus the offset
            d["mono"] = int(d["f"]["mono"]) if d["f"].get("mono", "").isdigit() else int(d["up"] * 1e9) - self.off
            aw = d["f"].get("aw", "-")
            d["aw"] = [tuple(x.split(":")) for x in aw.split(";")] if aw not in ("-", "") else []
            self.rows.append(d)

    def at(self, mono_ns):
        """The row nearest a CLOCK_MONOTONIC time."""
        if not self.rows:
            return None
        return min(self.rows, key=lambda d: abs(d["mono"] - mono_ns))


class Run:
    """One run of the CPU pass."""

    def __init__(self, rdir, m3path, csvrows, ref_tl=None, ksyms_of=None):
        self.dir, self.label = rdir, m3path.stem
        self.inf = info(m3path.with_suffix(".info"))
        self.key = (self.inf.get("config"), self.inf.get("op"), int(self.inf.get("threads", 0) or 0))
        self.rep = self.inf.get("rep", "1")
        self.fs = int(self.inf.get("fdatasync_n", 64) or 64)
        self.csv = csvrows.get(self.key + (self.rep,), {})
        self.tr = tr = Trace(m3path)
        self.n = tr.get("sync_n")
        self.on, self.end = tr.get("cp_on"), tr.get("cp_end")
        self.tau = (self.key[0] or "").startswith("tau-")
        self.target = 7 if self.tau else 1
        self.warm, self.tl = timeline(m3path.with_suffix(".tl"))
        self.ok = bool(self.n)
        if not self.ok:
            return
        n = self.n
        self.ph = {}                                   # bucket -> (M3 time, off, wait for a CPU, switches) per sync
        for b in INSYNC + [12]:
            bs = [8, 9] if b == 8 else [b]
            x = None if b == 12 else sum(tr.get("x", c) for c in bs)
            off = sum(tr.total("cp_x", c) for c in bs)
            rq = sum(tr.get("cp_r", c) for c in bs)
            sw = sum(tr.count("cp_x", c) for c in bs)
            self.ph[b] = (None if x is None else x / n / 1000, off / n / 1000, rq / n / 1000, sw / n)
        self.sync = tr.get("sync_ns") / n / 1000
        self.check = 100.0 * sum(tr.get("x", b) for b in range(11)) / tr.get("sync_ns") if tr.get("sync_ns") else None
        self.smp = {b: tr.get("cp_smp", b) + (tr.get("cp_smp", 9) if b == 8 else 0) for b in INSYNC + [12]}
        self.counted_s = (self.end - self.on) / 1e9 if self.on and self.end and self.end > self.on else None
        # atomicw's seconds against CLOCK_MONOTONIC: @cp_end (the first thread's exit) is the timeline's end
        self.end_sec = None
        if self.tl:
            last = max(self.tl)
            self.end_sec = last + (self.tl[last] / self.tl[last - 1] if self.tl.get(last - 1) else 0)
        self.cnt_secs = []
        if self.tl and self.counted_s and self.end_sec is not None:
            first = int(self.end_sec - self.counted_s) + 1
            self.cnt_secs = [s for s in range(first, int(self.end_sec)) if s in self.tl]
        # perf
        self.perf = Counter()                          # (bucket, group) -> samples
        self.trc = Counter()                           # bucket -> samples with tracer frames
        self.trc_g = Counter()                         # (bucket, group) -> of them
        self.trc_site = defaultdict(Counter)           # bucket -> probe site -> of them
        self.leaf = defaultdict(Counter)               # bucket -> leaf function -> samples
        self.incl = defaultdict(Counter)               # bucket -> named function -> samples
        self.selfc = Counter()                         # bucket -> samples with the commit as the leaf
        self.sl_perf = defaultdict(Counter)            # 5-s slice -> bucket -> samples
        self.sl_grp = defaultdict(Counter)             # 5-s slice -> group -> in-sync samples
        self.sec_perf = defaultdict(Counter)           # atomicw second -> group -> in-sync samples
        self.folded = defaultdict(Counter)             # bucket -> "root;...;leaf" -> samples
        self.perf_in = self.perf_out = 0
        pt = rdir / "runs" / (self.label + ".perf.txt.gz")
        self.has_perf = pt.exists()
        self.ksyms = ksyms_of(self.inf.get("kernel")) if ksyms_of else None
        tb = rdir / "m3_phases.kernel.bt"               # the functions the run's tracer wraps with a kretfunc
        self.kret = frozenset(re.findall(r"^kretfunc:[\w.]+:(\w+)", tb.read_text(), re.M)) if tb.exists() else frozenset()
        for t, frames in perf_samples(pt, self.ksyms):
            if not frames:
                continue
            if not (self.on and self.end and self.on <= t <= self.end):
                self.perf_out += 1
                continue
            self.perf_in += 1
            b = phase_of(frames)
            g = group_of(frames)
            self.perf[(b, g)] += 1
            if tracer_frames(frames, self.kret):
                self.trc[b] += 1
                self.trc_g[(b, g)] += 1
                self.trc_site[b][tracer_site(frames, self.kret)] += 1
            self.leaf[b][frames[0]] += 1
            if frames[0] in COMMIT:
                self.selfc[b] += 1
            for f in set(frames):
                if f in NAMED:
                    self.incl[b][f] += 1
            self.folded[b][";".join(reversed(frames))] += 1
            k = (t - self.on) // (SLICE_S * 1_000_000_000)
            self.sl_perf[k][b] += 1
            if b != 12:
                self.sl_grp[k][g] += 1
                if self.end_sec is not None:
                    self.sec_perf[int(self.end_sec - (self.end - t) / 1e9)][g] += 1
        self.perf_lost = perf_lost(rdir, self.label)
        # the tracer's IOPS burden: counted / before, and against the reference run
        self.before = self.counted = self.burden = None
        if self.cnt_secs:
            if (self.warm or 0) >= 10:
                self.before = mean_of(self.tl, range(2, 10))
            self.counted = mean_of(self.tl, self.cnt_secs)
            self.burden = burden(self, ref_tl)
        # slow seconds (plan 4c)
        self.slow = []
        if self.cnt_secs:
            ref = [self.tl[s] for s in range(2, 10) if s in self.tl] if (self.warm or 0) >= 10 \
                else [self.tl[s] for s in self.cnt_secs[:10]]
            base = statistics.median(ref) if ref else None
            self.slow = [s for s in self.cnt_secs if base and self.tl[s] < 0.95 * base]

    def mono(self, s):
        """CLOCK_MONOTONIC ns at the start of atomicw second s."""
        return self.end - (self.end_sec - s) * 1e9

    def slice_of_sec(self, s):
        return int((self.mono(s) + 0.5e9 - self.on) // (SLICE_S * 1e9))

    def on_cpu(self, b):
        """On-CPU µs per fdatasync of bucket b, b a list of buckets, or 'sync' (all in-sync buckets)."""
        if b == "sync":
            b = INSYNC
        if isinstance(b, list):
            xs = [self.on_cpu(x) for x in b]
            return sum(x for x in xs if x is not None)
        x, off, rq, sw = self.ph[b]
        return None if x is None else x - off

    def samples(self, b):
        """perf samples of bucket b or 'sync'."""
        if b == "sync":
            return sum(v for (pb, g), v in self.perf.items() if pb != 12)
        return sum(v for (pb, g), v in self.perf.items() if pb == b)

    def gsamples(self, b, g):
        if b == "sync":
            return sum(v for (pb, gg), v in self.perf.items() if pb != 12 and gg == g)
        return self.perf[(b, g)]

    def group_us(self, b, g):
        tot, on = self.samples(b), self.on_cpu(b)
        return self.gsamples(b, g) / tot * on if tot and on else None

    def tracer_us(self, b):
        tot, on = self.samples(b), self.on_cpu(b)
        n = sum(v for pb, v in self.trc.items() if pb != 12) if b == "sync" else self.trc[b]
        return n / tot * on if tot and on else None

    def bt_samples(self, bs):
        return sum(self.smp.get(b, 0) for b in bs)


def burden(r, ref_tl):
    """ours/ref in the counted seconds minus ours/ref in seconds 2-9, points (overwrite: the 10-s ramp)."""
    if not ref_tl or not r.before or not r.counted:
        return None
    rb, rc = mean_of(ref_tl, range(2, 10)), mean_of(ref_tl, r.cnt_secs)
    return 100.0 * (r.counted / rc - r.before / rb) if rb and rc else None


def runs_of(dirs, ref_of, ksyms_of=None):
    out = []
    for d in dirs:
        d = Path(d)
        rows = csv_rows(d)
        for m3 in sorted((d / "runs").glob("*.m3")):
            inf = info(m3.with_suffix(".info"))
            out.append(Run(d, m3, rows, ref_of((inf.get("config"), inf.get("op"), int(inf.get("threads", 0) or 0))),
                           ksyms_of))
    return out


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def fmt(x, f="%.1f"):
    return "" if x is None else f % x


def rng(vals, f="%.0f"):
    vals = [v for v in vals if v is not None]
    if not vals:
        return ""
    if len(vals) == 1:
        return f % vals[0]
    return "%s (%s-%s)" % (f % statistics.median(vals), f % min(vals), f % max(vals))


def pct(a, b):
    return 100.0 * a / b if a is not None and b else None


# ---------------------------------------------------------------- the I/O pass

class IoRun:
    def __init__(self, m3, pathdev):
        self.inf = info(m3.with_suffix(".info"))
        self.key = (self.inf.get("config"), self.inf.get("op"), int(self.inf.get("threads", 0) or 0))
        tr = self.tr = Trace(m3)
        self.n = n = tr.get("sync_n")
        if not n:
            return
        self.pathdev_bt = tr.get("io_pathdev") or None
        self.pdev = pathdev or self.pathdev_bt
        bios = tr.v.get("io_bio", {})
        ins = {k: v for k, v in bios.items() if k[0] in INSYNC + [9]}
        self.bios = sum(ins.values()) / n
        self.bio_kib = sum(v * k[2] for k, v in ins.items()) / 2.0 / n
        self.bio_sz = [sum(v for k, v in ins.items() if lo <= k[2] <= hi) / n for lo, hi in ((0, 8), (9, 127), (128, 1 << 30))]
        self.bios_out = sum(v for k, v in bios.items() if k[0] == 12) / n
        self.bios_bg = sum(v for k, v in bios.items() if k[0] == 13) / n
        self.bio_rwbs = Counter()
        for k, v in ins.items():
            self.bio_rwbs[k[1]] += v
        mg = tr.v.get("io_merge", {})
        self.merges = sum(v for k, v in mg.items() if k[0] in INSYNC + [9]) / n
        self.merges_all = sum(mg.values()) / n
        rqs = {k: v for k, v in tr.v.get("io_rq", {}).items() if self.pdev is None or k[0] == self.pdev}
        rin = {k: v for k, v in rqs.items() if k[1] in INSYNC + [9]}
        self.rq_in = sum(rin.values()) / n
        self.rq_in_kib = sum(v * k[3] for k, v in rin.items()) / 2.0 / n
        self.rq_all = sum(rqs.values()) / n
        self.rq_all_kib = sum(v * k[3] for k, v in rqs.items()) / 2.0 / n
        self.rq_sz = [sum(v for k, v in rqs.items() if lo <= k[3] <= hi) / n for lo, hi in ((0, 8), (9, 127), (128, 1 << 30))]
        self.rq_bg = sum(v for k, v in rqs.items() if k[1] == 13) / n
        self.rq_rwbs = Counter()
        for k, v in rqs.items():
            self.rq_rwbs[k[2]] += v
        self.rq_flag = {"flush (rwbs F...)": sum(v for k, v in rqs.items() if str(k[2]).startswith("F")) / n,
                        "FUA (W..F..)": sum(v for k, v in rqs.items() if re.match(r"^F?W\w*F", str(k[2]))) / n}
        ins_rq = {k: v for k, v in tr.v.get("io_rqins", {}).items() if self.pdev is None or k[0] == self.pdev}
        self.rq_ins = sum(ins_rq.values()) / n
        self.rq_ins_in = sum(v for k, v in ins_rq.items() if k[1] in INSYNC + [9]) / n
        self.rqc = sum(v for k, v in tr.v.get("io_rqc", {}).items() if self.pdev is None or k[0] == self.pdev) / n
        self.comms_rq = sorted(tr.v.get("io_rqcomm", {}).items(), key=lambda kv: -kv[1])[:4]
        self.comms_bio = sorted(tr.v.get("io_biocomm", {}).items(), key=lambda kv: -kv[1])[:4]


def io_runs(dirs, pathdev):
    out = []
    for d in dirs:
        for m3 in sorted(Path(d, "runs").glob("*.m3")):
            r = IoRun(m3, pathdev)
            if r.n:
                out.append(r)
    return out


def devwide(r):
    """From the CPU pass's .info: the path's write requests, KiB and flushes from the ramp's end to the tool's end,
    per fdatasync (the timeline's pages after the ramp / fdatasync_n)."""
    a, b = r.inf.get("dev_ramp") or r.inf.get("dev_start"), r.inf.get("dev_fio_end")
    if not a or not b or not r.tl:
        return None
    a, b = [int(x) for x in a.split()], [int(x) for x in b.split()]
    warm = r.warm or 0
    syncs = sum(v for s, v in r.tl.items() if s >= warm) / r.fs
    if not syncs:
        return None
    return ((b[0] - a[0]) / syncs, (b[1] - a[1]) / 2.0 / syncs, (b[2] - a[2]) / syncs)


def pathstat(r, host):
    """From the host sampler: the path's write requests and merges per fdatasync in the counted window."""
    if not host or not r.counted_s:
        return None
    h0, h1 = host.at(r.on), host.at(r.end)
    if not h0 or not h1 or len(h0["stat"]) < 7 or len(h1["stat"]) < 7 or h1["up"] <= h0["up"]:
        return None
    syncs = r.n * (h1["up"] - h0["up"]) / r.counted_s
    return ((h1["stat"][4] - h0["stat"][4]) / syncs, (h1["stat"][5] - h0["stat"][5]) / syncs)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="*")
    ap.add_argument("--ref", nargs="*", default=[])
    ap.add_argument("--notrace", nargs="*", default=[])
    ap.add_argument("--io", nargs="*", default=[])
    ap.add_argument("--pathdev")
    ap.add_argument("--manifest", nargs="*", default=[])
    ap.add_argument("--host", nargs="*", default=[])
    ap.add_argument("--ksyms", nargs="*", default=[])
    ap.add_argument("-o", "--out")
    ap.add_argument("--folded", help="directory for the folded stacks per run and phase")
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--min-burden", type=float, default=-5.0)
    a = ap.parse_args()
    pathdev = None
    if a.pathdev:
        x, y = a.pathdev.split(":")
        pathdev = (int(x) << 20) | int(y)

    def tls(dirs):
        out = {}
        for rd in dirs:
            for tl in sorted(Path(rd).joinpath("runs").glob("*.tl")):
                inf = info(tl.with_suffix(".info"))
                k = (inf.get("config"), inf.get("op"), int(inf.get("threads", 0) or 0))
                out.setdefault(k, (tl.stem, timeline(tl)[1]))
        return out
    refs, untraced = tls(a.ref), tls(a.notrace)
    hosts = [Host(h) for h in a.host if Path(h).exists()]
    ksyms = [Ksyms(k) for k in a.ksyms if Path(k).exists()]
    ksyms_of = lambda kernel: next((k for k in ksyms if k.kernel == kernel), None)

    runs = runs_of(a.dirs, lambda k: refs.get(k, (None, None))[1], ksyms_of)
    good = [r for r in runs if r.ok]
    cells = defaultdict(list)
    for r in good:
        cells[r.key].append(r)
    order = sorted(cells, key=lambda k: (not (k[0] or "").startswith("tau-"), k[0] or "", k[1] or "", k[2]))
    host_of = lambda r: next((h for h in hosts if h.kernel == r.inf.get("kernel")), None)
    ios = {r.key: r for r in io_runs(a.io, pathdev)}
    cols = ["%s %s T%d" % k for k in order]
    md = []
    P = md.append

    # header
    P("# M3 at one thread: where the fdatasync's CPU goes (m3_cpu_report.py)")
    P("")
    for d in a.dirs:
        env = Path(d, "env.txt")
        el = env.read_text(errors="replace").splitlines() if env.exists() else []
        ker = [l[8:] for l in el if re.match(r"^kernel: \S", l)]
        P("- CPU pass: %s (%s); m3_phases.kernel.bt %s, m3_cpu.bt %s" % (d, ker[0] if ker else "?",
          md5(Path(d, "m3_phases.kernel.bt")), md5(Path(d, "m3_cpu.bt"))))
        for l in el:
            if l.startswith("M3_CPU="):
                P("  - %s" % l)
    for d in a.notrace:
        P("- untraced runs: %s" % d)
    for d in a.io:
        P("- I/O pass: %s; m3_io.bt %s" % (d, md5(Path(d, "m3_io.bt"))))
    for rd in a.ref:
        P("- the burden's reference (M3 alone): %s" % rd)
    for mf in a.manifest:
        if Path(mf).exists():
            P("- MANIFEST %s:" % mf)
            for line in Path(mf).read_text(errors="replace").splitlines():
                if re.match(r"^(uname|bzImage|harness|HEAD|bpftrace|perf|  /sys/|  /proc/|clock)", line):
                    P("  - %s" % line.strip())
    P("- this report %s. µs per fdatasync of M3's counted syncs. On-CPU of a phase = M3's time minus its off-CPU "
      "(m3_cpu.bt). A group's µs = its share of the phase's perf samples (cycles:k, 999 Hz, kernel frames) x that "
      "on-CPU; all in-sync: its share of the in-sync samples x the in-sync on-CPU." % md5(Path(__file__)))
    P("- Phase of a perf sample (the plan's rules, 4a): no vfs_fsync_range frame = outside syncs; else the innermost "
      "of " + ", ".join("%s %s" % (f, PHASES[b]) for f, b in PHASE_FN.items()) + " (__wait_on_buffer only under "
      "the tau commit); none = in sync, other. No rule for TI: its samples are TW's.")
    P("- Groups (the plan's 16, 4a; the first that matches from the leaf up): " +
      "; ".join("%d %s: %s" % (i + 1, n, p) for i, (n, p) in enumerate(GROUP_PATS)) + "; 16 other.")
    P("- Tracer frames (not a group; the rows 'of which tracer'): %s; or BPF code ([bpf]: an unresolved frame in "
      "the module area that is in no module of the run's boot) running: not a trampoline that wraps a function the run's "
      "tracer probes with a kretfunc (the function's entry is the frame above it; the frame-pointer walk loses that "
      "function's caller, and a frameless callee loses its body too)." % TRACER.pattern)
    for k in ksyms:
        P("- module snapshot %s: kernel %s, %d modules, %d module symbols; unresolved module frames are named from it"
          % (k.path, k.kernel, len(k.mods), sum(len(v) for v in k.syms.values())))
    nosnap = sorted({r.inf.get("kernel") for r in good if r.has_perf and not r.ksyms})
    if nosnap:
        P("- no module snapshot for %s: every unresolved module-area frame of those runs is counted as [bpf] (module "
          "code such as nvme among them)" % ", ".join(str(x) for x in nosnap))
    P("")

    # 1. per cell
    P("## 1. Per cell (median of the runs; range)")
    P("")
    P("| config | op | T | runs | IOPS | syncs/s | fdatasync µs | target | M3 µs | on-CPU | off-CPU | of it wait "
      "for a CPU | switches/sync | other phases (M3 µs) | in-sync on-CPU | host CPU/page | proc CPU/page | "
      "counted/before % | slow s |")
    P("|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|")
    for k in order:
        rs = cells[k]
        tb = rs[0].target
        oth = " ".join("%s %.1f" % (PHASES[b], med([r.ph[b][0] for r in rs])) for b in INSYNC
                       if b != tb and (med([r.ph[b][0] for r in rs]) or 0) >= 0.5)
        P("| %s | %s | %d | %d | " % (k + (len(rs),)) + " | ".join([
            rng([fnum(r.csv, "write_iops") for r in rs]), rng([r.n / r.counted_s if r.counted_s else None for r in rs]),
            rng([r.sync for r in rs], "%.1f"), PHASES[tb], rng([r.ph[tb][0] for r in rs], "%.1f"),
            rng([r.on_cpu(tb) for r in rs], "%.1f"), rng([r.ph[tb][1] for r in rs], "%.1f"),
            fmt(med([r.ph[tb][2] for r in rs])), fmt(med([r.ph[tb][3] for r in rs]), "%.2f"), oth,
            rng([r.on_cpu("sync") for r in rs], "%.1f"), fmt(med([fnum(r.csv, "cpu_host_us_per_page") for r in rs]), "%.2f"),
            fmt(med([fnum(r.csv, "cpu_proc_us_per_page") for r in rs]), "%.2f"),
            rng([pct(r.counted, r.before) for r in rs], "%.1f"), rng([len(r.slow) for r in rs])]) + " |")
    P("")

    # 2-3. groups
    for num, title, which in (("2", "All in-sync on-CPU", "sync"), ("3", "The target phase's on-CPU (τ CT, Raw D)", "target")):
        P("## %s. %s by group (µs per fdatasync, median of the runs; %% of the column)" % (num, title))
        P("")
        P("| group | " + " | ".join(cols) + " |")
        P("|---|" + "---:|" * len(order))
        bsel = lambda rs: "sync" if which == "sync" else rs[0].target
        for g in GROUP_NAMES:
            row = []
            for k in order:
                rs = cells[k]
                us = med([r.group_us(bsel(rs), g) for r in rs])
                row.append("%s (%s%%)" % (fmt(us), fmt(pct(us, med([r.on_cpu(bsel(rs)) for r in rs])))))
            P("| %s | " % g + " | ".join(row) + " |")
        P("| **on-CPU** | " + " | ".join(fmt(med([r.on_cpu(bsel(cells[k])) for r in cells[k]])) for k in order) + " |")
        P("| of which tracer frames | " + " | ".join("%s (%s%%)" % (
            fmt(med([r.tracer_us(bsel(cells[k])) for r in cells[k]])),
            fmt(pct(med([r.tracer_us(bsel(cells[k])) for r in cells[k]]), med([r.on_cpu(bsel(cells[k])) for r in cells[k]]))))
            for k in order) + " |")
        P("| perf samples (all runs) | " + " | ".join(str(sum(r.samples(bsel(cells[k])) for r in cells[k])) for k in order) + " |")
        P("")

    P("Tracer samples by probe site (µs per fdatasync in all in-sync time, all runs pooled; the traced function "
      "above the BPF frames, the tracepoint, the profile or perf):")
    P("")
    for k in order:
        rs = cells[k]
        pool = Counter()
        for r in rs:
            for pb, c in r.trc_site.items():
                if pb != 12:
                    pool.update(c)
        tot = sum(r.samples("sync") for r in rs)
        on = med([r.on_cpu("sync") for r in rs])
        P("- %s: " % cols[order.index(k)] + ("; ".join("%s %.2f" % (site, c / tot * on) for site, c in pool.most_common(12))
                                            if tot and on and pool else "none"))
    P("")

    # 4. leaf functions
    P("## 4. Top 20 leaf functions (self), µs per fdatasync (all runs of a cell pooled; % of the phase)")
    P("")
    for which in ("target", "sync"):
        for k in order:
            rs = cells[k]
            b = rs[0].target if which == "target" else "sync"
            pool = Counter()
            for r in rs:
                if b == "sync":
                    for pb, c in r.leaf.items():
                        if pb != 12:
                            pool.update(c)
                else:
                    pool.update(r.leaf[b])
            tot, on = sum(pool.values()), med([r.on_cpu(b) for r in rs])
            name = PHASES[b] if b != "sync" else "all in-sync"
            if tot and on:
                P("- %s, %s (%d samples): " % (cols[order.index(k)], name, tot) + "; ".join(
                    "%s %.1f (%.1f%%)" % (f, c / tot * on, 100.0 * c / tot) for f, c in pool.most_common(20)))
            else:
                P("- %s, %s: no samples" % (cols[order.index(k)], name))
        P("")

    # 5. named functions, inclusive
    P("## 5. Named functions (plan 4a), inclusive µs per fdatasync (median of the runs; % of the phase)")
    P("")
    for which in ("target", "sync"):
        P("%s:" % ("In the target phase (τ CT, Raw D)" if which == "target" else "In all in-sync time"))
        P("")
        P("| function | " + " | ".join(cols) + " |")
        P("|---|" + "---:|" * len(order))
        for f in NAMED + [SELF]:
            row = []
            for k in order:
                rs = cells[k]
                b = rs[0].target if which == "target" else "sync"

                def us(r):
                    tot, on = r.samples(b), r.on_cpu(b)
                    if not tot or not on:
                        return None
                    if f == SELF:
                        c = sum(v for pb, v in r.selfc.items() if pb != 12) if b == "sync" else r.selfc[b]
                    else:
                        c = sum(cc[f] for pb, cc in r.incl.items() if pb != 12) if b == "sync" else r.incl[b][f]
                    return c / tot * on
                v = med([us(r) for r in rs])
                row.append("%s (%s%%)" % (fmt(v), fmt(pct(v, med([r.on_cpu(b) for r in rs])))) if v else "")
            P("| %s | " % f + " | ".join(row) + " |")
        P("")

    # 6. I/O
    P("## 6. I/O per fdatasync")
    P("")
    if ios:
        P("The I/O pass (M3 + m3_io.bt, 20 s, counts only). In sync: by the tool's thread in a counted sync (bios: "
          "the submitter; requests: the issuer). Bios are on the namespace head; requests on the PM1735's path "
          "(dev %s; the bio remap gave %s). Sizes: <=4 KiB, 8-60 KiB, >=64 KiB." % (
              a.pathdev or "from the bio remap", ", ".join(sorted({"%d:%d" % (r.pathdev_bt >> 20, r.pathdev_bt & 0xfffff)
                                                                for r in ios.values() if r.pathdev_bt}))))
        P("")
        P("| config | op | T | syncs | bios in sync | KiB | <=4 / 8-60 / >=64 KiB | bios outside / other threads | "
          "merges in sync / all | rq issued in sync | KiB | rq all | KiB | <=4 / 8-60 / >=64 KiB | rq of other "
          "threads | rq inserted in sync / all | rq completed | flush, FUA rq | rq rwbs | other threads' rq, bios |")
        P("|---|---|---:|---:|---:|---:|---|---|---|---:|---:|---:|---:|---|---:|---|---:|---|---|---|")
        for k in sorted(ios, key=lambda k: (not (k[0] or "").startswith("tau-"), k)):
            r = ios[k]
            P("| %s | %s | %d | %d | " % (k + (r.n,)) + " | ".join([
                "%.1f" % r.bios, "%.0f" % r.bio_kib, " / ".join("%.1f" % x for x in r.bio_sz),
                "%.1f / %.1f" % (r.bios_out, r.bios_bg), "%.1f / %.1f" % (r.merges, r.merges_all), "%.1f" % r.rq_in,
                "%.0f" % r.rq_in_kib, "%.1f" % r.rq_all, "%.0f" % r.rq_all_kib, " / ".join("%.1f" % x for x in r.rq_sz),
                "%.1f" % r.rq_bg, "%.1f / %.1f" % (r.rq_ins_in, r.rq_ins), "%.1f" % r.rqc,
                ", ".join("%s %.2f" % (n, v) for n, v in r.rq_flag.items()),
                " ".join("%s %.1f" % (w, v / r.n) for w, v in r.rq_rwbs.most_common(4)),
                "rq: " + ", ".join("%s %.2f" % (c[0] if c else "?", v / r.n) for c, v in r.comms_rq) +
                "; bios: " + ", ".join("%s %.2f" % (c[0] if c else "?", v / r.n) for c, v in r.comms_bio)]) + " |")
        P("")
    P("From the CPU pass (no probes): the path's write requests, KiB and flushes per fdatasync from the ramp's end to the "
      "tool's end (.info); and from the host sampler's path stat in the counted window, write requests + merges, "
      "against the I/O pass's bios in sync (bios ≈ requests + merges).")
    P("")
    P("| config | op | T | rep | rq | KiB | flushes | rq (host sampler) | merges | rq + merges | I/O pass bios in sync |")
    P("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for k in order:
        for r in cells[k]:
            dw, ps = devwide(r), pathstat(r, host_of(r))
            P("| %s | %s | %d | %s | " % (k + (r.rep,)) + " | ".join([
                fmt(dw[0]) if dw else "", fmt(dw[1], "%.0f") if dw else "", fmt(dw[2], "%.2f") if dw else "",
                fmt(ps[0]) if ps else "", fmt(ps[1]) if ps else "", fmt(ps[0] + ps[1]) if ps else "",
                fmt(ios[k].bios) if k in ios else ""]) + " |")
    P("")

    # 7. per unit
    P("## 7. Per unit (the CPU pass's medians over the I/O pass's counts of the same cell)")
    P("")
    P("| config | op | T | in-sync on-CPU µs | per bio | per request (path, all) | per 4-KiB block (bio KiB / 4) | "
      "target on-CPU µs | target per bio |")
    P("|---|---|---:|---:|---:|---:|---:|---:|---:|")
    for k in order:
        rs, io = cells[k], ios.get(k)
        ins, tgt = med([r.on_cpu("sync") for r in rs]), med([r.on_cpu(rs[0].target) for r in rs])
        P("| %s | %s | %d | " % k + " | ".join([
            fmt(ins), fmt(ins / io.bios, "%.2f") if io and io.bios and ins else "",
            fmt(ins / io.rq_all, "%.2f") if io and io.rq_all and ins else "",
            fmt(ins / (io.bio_kib / 4), "%.2f") if io and io.bio_kib and ins else "", fmt(tgt),
            fmt(tgt / io.bios, "%.2f") if io and io.bios and tgt else ""]) + " |")
    P("")

    # 8. burden
    P("## 8. The tracer's burden (atomicw's pages per second)")
    P("")
    P("before: seconds 2-9 (the 10-s ramp of overwrite, before the tracer). counted: the full seconds in "
      "[@cp_on, @cp_end]. Against a reference (M3 alone) or the cell's untraced run, in points: ours/theirs in the "
      "counted seconds minus ours/theirs in seconds 2-9. The untraced run is rep 1 after a fresh layout.")
    P("")
    P("| config | op | T | rep | counted secs | counted s (cp) | before | counted | counted/before % | vs reference, "
      "points | untraced counted/before % | vs untraced, points | slow seconds |")
    P("|---|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for k in order:
        for r in cells[k]:
            u = untraced.get(k, (None, None))[1]
            ur = pct(mean_of(u, r.cnt_secs), mean_of(u, range(2, 10))) if u and r.cnt_secs else None
            P("| %s | %s | %d | %s | " % (k + (r.rep,)) + " | ".join([
                "%d-%d" % (r.cnt_secs[0], r.cnt_secs[-1]) if r.cnt_secs else "", fmt(r.counted_s),
                fmt(r.before, "%.0f"), fmt(r.counted, "%.0f"), fmt(pct(r.counted, r.before)),
                fmt(r.burden, "%+.1f"), fmt(ur), fmt(burden(r, u), "%+.1f"),
                ",".join(str(s) for s in r.slow)]) + " |")
    P("")

    # 9. slices
    P("## 9. Per 5-s slice from @cp_on (appendix)")
    P("")
    P("Per slice: atomicw's pages per second; in-sync on-CPU µs per fdatasync from bpftrace's profile counts "
      "(@cp_slc) / from perf; the leading groups of the in-sync perf samples.")
    P("")
    for k in order:
        for r in cells[k]:
            if not r.cnt_secs:
                continue
            secs = defaultdict(list)
            for s in r.cnt_secs:
                secs[r.slice_of_sec(s)].append(s)
            rows = []
            for sl in sorted(secs):
                ss = secs[sl]
                syncs = sum(r.tl[s] for s in ss) / r.fs * (SLICE_S / len(ss))
                bt = sum(r.tr.get("cp_slc", b, sl) for b in INSYNC + [9])
                pf = sum(v for b, v in r.sl_perf[sl].items() if b != 12)
                tot = sum(r.sl_grp[sl].values())
                lead = ", ".join("%s %.0f%%" % (g, 100.0 * v / tot) for g, v in r.sl_grp[sl].most_common(3)) if tot else ""
                rows.append("s%d-%d %.0f p/s, %s / %s µs (%s)" % (ss[0], ss[-1], mean_of(r.tl, ss),
                            fmt(bt / HZ * 1e6 / syncs if syncs else None), fmt(pf / HZ * 1e6 / syncs if syncs else None), lead))
            P("- %s r%s: " % (cols[order.index(k)], r.rep) + "; ".join(rows))
            if len(r.slow) >= 5:
                P("  - slow seconds (%d: %s) against the others, in-sync: " % (len(r.slow), ",".join(map(str, r.slow))) +
                  "; ".join(split_line(r, part) for part in ("fast", "slow")))
                h = host_of(r)
                if h:
                    s0 = r.slow[0]
                    for s in (s0 - 2, s0 - 1, s0, s0 + 1):
                        row = h.at(r.mono(s))
                        if row:
                            P("  - host at second %d: %s" % (s, re.sub(r"^\S+ ", "", row["line"])[:400]))
    P("")

    # 10. checks
    P("## 10. Checks")
    P("")
    P("Per run: M3 check; @cp_on, @cp_end; @cp_anom; @cp_nowake; lost off-CPU stacks (empty stacks, % of the target's "
      "off-CPU); perf samples in / outside the window; perf's lost records; check 3 (the process's sampled CPU per "
      "page against atomicw's getrusage, runs with no slow phase only).")
    P("")
    P("| config | op | T | rep | M3 check | cp_on, cp_end | anom | nowake | lost stacks | perf in / out | perf lost | "
      "check 3 sampled / getrusage µs per page |")
    P("|---|---|---:|---:|---:|---|---:|---:|---:|---|---:|---|")
    gate = []
    for k in order:
        for r in cells[k]:
            b = r.target
            lost_ns = sum(v["total"] for kk, fr, v in r.tr.stk.get("cp_stk", []) if kk and kk[0] in ([8, 9] if b == 8 else [b])
                          and not fr and isinstance(v, dict))
            lost_pct = pct(lost_ns, r.ph[b][1] * r.n * 1000) or 0.0
            c3 = ""
            if not r.slow:
                smp_all = r.bt_samples(INSYNC + [12]) / HZ * 1e6 / (r.n * r.fs)
                cpu = fnum(r.csv, "cpu_proc_us_per_page")
                c3 = "%.2f / %s (%s%%)" % (smp_all, fmt(cpu, "%.2f"), fmt(pct(smp_all, cpu)))
            P("| %s | %s | %d | %s | " % (k + (r.rep,)) + " | ".join([
                fmt(r.check), "%s, %s" % ("yes" if r.on else "no", "yes" if r.end else "no"), str(r.tr.get("cp_anom")),
                str(r.tr.get("cp_nowake")), "%.2f%%" % lost_pct, "%d / %d" % (r.perf_in, r.perf_out),
                "" if r.perf_lost is None else str(r.perf_lost), c3]) + " |")
            r.lost_pct = lost_pct
    P("")
    P("Per phase: sampled (profile counts / 999 Hz) against derived (M3 time minus off-CPU), and the phase's share of "
      "the in-sync samples, perf against bpftrace's profile. τ: perf's TW against bpftrace's TW + TI.")
    P("")
    P("| config | op | T | rep | phase | derived µs | sampled/derived % | perf samples | share perf % | share bpftrace % | perf/bpftrace |")
    P("|---|---|---:|---:|---|---:|---:|---:|---:|---:|---:|")
    for k in order:
        for r in cells[k]:
            ins_perf, ins_bt = r.samples("sync"), r.bt_samples(INSYNC)
            for name, bt_bs, pf_b in [("in sync", INSYNC, "sync")] + [(PHASES[b] + ("+TI" if b == 5 and r.tau else ""),
                                      [5, 6] if b == 5 and r.tau else [b], b) for b in INSYNC if b != 6]:
                der = r.on_cpu(bt_bs)
                smp = r.bt_samples(bt_bs) / HZ * 1e6 / r.n
                ps, bs = pct(r.samples(pf_b), ins_perf), pct(r.bt_samples(bt_bs), ins_bt)
                if name != "in sync" and not r.bt_samples(bt_bs) and not r.samples(pf_b):
                    continue
                P("| %s | %s | %d | %s | %s | " % (k + (r.rep, name)) + " | ".join([
                    fmt(der), fmt(pct(smp, der)), str(r.samples(pf_b)), fmt(ps), fmt(bs),
                    fmt(ps / bs, "%.3f") if ps and bs else ""]) + " |")
    P("")
    for k in order:
        for r in cells[k]:
            b = r.target
            der = r.on_cpu(b)
            sd = pct(r.bt_samples([b]) / HZ * 1e6 / r.n, der)
            sp, sb = pct(r.samples(b), r.samples("sync")), pct(r.bt_samples([b]), r.bt_samples(INSYNC))
            why = []
            if fmt(r.check) != "100.0":                 # the plan: "M3 check 100.0", as m3_report.py prints it
                why.append("M3 check %s" % fmt(r.check, "%.2f"))
            if not (r.on and r.end):
                why.append("@cp_on or @cp_end missing")
            if r.tr.get("cp_anom"):
                why.append("@cp_anom %d" % r.tr.get("cp_anom"))
            if r.lost_pct > 1.0:
                why.append("lost off-CPU stacks %.2f%%" % r.lost_pct)
            if sd is None or not 90.0 <= sd <= 110.0:
                why.append("%s sampled/derived %s%%" % (PHASES[b], fmt(sd)))
            if not r.has_perf or r.perf_lost is None or r.perf_lost != 0:
                why.append("perf data or stats missing, or lost records (%s)" % r.perf_lost)
            if r.samples(b) < 1000:
                why.append("%d perf samples in %s" % (r.samples(b), PHASES[b]))
            if not sp or not sb or abs(sp / sb - 1.0) > 0.10:
                why.append("%s share perf %s%% against bpftrace %s%%" % (PHASES[b], fmt(sp), fmt(sb)))
            if r.burden is None or r.burden < a.min_burden:
                why.append("IOPS burden %s" % (fmt(r.burden, "%+.1f points") if r.burden is not None else "unknown"))
            gate.append((k, r.rep, not why, "; ".join(why) or "ok: M3 check %s, %s sampled/derived %s%%, %d perf "
                         "samples, share perf/bpftrace %s, lost stacks %.2f%%, burden %s points" % (
                             fmt(r.check, "%.2f"), PHASES[b], fmt(sd), r.samples(b),
                             fmt(sp / sb if sp and sb else None, "%.3f"), r.lost_pct, fmt(r.burden, "%+.1f"))))
    # 11. per second: the tool's threads and the NUMA nodes (m3cpu_sampler.py)
    if any(any(row["aw"] for row in (host_of(r).rows if host_of(r) else [])) for k in order for r in cells[k]):
        P("## 11. Per second: the tool's threads and the NUMA nodes (host sampler, read at about mid-second)")
        P("")
        P("A thread: tid@cpu/node, its migrations and non-voluntary switches since the line before. Nodes: free "
          "memory (GB) and the change of their page cache (FilePages, MB) since the line before.")
        P("")
        for k in order:
            for r in cells[k]:
                h = host_of(r)
                if not h or not r.tl or r.end_sec is None:
                    continue
                P("%s r%s (counted from second %s):" % (cols[order.index(k)], r.rep, r.cnt_secs[0] if r.cnt_secs else "?"))
                P("")
                P("| s | pages/s | threads | migrations | nvcsw | " + " | ".join("node%d free GB, file ΔMB" % n
                  for n in sorted({int(x[4:x.index("_")]) for x in h.rows[0]["f"] if re.match(r"^node\d+_free$", x)})) + " |")
                P("|---:|---:|---|---:|---:|" + "---|" * len([x for x in h.rows[0]["f"] if re.match(r"^node\d+_free$", x)]))
                prev = None
                for sec in sorted(r.tl):
                    if sec >= int(r.end_sec):
                        break
                    row = h.at(r.mono(sec + 0.5))
                    if row is None or (prev is not None and row is prev):
                        continue
                    pa = {t[0]: t for t in prev["aw"]} if prev else {}
                    thr, mig, nv = [], 0, 0
                    for t in row["aw"]:
                        tid, cpu = t[0], t[1]
                        node = h.node_of.get(int(cpu)) if cpu.isdigit() else None
                        thr.append("%s@%s/%s" % (tid, cpu, "?" if node is None else node))
                        if tid in pa and t[2].isdigit() and pa[tid][2].isdigit():
                            mig += int(t[2]) - int(pa[tid][2])
                        if tid in pa and t[3].isdigit() and pa[tid][3].isdigit():
                            nv += int(t[3]) - int(pa[tid][3])
                    nodes = []
                    for x in sorted(f for f in row["f"] if re.match(r"^node\d+_free$", f)):
                        n = x[4:x.index("_")]
                        fr, fi = row["f"].get("node%s_free" % n, "?"), row["f"].get("node%s_file" % n, "?")
                        dfi = (int(fi) - int(prev["f"].get("node%s_file" % n, fi))) / 1024 if prev and fi.isdigit() else None
                        nodes.append("%s, %s" % ("%.2f" % (int(fr) / 2**20) if fr.isdigit() else "?", fmt(dfi, "%+.0f")))
                    P("| %d | %d | %s | %s | %s | %s |" % (sec, r.tl[sec], " ".join(thr) or "-", mig if prev else "",
                                                       nv if prev else "", " | ".join(nodes)))
                    prev = row
                P("")

    notes = [(r, r.tr.notes) for k in order for r in cells[k] if r.tr.notes]
    if notes:
        P("Lines of the tracer output that are not maps (errors, warnings):")
        for r, ns in notes:
            P("- %s r%s: %d, first: %s" % (cols[order.index(r.key)], r.rep, len(ns), ns[0][:160]))
        P("")
    if a.gate:
        if len(good) != 1:
            gate.append((("all", "", 0), "", False, "%d runs with syncs, the check has 1" % len(good)))
        ok = all(g[2] for g in gate)
        P("## Gate (check step, plan section 6): %s" % ("PASS" if ok else "FAIL"))
        P("")
        for k, rep, g, why in gate:
            P("- %s %s T%s r%s: %s (%s)" % (k[0], k[1], k[2], rep, "pass" if g else "FAIL", why))
        P("")
    text = "\n".join(md) + "\n"
    if a.out:
        Path(a.out).write_text(text)
    if a.folded:
        fd = Path(a.folded)
        fd.mkdir(parents=True, exist_ok=True)
        for r in good:
            for b, c in r.folded.items():
                (fd / ("%s.%s.folded" % (r.label, PHASES.get(b, str(b)).replace("+", "_")))).write_text(
                    "".join("%s %d\n" % (s, v) for s, v in c.most_common()))
    print(text)
    if a.gate and not all(g[2] for g in gate):
        sys.exit(2)


def split_line(r, part):
    """In-sync perf group shares and on-CPU µs per fdatasync in the run's slow or other counted seconds."""
    secs = [s for s in r.cnt_secs if (s in r.slow) == (part == "slow")]
    c = Counter()
    for s in secs:
        c.update(r.sec_perf.get(s, {}))
    syncs = sum(r.tl[s] for s in secs) / r.fs
    tot = sum(c.values())
    if not tot or not syncs:
        return "%s: no samples" % part
    return "%s %d s: %.0f p/s, %.1f µs (perf), %s" % (part, len(secs), mean_of(r.tl, secs), tot / HZ * 1e6 / syncs,
                                                     ", ".join("%s %.0f%%" % (g, 100.0 * v / tot) for g, v in c.most_common(4)))


if __name__ == "__main__":
    main()
