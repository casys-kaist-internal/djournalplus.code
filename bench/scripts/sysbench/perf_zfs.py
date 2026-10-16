#!/usr/bin/env python3
"""Where the CPU goes on ZFS: a perf record -a -g of the diagnosis window
(profile.sh PROFILE=diag) split by thread group and by ZFS code path.

Runs `perf script` (as root, with --kallsyms=/proc/kallsyms so the zfs/spl
module symbols resolve; the module of a function comes from /proc/kallsyms)
and prints, with shares of all samples (CPUs x window) and in CPUs:
- every thread group, and its samples with a zfs/spl frame in the stack;
- inclusive shares of the zfs/spl functions and of the code paths asked about
  (write issue, metadata compression, checksums, allocation, space accounting,
  the taskq lock, the ZIL);
- CPU spent spinning on a lock, by the function taking it;
- the top call stacks of the samples with a zfs/spl frame;
- with the perf lock contention -v output of the same window: contended
  acquisitions per lock caller (summed over its call stacks), by count. The BPF
  wait times have outliers of tens of seconds in a 60-s window, so the total
  waits are only listed.
Usage: perf_zfs.py <perf.data> [perf lock contention output]   (PERF: perf binary)
"""
import collections
import os
import re
import subprocess
import sys

PERF = os.environ.get("PERF", "perf")
GROUPS = [  # (name, comm regex), first match wins
    ("idle", r"swapper"),
    ("zio write issue (z_wr_iss*)", r"z_wr_iss"),
    ("zio write done (z_wr_int*)", r"z_wr_int"),
    ("other zio taskqs (z_*)", r"z_"),
    ("syncing context (txg_sync, dp_sync_taskq)", r"(txg_|dp_sync_taskq|dp_zil_clean)"),
    ("ZIL / ARC / dbuf / spl threads", r"(zil_|arc_|dbu_evict|dbuf_evict|spl_|zthr|l2arc|mmp)"),
    ("PostgreSQL processes", r"postgres"),
    ("MySQL user threads (connection)", r"connection"),
    ("MySQL background threads", r"(ib_|mysqld|xpl_|sig_handler|evt_sched|gtid_zip)"),
    ("sysbench", r"sysbench"),
    ("other", r""),
]
# frames skipped when finding who takes a contended lock
LOCK_FRAMES = re.compile(r"(_?_?raw_spin_lock|native_queued_spin_lock_slowpath|"
                         r"queued_spin_lock_slowpath|osq_lock|mutex_spin_on_owner|"
                         r"__mutex_lock|mutex_lock|mutex_trylock|rwsem_|down_read|"
                         r"down_write|raw_spin_rq_lock)")
SPIN_LEAVES = {"native_queued_spin_lock_slowpath", "queued_spin_lock_slowpath",
               "osq_lock", "mutex_spin_on_owner", "rwsem_spin_on_owner"}
ENTRY_FRAMES = {"ret_from_fork_asm", "ret_from_fork", "kthread",
                "entry_SYSCALL_64_after_hwframe", "do_syscall_64", "x64_sys_call"}
PATHS = [  # (name, any of these functions in the stack)
    ("zio pipeline (zio_execute)", {"zio_execute", "__zio_execute"}),
    ("  write compress stage (zio_write_compress)", {"zio_write_compress"}),
    ("    lz4 compression (lz4_compress_zfs)", {"lz4_compress_zfs"}),
    ("  checksums (zio_checksum_compute)", {"zio_checksum_compute"}),
    ("  allocation (metaslab_alloc)", {"metaslab_alloc"}),
    ("  vdev queue (vdev_queue_io, vdev_queue_io_done)", {"vdev_queue_io", "vdev_queue_io_done"}),
    ("taskq dispatch (taskq_dispatch_ent, taskq_dispatch)", {"taskq_dispatch_ent", "taskq_dispatch"}),
    ("syncing thread (spa_sync)", {"spa_sync"}),
    ("dnode/dbuf sync tasks (sync_dnodes_task)", {"sync_dnodes_task"}),
    ("space accounting (dsl_dir_diduse_*, dsl_dir_willuse_space, "
     "dsl_dir_tempreserve_*, dsl_dir_transfer_space)",
     {"dsl_dir_diduse_space", "dsl_dir_diduse_transfer_space", "dsl_dir_willuse_space",
      "dsl_dir_tempreserve_space", "dsl_dir_tempreserve_impl", "dsl_dir_tempreserve_clear",
      "dsl_dir_transfer_space"}),
    ("block born/kill (dsl_dataset_block_born/kill)",
     {"dsl_dataset_block_born", "dsl_dataset_block_kill"}),
    ("tx assign (dmu_tx_assign)", {"dmu_tx_assign"}),
    ("write syscalls (zfs_write)", {"zfs_write"}),
    ("read syscalls (zfs_read)", {"zfs_read"}),
    ("fsync / ZIL commit (zil_commit)", {"zil_commit"}),
    ("ZIL log records (zfs_log_write)", {"zfs_log_write"}),
    ("ARC eviction (arc_evict)", {"arc_evict", "arc_evict_state"}),
]


def module_funcs():
    mods = {}
    with open("/proc/kallsyms") as f:
        for line in f:
            p = line.split()
            if len(p) >= 4 and p[3] in ("[zfs]", "[spl]"):
                mods[p[2]] = p[3]
    return mods


