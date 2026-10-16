#!/usr/bin/env python3
"""Where MySQL's user threads spend a transaction: the DIAG_TOOLS=offcpu
diagnosis window of run_main.sh PROFILE=diag (profile.sh diag_offcpu).

For every configuration of a run directory, per commit of the window, of
the user ("connection") threads serving the load: time on a CPU (schedstat),
waiting for a CPU after being preempted (offcpu.bt) and blocked (offcpu.bt:
from switching out to running again, so it holds the wait for a CPU after the
wake-up, which is schedstat's run delay less the preempted part). The three
add up to threads x window / commits, the mean time per transaction (Little's
law). The blocked time goes by category of the user stack (client, redo
commit, free page, LRU list mutex, page latch, ...), by wait site (the first
user frame outside the wait primitives) and by kernel wait (futex, block I/O,
poll, ...), with the difference between the first two configurations. An idle
connection thread (thread cache) is left out.
bpftrace leaves the frames of threads whose /proc entry it could not open
unresolved; the mysqld ones are resolved here from the binary's symbol table
(its load address from the frames bpftrace did resolve), the others (libc)
count as wait primitives.
Usage: offcpu_tables.py <run dir> [top sites]
"""
import bisect
import collections
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

USER = "connection"
# user frames that only wait; the first frame outside them is the wait site
PRIM = re.compile(
    r"^(_+GI_+|__libc_|_*lll_|_*futex|_*pthread_|syscall|_*poll|ppoll|_*recv|_*read$|"
    r"_*pread|_*pwrite|_*fsync|_*fdatasync|_*clock_nanosleep|_*nanosleep|_*sched_yield|"
    r"epoll_wait|io_getevents|std::condition_variable|std::__condvar|std::this_thread|"
    r"os_event|os_thread_|sync_array_|rw_lock_|pfs_rw_lock|pfs_mutex|TTASEventMutex|"
    r"PolicyMutex|ut_delay|mysql_cond_|inline_mysql_cond|native_cond|my_cond|os_file_|"
    r"pfs_os_file|os_aio|vio_|Vio|my_net_read|net_read|my_real_read|Protocol_classic::|"
    r"0x[0-9a-f]+$)")
IDLE = "idle connection thread (thread cache)"
# buf_page_make_young and buf_page_init_for_read take buf_pool->LRU_list_mutex
LRU_SITES = ("buf_page_make_young", "buf_page_init_for_read", "buf_LRU_make_block_young",
             "buf_LRU_add_block")


def category(fr, site):
    """Category of a blocked user stack (function base names, innermost first)."""
    if any("block_until_new_connection" in x for x in fr):
        return IDLE
    if site == "do_command":
        return "client: waiting for the next statement"
    if any(x in fr for x in ("log_write_up_to", "log_wait_for_flush", "log_wait_for_write")):
        return "redo: the commit waits for the log flush"
    if "buf_LRU_get_free_block" in fr:
        return "free page: LRU scan and single-page flush (buf_LRU_get_free_block)"
    if site in LRU_SITES:
        return "LRU list mutex: making a page young, adding a page read"
    if "lock_wait_suspend_thread" in fr:
        return "row lock"
    if any(x.startswith("buf_read_page") for x in fr):
        return "page read from the file"
    if site.startswith(("Buf_fetch", "buf_page_get", "btr_", "buf_wait_for_read", "buf_page_t")):
        return "page latch or I/O fix"
    if site.startswith(("mtr_t::x_lock_space", "fsp_", "fseg_")):
        return "tablespace latch (extent reservation)"
    if site.startswith("trx_"):
        return "transaction system and undo (trx_*)"
    return "other"

KWAIT = [  # kernel stack: what the thread slept in
    ("futex (InnoDB events, mutexes, condition variables)", r"futex"),
    ("block I/O (page cache miss, writes)", r"io_schedule|folio_wait|bit_wait_io|blk_|rq_qos|"
                                             r"wait_on_page|filemap_|__wait_on_buffer"),
    ("fsync / journal", r"jbd2|ext4_sync|file_write_and_wait|fdatawait|file_fdatawait"),
    ("socket", r"sk_wait|tcp_|unix_stream|sock_|inet_"),
    ("poll", r"epoll|do_sys_poll|do_select|poll_schedule"),
    ("kernel lock", r"rwsem|mutex_lock|__mutex"),
    ("sleep", r"nanosleep|hrtimer"),
]


def base_name(sym):
    sym = re.sub(r"\+\d+$", "", sym).replace(" [clone .cold]", "")
    return sym if sym.startswith("operator") else sym.split("(", 1)[0]


