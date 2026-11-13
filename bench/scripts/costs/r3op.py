#!/usr/bin/env python3
"""EVAL_PLAN R3 (§6.5 Costs): one step of run_r3.sh or run_r3_drop.sh.

  r3op.py create <path> <bytes>            a plain file: sequential 1 MiB writes, fsync
  r3op.py overwrite <path> <bytes> [--tau] rewrite it in place, 1 MiB writes, fsync
                                           (--tau: opened with O_TAU_UNTORN)
  r3op.py usage <devname>                  used segments of the tau journal on
                                           /dev/<devname>, "-" without one
  r3op.py vmstat                           the reclaim counters (measure --vm0)
  r3op.py measure ...                      (root) one timed operation, see below

measure: --op truncate (ftruncate(fd, 0)), unlink (unlink(path), the file closed
first, so its eviction runs inside the call) or cmd (a shell command, e.g. a
DROP TABLE through the database's client; its stdout is kept).  Around it:

  * the block layer's writes to the test device (tracefs block_rq_issue, trace
    clock mono; on an NVMe multipath head, whose path disks have no dev_t in
    sysfs, block_bio_remap of the head's bios instead), split by time into the call ("sync": from its start to its
    return) and after it ("after": to the end of the window), and by place: "home"
    is a write to the blocks the files (--path, --home) had before the call
    (FIEMAP), "reuse" such a write once the host has committed after the call
    (ext4: the freed blocks may be another file's by then; XFS has no commit
    event here, so all of it stays "home"), the rest ("other") is the journals
    and the file system's metadata.  The
    traced bytes are checked against the device's own counter
    (/sys/block/<statdev>/stat).
  * the tau journal's usage (tau_journal_usage, segments used of the journal on
    the device) before, after and as a time series, and, with --used-base, the
    time until the used segments are back at that count, give or take the one
    segment the call's own commit may keep ("seg_return_ms": the segments of the
    data the call made obsolete given back).
  * the host journal's commits (jbd2 end_commit tracepoint, ext4) after the call.
  * the tau probe counters (CONFIG_TAU_PROBE_TORN), when the kernel has them.

The window ends --after-min s after the call at the earliest, and only once the
segments are back (or --seg-timeout s passed); then a syncfs of the mount, so the
host's deferred metadata is in it too (and before the call a syncfs, so the
host's earlier metadata is not).  The segments come back once the host has
the free or the unlink on disk: by default that is the host's own commit (ext4:
jbd2, 5 s; XFS: the log worker, up to 30 s); --after-sync calls syncfs right
after the call instead, which leaves tau's own part (the next journald pass).
"reclaim" lists the /proc/vmstat reclaim counters that moved between --vm0 (or
the start) and the call: a shrinker scan makes tau checkpoint the oldest tx
whole, so a res1g run with one is void (also the probes shrink_scan, cpq_*).  Before the call, the device has to be
quiet for 1 s (at most --quiet-max s of waiting).  One JSON object on stdout.
"""
import argparse
import bisect
import ctypes
import errno
import fcntl
import json
import os
import re
import struct
import subprocess
import sys
import time

O_TAU_UNTORN = 0o40000000
CHUNK = 1 << 20
TRACEFS = next((d for d in ("/sys/kernel/tracing", "/sys/kernel/debug/tracing")
                if os.path.isdir(d + "/instances")), None)
TAU_PARAMS = "/sys/module/tau_journal/parameters"
INSTANCE = "r3op"


def mono_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


# ---------------------------------------------------------------- files