def samples(data):
    """(comm, time, frames leaf first) of every sample."""
    cmd = ["sudo", PERF, "script", "-f", "-i", data, "--kallsyms=/proc/kallsyms",
           "-F", "comm,tid,time,ip,sym"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, errors="replace")
    comm, t, frames = None, None, []
    for line in p.stdout:
        if line.startswith("\t"):
            f = line.split(None, 1)
            frames.append(f[1].strip() if len(f) > 1 else "[unknown]")
        elif not line.strip():
            if comm is not None:
                yield comm, t, frames
            comm, t, frames = None, None, []
        else:
            m = re.match(r"\s*(.*?)\s+(\d+)\s+(\d+\.\d+):", line)
            if m:
                comm, t = m.group(1), float(m.group(3))
    if comm is not None:
        yield comm, t, frames
    p.wait()


def lock_callers(path):
    """{(caller, type): [contended, total wait s]} of perf lock contention -v."""
    unit = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600}
    out = collections.defaultdict(lambda: [0, 0.0])
    for line in open(path):
        m = re.match(r"\s+(\d+)\s+([\d.]+) (\w+)\s+[\d.]+ \w+\s+[\d.]+ \w+\s+(\S+)\s+(\S+)$", line)
        if m and m.group(3) in unit:
            e = out[(m.group(5).split("+")[0], m.group(4))]
            e[0] += int(m.group(1))
            e[1] += float(m.group(2)) * unit[m.group(3)]
    return out


def group(comm):
    for name, rx in GROUPS:
        if re.match(rx, comm):
            return name
    return "other"


def main():
    data = sys.argv[1]
    ntop = 10
    mods = module_funcs()
    n = 0
    t0 = t1 = None
    by_group, zfs_by_group = collections.Counter(), collections.Counter()
    incl, paths, spin = collections.Counter(), collections.Counter(), collections.Counter()
    stacks = collections.Counter()
    for comm, t, frames in samples(data):
        n += 1
        t0 = t if t0 is None else min(t0, t)
        t1 = t if t1 is None else max(t1, t)
        g = group(comm)
        by_group[g] += 1
        fset = set(frames)
        zf = [f for f in frames if f in mods]
        if zf:
            zfs_by_group[g] += 1
            for f in set(zf):
                incl[f] += 1
            # kernel frames root first, without the thread/syscall entry frames
            st = [f for f in reversed(frames) if f not in ENTRY_FRAMES]
            first_k = next((i for i, f in enumerate(st) if f in mods), 0)
            stacks[(g, ";".join(st[max(first_k - 1, 0):]))] += 1
        for name, funcs in PATHS:
            if fset & funcs:
                paths[name] += 1
        if frames and frames[0] in SPIN_LEAVES:
            caller = next((f for f in frames if not LOCK_FRAMES.match(f)), "[unknown]")
            spin[(caller, "zfs/spl" if caller in mods else "")] += 1
    if not n:
        sys.exit("no samples")
    win = t1 - t0
    hz = n / win / os.cpu_count()

    def pct(c):
        return f"{100 * c / n:5.1f}%  {c / win / hz:5.2f} CPUs"

    busy = n - by_group["idle"]
    zfs_all = sum(zfs_by_group.values())
    print(f"{n} samples, {win:.1f} s, {os.cpu_count()} CPUs, {hz:.0f} Hz per CPU; "
          f"busy (not idle) {100 * busy / n:.1f}%, with a zfs/spl frame {100 * zfs_all / n:.1f}% "
          f"({100 * zfs_all / busy:.1f}% of busy)\n")
    print("## Thread groups: all samples | samples with a zfs/spl frame")
    for g, c in by_group.most_common():
        print(f"{pct(c)}  | {pct(zfs_by_group[g])}  {g}")
    print("\n## Code paths (inclusive: a frame anywhere in the stack)")
    for name, _ in PATHS:
        print(f"{pct(paths[name])}  {name}")
    print("\n## zfs/spl functions, inclusive (top 30)")
    for f, c in incl.most_common(30):
        print(f"{pct(c)}  {f} {mods[f]}")
    print("\n## Spinning on a lock (leaf in a spin/mutex slow path), by the function taking it (top 15)")
    tot = sum(spin.values())
    print(f"{pct(tot)}  all")
    for (f, m), c in spin.most_common(15):
        print(f"{pct(c)}  {f} {m}")
    print(f"\n## Top {ntop} call stacks with a zfs/spl frame (kernel part, root first)")
    for (g, st), c in stacks.most_common(ntop):
        print(f"{pct(c)}  [{g}]\n    {st}")
    if len(sys.argv) > 2:
        locks = lock_callers(sys.argv[2])
        print(f"\n## Lock contention (perf lock contention, {sys.argv[2].rsplit('/', 1)[-1]}): "
              "contended acquisitions per caller, top 12 by count")
        print(" contended  per s   total wait  type      caller")
        for (caller, typ), (c, w) in sorted(locks.items(), key=lambda kv: -kv[1][0])[:12]:
            print(f"{c:10d} {c / 60:7.0f} {w:9.1f} s  {typ:9} {caller}")


if __name__ == "__main__":
    main()