def raw_frames(block):
    """(address, symbol+offset or None, module or None) per frame line."""
    out = []
    for line in block:
        parts = line.strip().split(None, 1)
        if len(parts) < 2 or not re.fullmatch(r"[0-9a-f]+", parts[0]):
            continue
        rest, mod = parts[1], None
        if rest.endswith(")") and " (" in rest:
            rest, mod = rest.rsplit(" (", 1)
            mod = mod[:-1]
        out.append((int(parts[0], 16), None if rest.startswith("0x") else rest, mod))
    return out


class Mysqld:
    """Resolves mysqld addresses of a run from the binary's symbol table."""

    def __init__(self, stacks):
        self.path = next((m for st in stacks for _, _, m in st if m and m.endswith("/mysqld")), None)
        self.base = None
        if not self.path:
            return
        nm = subprocess.run(["nm", "-C", "--defined-only", self.path], capture_output=True,
                            text=True).stdout.splitlines()
        syms, by_name = [], {}
        for line in nm:
            f = line.split(" ", 2)
            if len(f) == 3 and f[1] in "TtWw":
                a = int(f[0], 16)
                syms.append((a, f[2]))
                if "[clone" not in f[2]:
                    by_name.setdefault(f[2], a)
        syms.sort()
        self.addrs, self.names = [a for a, _ in syms], [n for _, n in syms]
        bases = collections.Counter()
        for st in stacks:
            for addr, sym, mod in st:
                if sym and mod == self.path:
                    name, _, off = sym.rpartition("+")
                    if name in by_name and off.isdigit():
                        bases[addr - by_name[name] - int(off)] += 1
            if sum(bases.values()) > 200:
                break
        if bases:
            self.base = bases.most_common(1)[0][0]
            self.end = self.base + self.addrs[-1] + 0x100000

    def name(self, addr):
        if self.base is None or not self.base <= addr < self.end:
            return None
        i = bisect.bisect_right(self.addrs, addr - self.base) - 1
        return self.names[i] if i >= 0 else None


def bt_stacks(text, name):
    """{tuple of function base names: ns} of @name[stack]: value entries."""
    raw, cur = [], None
    for line in text.splitlines():
        if line.startswith(f"@{name}["):
            cur = []
        elif cur is not None and line.startswith("]: "):
            raw.append((raw_frames(cur), int(line[3:])))
            cur = None
        elif cur is not None:
            cur.append(line)
    my = Mysqld([st for st, _ in raw])
    out = defaultdict(int)
    for st, ns in raw:
        fr = []
        for addr, sym, _ in st:
            sym = sym or my.name(addr)
            fr.append(base_name(sym) if sym else "0x%x" % addr)
        out[tuple(fr)] += ns
    return out


def scalar(text, name):
    m = re.search(rf"^@{name}: (\d+)$", text, re.M)
    return int(m.group(1)) if m else 0


def status(path):
    st = {}
    for line in path.read_text().splitlines():
        st[line.split()[0]] = {k: float(v) for k, v in re.findall(r"(\w+)=([\d.]+)", line)}
    return st


def schedstat(path):
    """{tag: {tid: (comm, on_cpu_ns, runq_ns)}}, {tag: time}"""
    per, times = defaultdict(dict), {}
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) == 2 and f[1].startswith("time="):
            times[f[0]] = float(f[1][5:])
        elif len(f) >= 5:
            per[f[0]][f[1]] = (f[2], int(f[3]), int(f[4]))
    return per, times


def wait_site(fr):
    return next((f for f in fr if not PRIM.match(f)), fr[-1] if fr else "?")