def cmd_create(a):
    buf = b"\x5a" * CHUNK
    fd = os.open(a.path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        left = a.bytes
        while left > 0:
            left -= os.write(fd, buf[:min(left, CHUNK)])
        os.fsync(fd)
    finally:
        os.close(fd)


def cmd_overwrite(a):
    buf = b"\xa5" * CHUNK
    t0 = mono_ns()
    fd = os.open(a.path, os.O_WRONLY | (O_TAU_UNTORN if a.tau else 0))
    try:
        off = 0
        while off < a.bytes:
            off += os.pwrite(fd, buf[:min(a.bytes - off, CHUNK)], off)
        t1 = mono_ns()
        os.fsync(fd)
    finally:
        os.close(fd)
    t2 = mono_ns()
    print(json.dumps({"write_ms": round((t1 - t0) / 1e6, 1), "fsync_ms": round((t2 - t1) / 1e6, 1),
                      "end_ns": t2}))


def fiemap(fd):
    """[(physical byte offset, length)] of the file's mapped extents, merged."""
    FS_IOC_FIEMAP = 0xC020660B
    n = 4096
    out, start = [], 0
    while True:
        # no FIEMAP_FLAG_SYNC: writing a tau file's dirty pages back would be a
        # checkpoint of what the journal holds
        hdr = struct.pack("=QQLLLL", start, 0xFFFFFFFFFFFFFFFF, 0, 0, n, 0)
        buf = bytearray(hdr + b"\0" * (56 * n))
        fcntl.ioctl(fd, FS_IOC_FIEMAP, buf)
        mapped = struct.unpack_from("=L", buf, 20)[0]
        last = False
        for i in range(mapped):
            lo, ph, ln, _, _, fl = struct.unpack_from("=QQQQQL", buf, 32 + 56 * i)
            out.append((ph, ln))
            start = lo + ln
            last = bool(fl & 1)  # FIEMAP_EXTENT_LAST
        if mapped < n or last:
            break
    out.sort()
    merged = []
    for ph, ln in out:
        if merged and merged[-1][0] + merged[-1][1] == ph:
            merged[-1] = (merged[-1][0], merged[-1][1] + ln)
        else:
            merged.append((ph, ln))
    return merged


# ---------------------------------------------------------------- counters

def tau_usage(devname):
    """(used, free, total, seg_mb) of the tau journal on devname, or None."""
    try:
        with open(TAU_PARAMS + "/tau_journal_usage") as f:
            for line in f:
                w = line.split()
                if w and w[0].startswith(devname + "-"):
                    kv = dict(zip(w[1::2], w[2::2]))
                    return (int(kv["used"]), int(kv["free"]), int(kv["total"]), int(kv["seg_mb"]))
    except OSError:
        pass
    return None


def cmd_usage(a):
    u = tau_usage(a.devname)
    print("-" if u is None else u[0])


def probes():
    """tau_probe_* counters, {} on a kernel without CONFIG_TAU_PROBE_TORN."""
    out = {}
    try:
        names = os.listdir(TAU_PARAMS)
    except OSError:
        return out
    for n in names:
        if n.startswith("tau_probe_"):
            try:
                with open(f"{TAU_PARAMS}/{n}") as f:
                    out[n[10:]] = int(f.read())
            except (OSError, ValueError):
                pass
    return out


VMSTAT_KEYS = ("slabs_scanned", "pgscan_kswapd", "pgscan_direct", "drop_slab", "drop_pagecache",
               "pgsteal_kswapd", "pgsteal_direct")


def vmstat():
    """reclaim counters: a shrinker scan (kswapd, direct reclaim, drop_caches 2/3)
    makes tau checkpoint the oldest tx whole (journal.c tau_checkpoint_policy)"""
    out = {}
    with open("/proc/vmstat") as f:
        for line in f:
            k, v = line.split()
            if k in VMSTAT_KEYS:
                out[k] = int(v)
    return out


def cmd_vmstat(a):
    print(" ".join(f"{k}={v}" for k, v in vmstat().items()))


def devstat_sectors(statdevs):
    """sectors written, summed over the devices that account the test SSD's I/O"""
    tot = 0
    for d in statdevs:
        with open(f"/sys/block/{d}/stat") as f:
            tot += int(f.read().split()[6])
    return tot


def dev_t(name):
    try:
        with open(f"/sys/class/block/{name}/dev") as f:
            ma, mi = f.read().strip().split(":")
        return (int(ma) << 20) | int(mi), f"{ma},{mi}"
    except OSError:
        return None, None


def part_start_sectors(devname):
    try:
        with open(f"/sys/class/block/{devname}/start") as f:
            return int(f.read())
    except OSError:
        return 0


# ---------------------------------------------------------------- tracefs

def tw(path, val):
    with open(f"{TRACEFS}/instances/{INSTANCE}/{path}", "w") as f:
        f.write(val)


def trace_setup(devs, head, jbd2_dev):
    """devs: the dev_t of every device that issues the test SSD's requests, or
    None when one of them is hidden (an NVMe multipath path: no dev in sysfs, its
    requests carry a dev_t nothing names); then the head's bios are traced where
    multipath sends them to a path (block_bio_remap, old_dev = the head)"""
    inst = f"{TRACEFS}/instances/{INSTANCE}"
    if not os.path.isdir(inst):
        os.mkdir(inst)
    tw("tracing_on", "0")
    tw("trace_clock", "mono")
    tw("buffer_size_kb", "2048")
    tw("trace", "")
    if devs is None:
        tw("events/block/block_bio_remap/filter", f"old_dev == {head}")
        tw("events/block/block_bio_remap/enable", "1")
    else:
        tw("events/block/block_rq_issue/filter", " || ".join(f"dev == {d}" for d in devs))
        tw("events/block/block_rq_issue/enable", "1")
    have_jbd2 = os.path.isdir(f"{inst}/events/jbd2/jbd2_end_commit")
    if have_jbd2:
        tw("events/jbd2/jbd2_end_commit/filter", f"dev == {jbd2_dev}")
        tw("events/jbd2/jbd2_end_commit/enable", "1")
    tw("tracing_on", "1")
    return have_jbd2


def trace_collect():
    inst = f"{TRACEFS}/instances/{INSTANCE}"
    tw("tracing_on", "0")
    with open(f"{inst}/trace") as f:
        text = f.read()
    overrun = 0
    for c in os.listdir(f"{inst}/per_cpu"):
        try:
            with open(f"{inst}/per_cpu/{c}/stats") as f:
                for line in f:
                    if line.startswith("overrun:"):
                        overrun += int(line.split()[1])
        except OSError:
            pass
    for ev in ("block/block_rq_issue", "block/block_bio_remap", "jbd2/jbd2_end_commit"):
        if os.path.isdir(f"{inst}/events/{ev}"):
            tw(f"events/{ev}/enable", "0")
    os.rmdir(inst)   # its ring buffers go with it
    return text, overrun


RQ = re.compile(r"\s(\d+\.\d+): block_rq_issue: (\d+),(\d+) (\S+) (\d+) \([^)]*\) (\d+) \+ (\d+)")
# multipath: "<path dev> <rwbs> <sector> + <nr_sector> <- (<head dev>) <head sector>"
RM = re.compile(r"\s(\d+\.\d+): block_bio_remap: \d+,\d+ (\S+) \d+ \+ (\d+) <- \(\d+,\d+\) (\d+)")
JC = re.compile(r"\s(\d+\.\d+): jbd2_end_commit: dev (\d+),(\d+) transaction (\d+)")


def classify(text, t0, t1, home, part0):
    """bytes by window (pre/sync/after) and place (home/reuse/other); flush (a
    preflush or a flush request) and FUA counts; "reuse": a write to the old
    blocks after the host's first commit after the call -- ext4 gives freed
    blocks out again only once the free is committed, so from then on such a
    write is another file's (a database's own writes after a DROP), not tau's;
    the jbd2 commits' end times (ns)"""
    starts = [s for s, _ in home]
    res = {w: {"home": 0, "reuse": 0, "other": 0, "reqs": 0, "flush": 0, "fua": 0}
           for w in ("pre", "sync", "after")}
    commits = []
    for line in text.splitlines():   # the commits first: the reuse boundary
        m = JC.search(line)
        if m:
            commits.append((int(round(float(m.group(1)) * 1e9)), int(m.group(4))))
    reuse_from = next((ts for ts, _ in commits if ts > t1), None)
    for line in text.splitlines():
        m = RQ.search(line)
        if m:
            ts, rwbs, nbytes, sector = (int(round(float(m.group(1)) * 1e9)), m.group(4),
                                        int(m.group(5)), int(m.group(6)))
        else:
            m = RM.search(line)
            if m:
                ts, rwbs, nbytes, sector = (int(round(float(m.group(1)) * 1e9)), m.group(2),
                                            int(m.group(3)) * 512, int(m.group(4)))
        if m:
            w = "pre" if ts < t0 else ("sync" if ts <= t1 else "after")
            # blk_fill_rwbs(): [F: REQ_PREFLUSH] op (W R D N, F = REQ_OP_FLUSH) [F: REQ_FUA] [A][S][M]
            pre = len(rwbs) > 1 and rwbs[0] == "F" and rwbs[1] in "WRDNF"
            op = rwbs[1 if pre else 0] if rwbs else ""
            if pre or op == "F":
                res[w]["flush"] += 1
            if rwbs[2 if pre else 1:][:1] == "F":
                res[w]["fua"] += 1
            if op != "W" or nbytes == 0:
                continue
            res[w]["reqs"] += 1
            lo = (sector - part0) * 512
            hi = lo + nbytes
            ov = 0
            i = max(bisect.bisect_right(starts, lo) - 1, 0)
            while i < len(home) and home[i][0] < hi:
                s, ln = home[i]
                ov += max(0, min(hi, s + ln) - max(lo, s))
                i += 1
            res[w]["reuse" if reuse_from is not None and ts > reuse_from else "home"] += ov
            res[w]["other"] += nbytes - ov
    return res, commits


# ---------------------------------------------------------------- measure

def syncfs(path):
    libc = ctypes.CDLL(None, use_errno=True)
    fd = os.open(path, os.O_RDONLY)
    try:
        if libc.syncfs(fd) != 0:
            raise OSError(ctypes.get_errno(), "syncfs")
    finally:
        os.close(fd)


def cmd_measure(a):
    statdevs = a.statdevs.split()
    devs = []
    for n in [a.dev] + statdevs:
        d, _ = dev_t(n)
        if d is None:          # a hidden multipath path: trace the head's remaps
            devs = None
            break
        if d not in devs:
            devs.append(d)
    jbd2_dev, _ = dev_t(a.dev)
    part0 = part_start_sectors(a.dev)
    out = {"op": a.op, "path": a.path, "tau_open": a.tau, "read_first": a.read,
           "trace_event": "block_bio_remap" if devs is None else "block_rq_issue"}
    out.update(dict(kv.split("=", 1) for kv in a.label))

    # the file, opened (and read) before anything is measured
    fd = None
    home = []
    if a.op in ("truncate", "unlink"):
        fd = os.open(a.path, os.O_RDWR | (O_TAU_UNTORN if a.tau else 0))
        out["file_bytes"] = os.fstat(fd).st_size
        if a.read:
            t = mono_ns()
            while os.read(fd, CHUNK):
                pass
            out["read_ms"] = round((mono_ns() - t) / 1e6, 1)
        home = fiemap(fd)
        if a.op == "unlink":
            os.close(fd)
            fd = None
    for p in a.home:
        try:
            hfd = os.open(p, os.O_RDONLY)
        except OSError:
            continue
        try:
            home += fiemap(hfd)
        finally:
            os.close(hfd)
    home.sort()
    out["home_extents"] = len(home)
    out["home_bytes_mapped"] = sum(ln for _, ln in home)

    # the host's pending metadata out first (a remount's journal segments, the
    # overwrite's inode): a syncfs commits, it does not checkpoint tau (tau_sync_all)
    t = mono_ns()
    syncfs(a.mnt)
    out["pre_syncfs_ms"] = round((mono_ns() - t) / 1e6, 1)
    pr0 = probes()
    vm0 = dict(kv.split("=") for kv in a.vm0.split()) if a.vm0 else vmstat()
    u0 = tau_usage(a.dev)
    # quiet: no write reached the device for 1 s
    tq = mono_ns()
    prev = devstat_sectors(statdevs)
    while True:
        time.sleep(1)
        cur = devstat_sectors(statdevs)
        if cur == prev or mono_ns() - tq > a.quiet_max * 1e9:
            break
        prev = cur
    out["quiet_wait_s"] = round((mono_ns() - tq) / 1e9, 1)
    out["quiet"] = cur == prev

    have_jbd2 = trace_setup(devs, jbd2_dev, jbd2_dev)
    vma = vmstat()
    pr_a = probes()
    ua = tau_usage(a.dev)
    sa = devstat_sectors(statdevs)
    cmd_out = None

    t0 = mono_ns()
    if a.op == "truncate":
        os.ftruncate(fd, 0)
    elif a.op == "unlink":
        os.unlink(a.path)
    else:
        r = subprocess.run(a.cmd, shell=True, capture_output=True, text=True)
        cmd_out = (r.stdout + r.stderr)[-4000:]
        out["cmd_rc"] = r.returncode
    t1 = mono_ns()

    sb = devstat_sectors(statdevs)
    ub = tau_usage(a.dev)
    pr_b = probes()
    if fd is not None:
        os.close(fd)
    if a.after_sync:   # the host commit now: the segments' return without the host's own period
        t = mono_ns()
        syncfs(a.mnt)
        out["after_syncfs_ms"] = round((mono_ns() - t) / 1e6, 1)

    # after the call: segments back, host commit, the window's minimum
    # "back": at most one segment over the count before the overwrite -- the
    # call's own commit (a truncate's tags) may keep one
    series = [(0, ub[0])] if ub else []
    seg_ret = None
    back = None if a.used_base is None else a.used_base + 1
    want_back = ub is not None and back is not None and ub[0] > back
    if ub is not None and back is not None and ub[0] <= back:
        seg_ret = 0.0
    while True:
        now = mono_ns()
        el = (now - t1) / 1e9
        u = tau_usage(a.dev) if ub else None
        if u and series and u[0] != series[-1][1]:
            series.append((round(el * 1000), u[0]))
        if want_back and seg_ret is None and u and u[0] <= back:
            seg_ret = round(el * 1000, 1)
        done_seg = (not want_back) or seg_ret is not None or el > a.seg_timeout
        if done_seg and el >= a.after_min:
            break
        time.sleep(0.01)
    t_sync = mono_ns()
    syncfs(a.mnt)
    out["syncfs_ms"] = round((mono_ns() - t_sync) / 1e6, 1)
    time.sleep(0.5)
    sc = devstat_sectors(statdevs)
    uc = tau_usage(a.dev)
    pr_c = probes()
    text, overrun = trace_collect()
    t_end = mono_ns()

    res, commits = classify(text, t0, t1, home, part0)
    out["lat_ms"] = round((t1 - t0) / 1e6, 3)
    out["after_sync"] = a.after_sync
    if a.since_ns:
        out["age_at_call_s"] = round((t0 - a.since_ns) / 1e9, 1)
    # reclaim between the start (or --vm0: before the overwrite) and the call
    out["reclaim"] = {k: vma[k] - int(vm0.get(k, vma[k])) for k in vma if vma[k] != int(vm0.get(k, vma[k]))}
    for w in ("sync", "after"):
        for k, v in res[w].items():
            out[f"{w}_{k}" + ("_bytes" if k in ("home", "reuse", "other") else "")] = v
    out["pre_reqs"] = res["pre"]["reqs"]
    out["dev_sync_bytes"] = (sb - sa) * 512
    out["dev_after_bytes"] = (sc - sb) * 512
    traced = sum(res[w]["home"] + res[w]["reuse"] + res[w]["other"] for w in ("pre", "sync", "after"))
    out["traced_bytes"] = traced
    out["trace_overrun"] = overrun
    # the trace has to account for what the device counted (both include every
    # write to it; anything else means the tracepoint filter missed a path node)
    out["trace_ok"] = overrun == 0 and abs(traced - (sc - sa) * 512) <= max(0.02 * (sc - sa) * 512, 65536)
    out["window_s"] = round((t_end - t0) / 1e9, 2)
    if have_jbd2:
        after = [(ts, tid) for ts, tid in commits if ts > t1]
        out["host_commit_ms"] = round((after[0][0] - t1) / 1e6, 1) if after else None
        out["host_commits"] = len(after)
    if u0:
        out["seg_mb"] = u0[3]
        out["used_base"] = a.used_base
        out["used_before"] = ua[0]
        out["used_after_call"] = ub[0]
        out["used_end"] = uc[0]
        out["total_end"] = uc[2]
        if a.used_base is not None:
            out["resident_mib"] = (ua[0] - a.used_base) * u0[3]
        out["seg_return_ms"] = seg_ret
        out["seg_released"] = ub[0] - min([ub[0], uc[0]] + [u for _, u in series])
        out["used_series"] = series[:200]
    if pr0:
        def delta(x, y):
            return {k: y[k] - x.get(k, 0) for k in y if y[k] != x.get(k, 0)}
        out["probe_settle"] = delta(pr0, pr_a)   # between opening the file and the call
        out["probe_call"] = delta(pr_a, pr_b)    # during the call
        out["probe_after"] = delta(pr_b, pr_c)   # the after window
    if cmd_out is not None:
        out["cmd_out"] = cmd_out
        if a.server_re:   # the server's own time for the statement, from the client's output
            m = re.search(a.server_re, cmd_out, re.M)
            out["server_ms"] = float(m.group(1)) if m else None
    print(json.dumps(out, sort_keys=True))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    s = p.add_subparsers(dest="what", required=True)
    c = s.add_parser("create"); c.add_argument("path"); c.add_argument("bytes", type=int)
    c = s.add_parser("overwrite"); c.add_argument("path"); c.add_argument("bytes", type=int)
    c.add_argument("--tau", action="store_true")
    c = s.add_parser("usage"); c.add_argument("devname")
    c = s.add_parser("vmstat")
    c = s.add_parser("measure")
    c.add_argument("--op", choices=("truncate", "unlink", "cmd"), required=True)
    c.add_argument("--path", default="")
    c.add_argument("--cmd", default="")
    c.add_argument("--home", nargs="*", default=[], help="more files whose blocks count as home")
    c.add_argument("--tau", action="store_true", help="open the file with O_TAU_UNTORN")
    c.add_argument("--read", action="store_true", help="read the file first (page cache warm)")
    c.add_argument("--dev", required=True, help="the test device, e.g. nvme0n1")
    c.add_argument("--statdevs", required=True, help="devices that count its I/O (common.sh tau_stat_devs)")
    c.add_argument("--mnt", required=True)
    c.add_argument("--used-base", type=int, default=None)
    c.add_argument("--after-min", type=float, default=6.0)
    c.add_argument("--seg-timeout", type=float, default=120.0)
    c.add_argument("--quiet-max", type=float, default=30.0)
    c.add_argument("--after-sync", action="store_true", help="syncfs right after the call")
    c.add_argument("--server-re", default="", help="--op cmd: regex whose group 1 is the server's ms")
    c.add_argument("--since-ns", type=int, default=0, help="CLOCK_MONOTONIC ns of the overwrite's end")
    c.add_argument("--vm0", default="", help="r3op.py vmstat output from before the overwrite")
    c.add_argument("--label", nargs="*", default=[], help="k=v pairs copied into the output")
    a = p.parse_args()
    if a.what == "measure":
        if os.geteuid() != 0:
            sys.exit("r3op.py measure: needs root (tracefs)")
        if TRACEFS is None:
            sys.exit("r3op.py measure: no tracefs")
        if a.op in ("truncate", "unlink") and not a.path:
            sys.exit("r3op.py measure: --path")
        if a.op == "cmd" and not a.cmd:
            sys.exit("r3op.py measure: --cmd")
    {"create": cmd_create, "overwrite": cmd_overwrite, "usage": cmd_usage, "vmstat": cmd_vmstat,
     "measure": cmd_measure}[a.what](a)


if __name__ == "__main__":
    main()