def analyse(prefix):
    text = Path(f"{prefix}.bt").read_text()
    st = status(Path(f"{prefix}.status"))
    commits = st["end"]["Com_commit"] - st["begin"]["Com_commit"]
    win = st["end"]["time"] - st["begin"]["time"]
    m0 = re.search(r"window_begin_ns (\d+)", text)
    m1 = re.search(r"window_end_ns (\d+)", text)
    bt_win = (int(m1.group(1)) - int(m0.group(1))) / 1e9
    scale = win / bt_win / commits * 1e-3      # bt ns -> us per commit of the counters' window
    per, _ = schedstat(Path(f"{prefix}.schedstat"))
    on = rq = 0
    threads = 0
    for tid, (comm, c1, r1) in per["end"].items():
        # threads serving the load (an idle cached thread runs ~0)
        if comm == USER and tid in per["begin"] and c1 - per["begin"][tid][1] > 0.01 * win * 1e9:
            on += c1 - per["begin"][tid][1]
            rq += r1 - per["begin"][tid][2]
            threads += 1
    cats, sites, kw = defaultdict(float), defaultdict(float), defaultdict(float)
    for fr, ns in bt_stacks(text, "blk_u").items():
        site = wait_site(fr)
        cats[category(fr, site)] += ns * scale
        sites[site] += ns * scale
    idle = cats.pop(IDLE, 0.0)
    blocked = scalar(text, "blocked_ns") * scale - idle
    preempted = scalar(text, "runq_ns") * scale
    r = {"commits": commits, "window_s": win, "threads": threads,
         "tps": commits / win,
         "little_us": threads * win / commits * 1e6,
         "on_cpu_us": on / commits / 1e3, "cpu_wait_us": rq / commits / 1e3,
         "preempted_us": preempted, "wakeup_wait_us": rq / commits / 1e3 - preempted,
         "blocked_us": blocked, "idle_us": idle,
         "blocked_d_us": scalar(text, "blocked_d_ns") * scale}
    for fr, ns in bt_stacks(text, "blk_k").items():
        k = " ".join(fr)
        kw[next((n for n, rx in KWAIT if re.search(rx, k)), "other: " + (fr[2] if len(fr) > 2 else "?"))] += ns * scale
    r.update(cats=cats, sites=sites, kwait=kw)
    return r


def main():
    run = Path(sys.argv[1])
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    res = {}
    for bt in sorted(run.glob("*.diag.offcpu.bt")):
        prefix = str(bt)[:-3]
        label = re.search(r"write_only_(.+?)_t\d+_c", bt.name).group(1)
        res[label] = analyse(prefix)
    labels = list(res)
    if not labels:
        sys.exit("no *.diag.offcpu.bt")
    diff = len(labels) >= 2
    hdr = "| | " + " | ".join(labels) + (f" | {labels[1]} − {labels[0]} |" if diff else " |")
    sep = "|---" * (len(labels) + 1 + diff) + "|"

    def row(name, vals, fmt="{:.0f}"):
        cells = [fmt.format(v) for v in vals]
        d = [fmt.format(vals[1] - vals[0])] if diff else []
        return f"| {name} | " + " | ".join(cells + d) + " |"

    print(f"# Off-CPU breakdown of the MySQL user threads ({run.name})\n")
    print("µs per transaction (commit) of the diagnosis window.\n")
    print(hdr + "\n" + sep)
    print(row("TPS in the window", [res[l]["tps"] for l in labels]))
    print(row("user threads serving the load", [res[l]["threads"] for l in labels]))
    print(row("time per transaction (threads × window / commits)", [res[l]["little_us"] for l in labels]))
    print(row("on a CPU (schedstat)", [res[l]["on_cpu_us"] for l in labels]))
    print(row("waiting for a CPU after being preempted (offcpu.bt)", [res[l]["preempted_us"] for l in labels]))
    print(row("blocked, until running again (offcpu.bt)", [res[l]["blocked_us"] for l in labels]))
    print(row("sum of the three", [res[l]["on_cpu_us"] + res[l]["preempted_us"] + res[l]["blocked_us"]
                                   for l in labels]))
    print(row("— blocked: waiting for a CPU after the wake-up (schedstat run delay − preempted)",
              [res[l]["wakeup_wait_us"] for l in labels]))
    print(row("— blocked: asleep (the rest)", [res[l]["blocked_us"] - res[l]["wakeup_wait_us"] for l in labels]))
    print(row("— blocked: uninterruptible (D, I/O)", [res[l]["blocked_d_us"] for l in labels]))
    print(row("left out: the idle connection thread", [res[l]["idle_us"] for l in labels]))
    for key, title in (("cats", "Blocked time by category (user stack; with the wait for a CPU after the wake-up)"),
                       ("kwait", "Blocked time by kernel wait (with the idle thread)"),
                       ("sites", f"Blocked time by wait site (first user frame outside the wait primitives), top {top}")):
        print(f"\n## {title}\n")
        print(hdr + "\n" + sep)
        names = set()
        for l in labels:
            names |= set(res[l][key])
        order = sorted(names, key=lambda n: -max(res[l][key].get(n, 0) for l in labels))
        if key == "sites":
            order = order[:top]
        for n in order:
            print(row(n.replace("|", "\\|"), [res[l][key].get(n, 0) for l in labels]))


if __name__ == "__main__":
    main()
