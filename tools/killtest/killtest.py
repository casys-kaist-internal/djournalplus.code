#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
killtest -- the SOSP-round QEMU kill experiment, as a tool of this tree.

Ported from taujournal-test.code (scripts/exp.sh, scripts/exp/run.exp and
run_<fs>.exp, tests/src/fs.c).  One trial:

  1. boot a VM whose test disk is an emulated NVMe backed by a host file
     (QEMU's default cache=writeback); cap its requests at 4 KiB
     (max_sectors_kb), format it, lay zeros over 32 files and check them;
  2. start the overwrite -- 32 threads writing a pattern in 16 KiB pwrite()s,
     fsync every 8 -- and SIGKILL QEMU a fixed time (WAIT_MS) later;
  3. boot again, mount (the file system's recovery runs here) and check every
     16 KiB chunk: all zeros or all pattern, anything else is a torn write.

  killtest.py probe   [--kernel K]                 what the guest sees
  killtest.py run     --fs ext4 --workload seq --trials 100
  killtest.py db      --db postgres --fs ext4 [--profile revision]
  killtest.py summary RESULT_DIR...

As in the SOSP round, a trial is torn when the verifier prints "torn write(s)
detected".  The summary reads the same way ("torn X/N"), adds a Wilson
interval, the shape of every torn chunk and how far the workload had got.
README.md says what this crash model can and cannot produce.

Runs as an ordinary user (kvm group); only mkrootfs.sh, run once, needs sudo.
"""
import argparse
import json
import math
import mmap
import os
import random
import re
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WORK = Path(os.environ.get("KILLTEST_WORK", HERE / "work"))
# results per machine (the rates depend on the host): results/<hostname -s>/
RESULTS = Path(os.environ.get(
    "KILLTEST_RESULTS", HERE / "results" / os.uname().nodename.split(".")[0]))
# The SOSP round ran QEMU 9.2.4; mkqemu.sh builds it into WORK.  Without it,
# the tree's own 7.2.1.
QEMU = os.environ.get("QEMU") or next(
    (str(q) for q in (WORK / "qemu-9.2.4/bin/qemu-system-x86_64",
                      ROOT / "tools/bin/qemu-system-x86_64") if q.exists()),
    "qemu-system-x86_64")
ROOTFS = WORK / "rootfs.img"
STOCK = ROOT / "bench/workspace/stock"

# The SOSP round booted vanilla v6.8 (6.8.0-ge8f897f4afef) for the baselines
# and the tau kernel for tau.  /boot/vmlinuz-6.8.0+ is vanilla 6.8 with
# /boot/config-6.8.0+, the baseline kernel of the revision's runs.
BASE_KERNEL = "/boot/vmlinuz-6.8.0+"
# the tau kernel and mkfs forks: submodules under codes/ (set_env.sh)
KERNEL_SRC = Path(os.environ.get("TAUFS_KERNEL",
                                 ROOT / "codes/djournalplus-kernel.code"))
E2FSPROGS = Path(os.environ.get("TAUFS_E2FSPROGS", ROOT / "codes/e2fsprogs"))
XFSPROGS = Path(os.environ.get("TAUFS_XFSPROGS", ROOT / "codes/xfsprogs-dev"))
TAU_KERNEL = str(KERNEL_SRC / "arch/x86/boot/bzImage")

# tau-aware tools for the tau configurations; the rootfs carries only stock ones
TAU_TOOLS = {
    "mke2fs": E2FSPROGS / "misc/mke2fs",
    "e2fsck": E2FSPROGS / "e2fsck/e2fsck",
    "mkfs.xfs": XFSPROGS / "mkfs/mkfs.xfs",
    "xfs_repair": XFSPROGS / "repair/xfs_repair",
}

SOSP_TEST_OPT = "-t 32 -s 8M -b 16K -F 8"       # run.exp TEST_OPT_DFT
# kernel lines kept in the record: the test device's, the journals', tau's
DMESG_PAT = r"nvme0n1|nvme nvme0|jbd2|tau[_ :]|tjournal|ZFS|zfs|I/O error|recover"

# One entry per scripts/exp/run_<fs>.exp of the SOSP round, with the same
# mkfs, mount, TEST_OPT and WAIT_MS.  fsck is new and is information only.
FSCONF = {
    "ext4": dict(
        sosp="run_ext4.exp",
        mkfs="mkfs.ext4 -F $TEST_DEV",
        mount="mount -t ext4 $TEST_DEV $TEST_DIR",
        test_opt="-t 32 -s 64M -b 16K -F 8", wait_ms=100,
        fsck="e2fsck -fn $TEST_DEV"),
    "ext4-dj": dict(
        sosp="run_ext4-dj.exp",
        mkfs="mkfs.ext4 -F $TEST_DEV",
        mount="mount -t ext4 -o data=journal $TEST_DEV $TEST_DIR",
        wait_ms=300,
        fsck="e2fsck -fn $TEST_DEV"),
    "xfs": dict(
        sosp="run_xfs.exp",
        mkfs="mkfs.xfs -f $TEST_DEV",
        mount="mount -t xfs $TEST_DEV $TEST_DIR",
        wait_ms=1000, modprobe="xfs",
        fsck="xfs_repair -n $TEST_DEV"),
    "f2fs": dict(
        sosp="run_f2fs.exp",
        mkfs="mkfs.f2fs -f $TEST_DEV",
        mount="mount -t f2fs $TEST_DEV $TEST_DIR",
        wait_ms=500, modprobe="f2fs",
        fsck="fsck.f2fs --dry-run $TEST_DEV"),
    "btrfs": dict(
        sosp="run_btrfs.exp",
        mkfs="mkfs.btrfs -f $TEST_DEV",
        mount="mount -t btrfs $TEST_DEV $TEST_DIR",
        wait_ms=1000, modprobe="btrfs",
        fsck="btrfs check --readonly $TEST_DEV"),
    # run_zfs-16k.exp created the pool and then set recordsize=16K,
    # mountpoint=/mnt/test and canmount=noauto; the same properties are given
    # at creation here, because the read-only rootfs has no room for the
    # pool's first automount at /zfspool.  cachefile=none for the same
    # reason; the pool comes back after the crash by import, as the SOSP
    # guest's zfs-import service did.
    "zfs-16k": dict(
        sosp="run_zfs-16k.exp",
        mkfs="zpool create -o cachefile=none -O recordsize=16K"
             " -O mountpoint=$TEST_DIR -O canmount=noauto zfspool $TEST_DEV -f",
        # zpool create mounts the dataset anyway; run.exp's `zfs mount`
        # then failed with "already mounted", which expect did not check
        mount="mountpoint -q $TEST_DIR || zfs mount zfspool",
        umount="zfs unmount $TEST_DIR",
        verify_mount="zpool import -o cachefile=none -N -f zfspool &&"
                     " zfs mount zfspool",
        wait_ms=1000, modprobe="zfs", udev=True,
        fsck="zpool scrub -w zfspool && zpool status -v zfspool"),
    # tau engages per file, so the workload opens its files O_TAU_UNTORN
    # (-T); run_taujournal.exp and run_xfs-tau.exp did not pass it.  Their
    # mkfs options (-J tau_journal_size=, -l tjsize=) no longer exist in the
    # forks, which create a tau journal by default.
    "tau-ext4": dict(
        sosp="run_taujournal.exp", tau=True,
        mkfs="/kt/tau/mke2fs -t ext4 -F $TEST_DEV",
        mount="mount -t ext4 -o tjournal $TEST_DEV $TEST_DIR",
        test_opt=SOSP_TEST_OPT + " -T", wait_ms=1000,
        fsck="/kt/tau/e2fsck -fn $TEST_DEV"),
    "tau-xfs": dict(
        sosp="run_xfs-tau.exp", tau=True,
        mkfs="/kt/tau/mkfs.xfs -f $TEST_DEV",
        mount="mount -t xfs -o tjournal $TEST_DEV $TEST_DIR",
        test_opt=SOSP_TEST_OPT + " -T", wait_ms=1000,
        fsck="/kt/tau/xfs_repair -n $TEST_DEV"),
}

WORKLOADS = ("seq", "rand", "rand_single", "append")

# ---- the DB test (exp_db.sh; bench/scripts/{common,sysbench/*,*/api}.sh at the
# SOSP round's commit 32f592b) ----------------------------------------------
#
# File systems as common.sh's do_mkfs/mount_fs made them for the databases.
DB_MKE2FS = "mke2fs -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F $TEST_DEV"


def _zfs_db(recordsize):
    # do_mkfs: zpool create -o ashift=12; mount_fs: recordsize, mountpoint.
    # Exported after preparation so that every trial imports it, as the
    # SOSP guest's restore did.
    return dict(
        mkfs="zpool create -o ashift=12 -o cachefile=none -O recordsize=%s"
             " -O mountpoint=$TEST_DIR -O canmount=noauto zfspool $TEST_DEV -f"
             % recordsize,
        mount_new="mountpoint -q $TEST_DIR || zfs mount zfspool",
        mount="zpool import -o cachefile=none -N -f zfspool && zfs mount zfspool",
        umount="zfs unmount $TEST_DIR && zpool export zfspool",
        modprobe="zfs", udev=True)


DBFSCONF = {
    "ext4": dict(mkfs=DB_MKE2FS, mount="mount -t ext4 $TEST_DEV $TEST_DIR"),
    "ext4-dj": dict(mkfs=DB_MKE2FS,
                    mount="mount -t ext4 -o data=journal $TEST_DEV $TEST_DIR"),
    "xfs": dict(mkfs="mkfs.xfs -f $TEST_DEV",
                mount="mount -t xfs $TEST_DEV $TEST_DIR", modprobe="xfs"),
    "zfs-8k": _zfs_db("8k"),       # run.sh paired PostgreSQL with zfs-8k
    "zfs-16k": _zfs_db("16k"),     # and MySQL with zfs-16k
}

# The SOSP round's settings: create_image.sh (16M rows over 32 tables, about
# 4 GB; PostgreSQL initdb --data-checksums), run.sh "persist" (oltp_write_only,
# 32 threads, 10 s warm-up; full_page_writes off with max_wal_size 2GB; MySQL
# doublewrite off, buffer pool 16G), create.exp (a 300 s run before the image
# is kept) and run.exp (kill 60 s + WAIT_MS 1000 into the measured run).
DB_SOSP = dict(
    dbname="sbtest_s200", tables=32, rows=16000000 // 32, threads=32,
    workload="oltp_write_only", warmup_s=10, age_s=300, run_s=300, rerun_s=30,
    wait_ms=61000,
    pg_conf="full_page_writes = off\\nmax_wal_size = 2GB",
    pg_cow_conf="",
    my_opts="--innodb_buffer_pool_size=16G --innodb-doublewrite=0",
    my_init_opts="", test_size=16, kill_on="time",
    rand_type="",                     # sysbench's default, special
    zfs_logbias=None, zfs_log_dataset=False)    # one dataset, logbias latency

# The revision's settings (bench/scripts/{postgres,mysql}/api.sh and
# sysbench/run_main.sh), with the caches at 25% of the VM's memory ({cache})
# as they are at 25% of the host's: 16 GB of WAL and of redo, MySQL on
# buffered I/O (flush method fsync) without a binary log or redo spin-waits,
# PostgreSQL without WAL zero-fill and recycling on ZFS.  The protection
# stays off, as in the SOSP round.  The image is prepared with them -- MySQL's
# redo at its run-time capacity from --initialize on, as create_image.sh does.
# The run is long enough for PostgreSQL's first timed checkpoint (5 min after
# the server starts), and the kill comes during writeback (--kill-on).
DB_REVISION = dict(
    DB_SOSP, run_s=600,
    pg_conf="full_page_writes = off\\nshared_buffers = {cache}MB"
            "\\nmax_wal_size = 16GB\\nlog_checkpoints = on",
    pg_cow_conf="\\nwal_init_zero = off\\nwal_recycle = off",
    my_opts="--innodb_buffer_pool_size={cache}M --innodb_redo_log_capacity=16G"
            " --innodb_flush_method=fsync --innodb-doublewrite=0"
            " --innodb_log_spin_cpu_pct_hwm=0 --disable-log-bin",
    my_init_opts="--innodb_redo_log_capacity=16G",
    # data, 16 GB of redo created up front (fallocate: no data written), WAL
    test_size=40, kill_on="writeback",
    # ZFS as common.sh's do_mkfs makes it (the OpenZFS workload tuning
    # guide's layout): the data with logbias=throughput, the WAL/redo in
    # zfspool/log at the defaults (recordsize 128K, logbias latency)
    zfs_logbias="throughput", zfs_log_dataset=True)
DB_PROFILES = {"sosp": DB_SOSP, "revision": DB_REVISION}

# --kill-on writeback (guest: src/ktwatch.c).  The kill comes the first time
# KILL_INFLIGHT or more writes are in flight on the test device, once armed:
# a random delay into the measured run (MySQL, whose page cleaner and
# checkpointer write data pages throughout), or into a checkpoint
# (PostgreSQL: when the database fits in shared_buffers only checkpoints
# write data pages; outside them the writes in flight are WAL).  A spread
# checkpoint lasts 0.9 * checkpoint_timeout = 270 s.
KILL_INFLIGHT = 64
KILL_SHM_SIZE = 1 << 20    # ivshmem's BAR: a power of two
KILL_HOLD_US = 0       # how long they must stay in flight before the kill
KILL_DELAY_S = {"mysql": (30, 240), "postgres": (0, 240)}
# --kill-on random: the host kills at a uniform random time this far into the
# run, and reads back what the guest last saw in flight (ktwatch's page)
RANDOM_DELAY_S = (30, 270)
KILL_GATE = {"mysql": "none", "postgres": "checkpoint"}
# MySQL on ZFS: native AIO off (OpenZFS's workload tuning guide; with it on, a
# host running OpenZFS 2.2.2 hard-locked in the io_submit completion path,
# 2026-10-02).  The SOSP round did not set it.
DB_MY_ZFS_OPTS = "--innodb_use_native_aio=OFF"

# What exp_db.sh counted as a torn page, per database
DB_TORN_PAT = {"postgres": "invalid page",
               "mysql": "Database page corruption on disk"}
# database log lines kept in the record
DBLOG_PAT = (r"invalid page|page verification failed|checksum|corrupt|FATAL|PANIC"
             r"|redo starts|redo done|database system (was|is)|ready for connections"
             r"|crash recovery|Apply batch|\[ERROR\]")

BUSY = ("mysqld", "postgres", "sysbench", "fio", "pgbench", "qemu-system-x86")


def say(msg):
    print("[killtest] " + msg, file=sys.stderr, flush=True)


def die(msg):
    say("error: " + msg)
    sys.exit(1)


def need_space(nbytes, what):
    """Refuse a run whose images WORK cannot hold at full size, plus slack for
    the tools disk: they are sparse and fill as the guest writes, and a full
    file system stalls the guest until its timeout -- and everyone else when
    WORK is on a shared root file system, as on libra08."""
    d = WORK
    while not d.exists():
        d = d.parent
    free = shutil.disk_usage(d).free
    if free < nbytes + (2 << 30):
        die("%s can write %.0f GiB into %s, which has %.0f GiB free:"
            " set KILLTEST_WORK to a bigger file system"
            % (what, nbytes / 2**30, d, free / 2**30))


def utcstamp():
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")


# ---------------------------------------------------------------- environment

def kernel_release(path):
    """Release and version string of a bzImage, from its setup header."""
    with open(path, "rb") as f:
        f.seek(0x20E)
        off = int.from_bytes(f.read(2), "little")
        f.seek(off + 0x200)
        s = f.read(512).split(b"\0")[0].decode("ascii", "replace")
    return s.split()[0], s


def qemu_version(qemu):
    out = subprocess.run([qemu, "--version"], capture_output=True, text=True)
    return out.stdout.splitlines()[0] if out.stdout else "?"


def busy_procs():
    """Benchmarks or VMs running on this host.  A VM's I/O and CPU would
    perturb their numbers, and theirs would perturb the kill timing."""
    out = subprocess.run(["ps", "-eo", "comm="], capture_output=True,
                         text=True).stdout.split()
    return sorted({c for c in out if c in BUSY})


def tree_bytes(path):
    n = 0
    for d, _, files in os.walk(path):
        for f in files:
            p = os.path.join(d, f)
            if not os.path.islink(p):
                n += os.path.getsize(p)
    return n


def compile_verifier(src, out):
    # tests/Makefile of the SOSP round: CFLAGS=-Wall -g, i.e. -O0.  The fill
    # loop's speed sets how fast the workload issues writes, so keep it.
    subprocess.run(["gcc", "-Wall", "-g", "-static", "-pthread", "-o", str(out),
                    str(src)], check=True)


def run_conf(fs, workload, test_opt, max_sectors_kb, fsck=True, wbt=None,
             mkfs=None):
    c = FSCONF.get(fs, {})
    v = {
        "FS": fs,
        "WORKLOAD": workload,
        "TEST_OPT": test_opt,
        "MAX_SECTORS_KB": str(max_sectors_kb),
        "WBT_LAT_USEC": "" if wbt is None else str(wbt),
        "MODPROBE": c.get("modprobe", ""),
        "UDEV": "1" if c.get("udev") else "0",
        "MKFS_CMD": mkfs or c.get("mkfs", ""),
        "MOUNT_CMD": c.get("mount", ""),
        "UMOUNT_CMD": c.get("umount", "umount $TEST_DIR"),
        "VERIFY_MOUNT_CMD": c.get("verify_mount", ""),
        "FSCK_CMD": c.get("fsck", "") if fsck else "",
        "DMESG_PAT": DMESG_PAT,
    }
    return "".join("%s=%s\n" % (k, shlex.quote(x)) for k, x in v.items())


PG_INSTALL = ROOT / "bench/workspace/pg_install"
PG_SRC = ROOT / "bench/postgresql"            # its configured source tree
MYSQL_BUILD = ROOT / "bench/mysql-server/build"


def stage_db(stage):
    """This tree's PostgreSQL and MySQL builds, as the guest runs them.  Both
    carry an absolute RUNPATH into this tree, so the guest sets
    LD_LIBRARY_PATH; the system libraries come with the rootfs (WITH_DB=1)."""
    if not (PG_INSTALL / "bin/postgres").exists():
        die("no PostgreSQL build at %s" % PG_INSTALL)
    shutil.copytree(PG_INSTALL, stage / "db/pg", symlinks=True,
                    ignore=shutil.ignore_patterns("include"))
    run = MYSQL_BUILD / "runtime_output_directory"
    if not (run / "mysqld").exists():
        die("no MySQL build at %s" % MYSQL_BUILD)
    (stage / "db/mysql/bin").mkdir(parents=True)
    (stage / "db/mysql/lib").mkdir()
    progs = ("mysqld", "mysql", "mysqladmin", "innochecksum")
    for prog in progs:
        shutil.copy2(run / prog, stage / "db/mysql/bin" / prog)
    # the libraries the build ships itself (abseil, protobuf), by ldd
    libdir = str((MYSQL_BUILD / "library_output_directory").resolve())
    out = subprocess.run(["ldd"] + [str(run / x) for x in progs],
                         capture_output=True, text=True).stdout
    for lib in sorted({l.split()[2] for l in out.splitlines()
                       if "=>" in l and len(l.split()) > 2
                       and l.split()[2].startswith(libdir)}):
        shutil.copy2(lib, stage / "db/mysql/lib")
    shutil.copytree(MYSQL_BUILD / "share", stage / "db/mysql/share",
                    ignore=shutil.ignore_patterns("CMakeFiles", "*.cmake",
                                                  "Makefile", "CTest*"))
    # the character set definitions stay in the source tree, not the build
    charsets = MYSQL_BUILD.parent / "share/charsets"
    if charsets.is_dir():
        shutil.copytree(charsets, stage / "db/mysql/share/charsets")


def build_tools_disk(name, fs, workload, test_opt, max_sectors_kb, release, tau,
                     fsck=True, wbt=None, mkfs=None, conf=None, db=False):
    """The read-only disk every boot of a run mounts at /kt."""
    stage = WORK / ("stage-" + name)
    img = WORK / ("tools-" + name + ".img")
    shutil.rmtree(stage, ignore_errors=True)
    (stage / "bin").mkdir(parents=True)
    shutil.copy2(HERE / "guest/guest.sh", stage / "guest.sh")
    os.chmod(stage / "guest.sh", 0o755)
    (stage / "run.conf").write_text(
        conf if conf is not None else
        run_conf(fs, workload, test_opt, max_sectors_kb, fsck, wbt, mkfs))
    if db:
        stage_db(stage)
    for prog in ("fs", "fs_single"):
        compile_verifier(HERE / "src" / (prog + ".c"), stage / "bin" / prog)
    # the guest half of db --kill-on writeback
    subprocess.run(["gcc", "-Wall", "-O2", "-static", "-o",
                    str(stage / "bin/ktwatch"), str(HERE / "src/ktwatch.c")],
                   check=True)
    if db:
        # PostgreSQL's page check before recovery, from its own headers
        subprocess.run(["gcc", "-Wall", "-Wno-format-truncation", "-O2",
                        "-static", "-I", str(PG_SRC / "src/include"), "-o",
                        str(stage / "bin/pgscan"), str(HERE / "src/pgscan.c")],
                       check=True)
    if tau:
        (stage / "tau").mkdir()
        for tool, src in TAU_TOOLS.items():
            if not src.exists():
                die("%s not built (%s)" % (tool, src))
            shutil.copy2(src, stage / "tau" / tool)
    mods = Path("/lib/modules") / release
    if mods.is_dir():
        shutil.copytree(mods, stage / "modules" / release, symlinks=True,
                        ignore=shutil.ignore_patterns("build", "source"))
    else:
        say("note: no /lib/modules/%s; the guest gets built-in drivers only"
            % release)

    # The stock mke2fs: the system one is the tau fork, and its tau journal
    # would follow the tools disk into a vanilla guest.
    mke2fs = STOCK / "usr/sbin/mke2fs"
    if not mke2fs.exists():
        die("no stock mke2fs at %s (bench/scripts/install_stock_mkfs.sh)" % mke2fs)
    size = tree_bytes(stage) * 5 // 4 + (64 << 20)
    with open(img, "wb") as f:
        f.truncate(size)
    env = dict(os.environ, MKE2FS_CONFIG=str(STOCK / "etc/mke2fs.conf"))
    subprocess.run([str(mke2fs), "-q", "-F", "-t", "ext4", "-L", "kttools",
                    "-d", str(stage), str(img)], check=True, env=env)
    shutil.rmtree(stage)
    return img


# ----------------------------------------------------------------------- VM

class Tail:
    """Lines of a file QEMU is still writing (a -serial file: backend)."""

    def __init__(self, path):
        self.path, self.pos, self.buf, self.lines = path, 0, b"", []

    def poll(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.pos)
                data = f.read()
        except FileNotFoundError:
            return []
        self.pos += len(data)
        self.buf += data
        out = []
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            out.append(line.decode("utf-8", "replace").rstrip("\r"))
        self.lines += out
        return out


class Ctx:
    pass


def qemu_cmd(ctx, phase, console, proto, extra=""):
    append = ("root=/dev/vda ro rootfstype=ext4 rootwait console=ttyS0"
              " panic=-1 init=/opt/killtest/init kt.phase=" + phase)
    if ctx.append:
        append += " " + ctx.append
    if extra:
        append += " " + extra
    kill = []
    if getattr(ctx, "kill_shm", None) is not None and phase == "dbwrite":
        # the page ktwatch writes its kill request into (await_kill_request)
        kill = ["-object", "memory-backend-file,id=ktshm,share=on,mem-path=%s,"
                           "size=%d" % (ctx.kill_shm, KILL_SHM_SIZE),
                "-device", "ivshmem-plain,memdev=ktshm"]
    return [ctx.qemu, "-enable-kvm", "-cpu", "host",
            "-smp", str(ctx.smp), "-m", ctx.mem,
            "-kernel", ctx.kernel, "-append", append,
            "-drive", "file=%s,format=raw,if=virtio,readonly=on" % ctx.rootfs,
            "-drive", "file=%s,format=raw,if=virtio,readonly=on" % ctx.tools,
            # run.exp: -drive file=$TEST_BIN,format=raw,if=none,id=test
            #          -device nvme,drive=test,serial=deadbeef
            "-drive", "file=%s,format=raw,if=none,id=test%s"
                      % (ctx.test_img, ctx.drive_opts),
            "-device", "nvme,drive=test,serial=deadbeef",
            "-display", "none", "-monitor", "none", "-nic", "none",
            "-no-reboot",
            "-serial", "file:" + str(console), "-serial", "file:" + str(proto)
            ] + kill


def start_vm(ctx, phase, prefix, extra=""):
    console = Path(str(prefix) + ".console")
    proto = Path(str(prefix) + ".proto")
    err = open(str(prefix) + ".qemu", "w")
    p = subprocess.Popen(qemu_cmd(ctx, phase, console, proto, extra),
                         stdin=subprocess.DEVNULL, stdout=err, stderr=err)
    err.close()
    return p, console, proto


def kill_vm(p):
    if p.poll() is None:
        p.kill()
    p.wait()


def drop_empty_qemu_logs(logs, t):
    for f in logs.glob("t%03d.*.qemu" % t):
        if f.stat().st_size == 0:
            f.unlink()


# ------------------------------------------------------------------ parsing

V_THREAD = re.compile(r"thread (\d+): num_chunks=(\d+), time=[\d.]+ s, (\w+)"
                      r", verified=(\d+), torn_write=(YES|NO)")
V_INCONS = re.compile(r"thread (\d+): verify_file: inconsistent data \(expected"
                      r" (\d+), got (\d+) at offset (\d+)\) \((\d+)/(\d+) total\)")
V_SHORT = re.compile(r"thread (\d+): verify_file: short read")
V_TORN = re.compile(r"\*\*\* (\d+)/(\d+) torn write\(s\) detected \*\*\*")


def size_arg(opt, flag, default):
    a = opt.split()
    if flag not in a or a.index(flag) + 1 >= len(a):
        return default
    s = a[a.index(flag) + 1]
    mult = {"k": 1 << 10, "m": 1 << 20, "g": 1 << 30}.get(s[-1].lower(), 1)
    return int(s.rstrip("kKmMgG")) * mult


def kv(line):
    return dict(x.split("=", 1) for x in line.split() if "=" in x)


def parse_write(lines, rec):
    for l in lines:
        if not l.startswith("@@KT "):
            continue
        b = l[5:]
        if b.startswith("BOOT "):
            d = kv(b)
            rec["release"] = d.get("release")
            rec["version"] = d.get("version", "").replace("_", " ")
        elif b.startswith("DEV write_cache="):
            d = kv(b)
            rec["write_cache"] = d.get("write_cache", "").replace("_", " ")
            rec["max_sectors_kb_default"] = int(d.get("max_sectors_kb", 0))
            rec["max_hw_sectors_kb"] = int(d.get("max_hw_sectors_kb", 0))
            for k in ("scheduler", "wbt_lat_usec", "blockdevs"):
                if k in d:
                    rec[k + ("_default" if k == "wbt_lat_usec" else "")] = d[k]
        elif b.startswith("DEV wbt_lat_usec_now="):
            rec["wbt_lat_usec"] = kv(b)["wbt_lat_usec_now"]
        elif b.startswith("DEV max_sectors_kb_now="):
            rec["max_sectors_kb"] = int(kv(b)["max_sectors_kb_now"])
        elif b.startswith("ZERO_VERIFY "):
            rec["zero_verify_rc"] = int(kv(b)["rc"])
        elif b.startswith("FAIL "):
            rec["fail"] = b[5:]
        elif b.startswith("TIME "):
            _, label, t = b.split()
            rec.setdefault("guest_time", {})["write." + label] = float(t)


def parse_verify(lines, rec, chunk, region):
    """region: bytes each thread owns before its own chunks start -- 0 for
    fs.c (a file per thread), the per-thread size for fs_single.c."""
    tears, per = [], {}
    rec["torn_threads"] = 0
    for l in lines:
        if not l.startswith("@@KT "):
            continue
        b = l[5:]
        if b.startswith("BOOT "):
            rec["verify_release"] = kv(b).get("release")
        elif b.startswith("MOUNT "):
            d = kv(b)
            rec["mount_rc"], rec["mount_ms"] = int(d["rc"]), int(d["ms"])
        elif b.startswith("DMESG "):
            rec.setdefault("dmesg", []).append(b[6:])
        elif b.startswith("MOUNT_ERR "):
            rec.setdefault("mount_err", []).append(b[10:])
        elif b.startswith("VERIFY "):
            rec["verify_rc"] = int(kv(b)["rc"])
        elif b.startswith("FSCK "):
            rec["fsck_rc"] = int(kv(b)["rc"])
        elif b.startswith("FSCK_OUT "):
            rec.setdefault("fsck_out", []).append(b[9:])
        elif b.startswith("FAIL "):
            rec["fail"] = b[5:]
        elif b.startswith("TIME "):
            _, label, t = b.split()
            rec.setdefault("guest_time", {})["verify." + label] = float(t)
        elif b.startswith("V "):
            v = b[2:]
            m = V_INCONS.search(v)
            if m:
                tid, exp, got, j, pos = (int(m.group(i)) for i in (1, 2, 3, 4, 5))
                # fs.c checks each byte against the first one: got == 0 means
                # the bytes before j were new and this one is old, got == exp
                # the other way round.
                first = "new" if got == 0 else ("old" if got == exp else "?")
                tears.append({"thread": tid,
                              "chunk": (pos - j - tid * region) // chunk,
                              "split": j, "first": first})
                continue
            if V_SHORT.search(v):
                tears.append({"thread": int(V_SHORT.search(v).group(1)),
                              "short_read": True})
                continue
            m = V_THREAD.search(v)
            if m:
                per[int(m.group(1))] = (int(m.group(4)), int(m.group(2)),
                                        m.group(5) == "YES")
                continue
            m = V_TORN.search(v)
            if m:
                rec["torn_threads"] = int(m.group(1))
    rec["tears"] = tears
    if per:
        rec["threads"] = len(per)
        rec["verified_chunks"] = sum(x[0] for x in per.values())
        # chunks each thread read before stopping: all of them unless its
        # file is short (append) or it hit an error
        rec["chunks_read"] = sum(x[1] for x in per.values())
        rec["verified_per_thread"] = [per[t][0] for t in sorted(per)]


def verdict(rec, workload, console_text):
    """exp.sh counted a trial as torn when the verifier printed "torn write(s)
    detected", and as a normal exit otherwise; the rest only says why a trial
    could not be judged."""
    if "Kernel panic" in console_text:
        return "guest_panic"
    if rec.get("torn_threads"):
        return "torn"
    if "verify_timeout" in rec:
        return "verify_timeout"
    if rec.get("mount_rc", 0) != 0:
        return "mount_failed"
    if "verify_rc" not in rec:
        return "verify_error"
    # append: the files had not grown to full size, so the verifier stops at
    # EOF with an error -- expected, and not a tear
    if rec["verify_rc"] == 0 or workload == "append":
        return "clean"
    return "verify_error"


# -------------------------------------------------------------------- trial

def run_trial(ctx, t):
    pfx = ctx.logs / ("t%03d" % t)
    rec = {"trial": t, "fs": ctx.fs, "workload": ctx.workload,
           "wait_ms": ctx.wait_ms}
    t0 = time.monotonic()

    # a fresh, all-zero device per trial: a sparse file
    with open(ctx.test_img, "wb") as f:
        f.truncate(ctx.test_size)

    # ---- boot 1: prepare, overwrite, kill
    p, wcon, wpro = start_vm(ctx, "write", str(pfx) + ".write")
    ctx.live = p
    tail = Tail(wpro)
    started = None
    deadline = time.monotonic() + ctx.setup_timeout
    while started is None:
        for l in tail.poll():
            if l.startswith("@@KT WRITE_START"):
                started = time.monotonic()
        if started is not None or p.poll() is not None or \
                time.monotonic() > deadline:
            break
        time.sleep(0.001)
    if started is None:
        kill_vm(p)
        tail.poll()
        parse_write(tail.lines, rec)
        rec["verdict"] = "setup_failed"
        rec.setdefault("fail", "no WRITE_START within %ds" % ctx.setup_timeout
                       if p.returncode == -signal.SIGKILL else
                       "guest exited before WRITE_START")
        rec["trial_s"] = round(time.monotonic() - t0, 1)
        return rec, (wcon,)

    target = started + ctx.wait_ms / 1000.0
    while True:
        now = time.monotonic()
        if now >= target:
            break
        rem = target - now
        time.sleep(rem - 0.002 if rem > 0.003 else 0.0002)
    tail.poll()
    done_before = any(l.startswith("@@KT WRITE_DONE") for l in tail.lines)
    p.send_signal(signal.SIGKILL)
    killed = time.monotonic()
    p.wait()
    ctx.live = None
    tail.poll()
    parse_write(tail.lines, rec)
    rec["kill_after_start_ms"] = round((killed - started) * 1000, 2)
    rec["write_done_before_kill"] = done_before
    rec["setup_s"] = round(started - t0, 1)

    # ---- boot 2: recover and verify
    p, vcon, vpro = start_vm(ctx, "verify", str(pfx) + ".verify")
    ctx.live = p
    try:
        p.wait(timeout=ctx.verify_timeout)
    except subprocess.TimeoutExpired:
        rec["verify_timeout"] = ctx.verify_timeout
        kill_vm(p)
    ctx.live = None
    vt = Tail(vpro)
    vt.poll()
    parse_verify(vt.lines, rec, ctx.chunk,
                 ctx.size if ctx.workload == "rand_single" else 0)
    if "threads" in rec:
        rec["chunks"] = rec["threads"] * (ctx.size // ctx.chunk)
    try:
        ctext = vcon.read_text(errors="replace")
    except FileNotFoundError:
        ctext = ""
    rec["verdict"] = verdict(rec, ctx.workload, ctext)
    rec["trial_s"] = round(time.monotonic() - t0, 1)
    return rec, (wcon, vcon)


# ------------------------------------------------------------------ summary

def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def summarize(recs, label):
    out = []
    n = len(recs)
    by = {}
    for r in recs:
        by[r.get("verdict", "?")] = by.get(r.get("verdict", "?"), 0) + 1
    judged = [r for r in recs if r.get("verdict") in ("torn", "clean")]
    torn = sum(1 for r in judged if r["verdict"] == "torn")
    lo, hi = wilson(torn, len(judged))
    # the line exp.sh printed
    out.append("%s: Reached max trial: %d/%d." % (label, torn, n))
    out.append("trials %d: %s" % (n, ", ".join("%s %d" % kv_ for kv_ in
                                                 sorted(by.items()))))
    if judged:
        out.append("torn %d/%d judged = %.1f%% [95%% CI %.1f-%.1f%%]"
                   % (torn, len(judged), 100.0 * torn / len(judged),
                      100 * lo, 100 * hi))
    shapes = {}
    for r in recs:
        for x in r.get("tears", []):
            k = "short read" if x.get("short_read") else \
                "first %d KiB %s" % (x["split"] // 1024, x["first"])
            shapes[k] = shapes.get(k, 0) + 1
    if shapes:
        out.append("torn chunks by shape (first mismatch per thread): " +
                   ", ".join("%s: %d" % s for s in sorted(shapes.items())))
    prog = [r["verified_chunks"] / r["chunks"] for r in judged
            if r.get("chunks")]
    if prog:
        prog.sort()
        out.append("chunks new after recovery: median %.1f%% (min %.1f, max %.1f)"
                   % (100 * prog[len(prog) // 2], 100 * prog[0], 100 * prog[-1]))
    done = sum(1 for r in recs if r.get("write_done_before_kill"))
    if done:
        out.append("overwrite had finished before the kill in %d trial(s)"
                   % done)
    ka = [r["kill_after_start_ms"] for r in recs if "kill_after_start_ms" in r]
    if ka:
        out.append("kill after WRITE_START: %.1f-%.1f ms" % (min(ka), max(ka)))
    mt = sorted(r["mount_ms"] for r in recs if "mount_ms" in r)
    if mt:
        out.append("recovery mount: median %d ms (max %d)" % (mt[len(mt) // 2],
                                                            mt[-1]))
    fk = [r for r in recs if r.get("fsck_rc") not in (None, 0)]
    if fk:
        out.append("fsck reported something in %d trial(s) (information only)"
                   % len(fk))
    return "\n".join(out)


def load_trials(d):
    recs = []
    with open(Path(d) / "trials.jsonl") as f:
        for line in f:
            line = line.strip()
            if line:
                recs.append(json.loads(line))
    return recs


# ----------------------------------------------------------------- commands

def make_ctx(a, fs, workload):
    ctx = Ctx()
    c = FSCONF.get(fs, {})
    ctx.fs, ctx.workload = fs, workload
    ctx.qemu = a.qemu
    ctx.kernel = a.kernel or (TAU_KERNEL if c.get("tau") else BASE_KERNEL)
    if not os.path.exists(ctx.kernel):
        die("kernel %s not found" % ctx.kernel)
    ctx.release, ctx.kversion = kernel_release(ctx.kernel)
    ctx.rootfs = Path(a.rootfs)
    if not ctx.rootfs.exists():
        die("no rootfs at %s: run tools/killtest/mkrootfs.sh once" % ctx.rootfs)
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        die("no access to /dev/kvm (join the kvm group)")
    ctx.smp, ctx.mem = a.smp, a.mem
    ctx.append = a.append
    ctx.drive_opts = a.drive_opts
    ctx.live = None
    return ctx


def cmd_probe(a):
    ctx = make_ctx(a, "probe", "seq")
    WORK.mkdir(parents=True, exist_ok=True)
    need_space(16 << 30, "probe")
    name = "probe-" + utcstamp()
    ctx.tools = build_tools_disk(name, "probe", "seq", SOSP_TEST_OPT, 0,
                                 ctx.release, tau=False)
    ctx.test_img = WORK / ("test-" + name + ".img")
    with open(ctx.test_img, "wb") as f:
        f.truncate(16 << 30)
    pfx = WORK / name
    p, con, pro = start_vm(ctx, "probe", pfx)
    try:
        p.wait(timeout=120)
    except subprocess.TimeoutExpired:
        kill_vm(p)
        say("probe timed out; console in %s" % con)
    t = Tail(pro)
    t.poll()
    print("kernel %s (%s)" % (ctx.kernel, ctx.kversion))
    for l in t.lines:
        print(l)
    for f in (ctx.tools, ctx.test_img):
        f.unlink()
    return 0 if any(l == "@@KT DONE" for l in t.lines) else 1


def cmd_run(a):
    if a.fs not in FSCONF:
        die("unknown --fs %s (%s)" % (a.fs, ", ".join(FSCONF)))
    c = FSCONF[a.fs]
    busy = busy_procs()
    if busy and not a.allow_busy:
        die("this host is running %s; a VM would perturb it and be perturbed"
            " (--allow-busy to run anyway)" % ", ".join(busy))
    ctx = make_ctx(a, a.fs, a.workload)
    ctx.test_opt = a.test_opt or c.get("test_opt", SOSP_TEST_OPT)
    ctx.wait_ms = a.wait_ms if a.wait_ms is not None else c["wait_ms"]
    ctx.chunk = size_arg(ctx.test_opt, "-b", 1 << 20)
    ctx.size = size_arg(ctx.test_opt, "-s", 256 << 20)
    ctx.test_size = a.test_size << 30
    ctx.setup_timeout, ctx.verify_timeout = a.setup_timeout, a.verify_timeout
    need_space(ctx.test_size, "run")

    name = "%s_%s_%s" % (utcstamp(), a.fs, a.workload)
    rundir = Path(a.out) / name if a.out else RESULTS / name
    ctx.logs = rundir / "logs"
    ctx.logs.mkdir(parents=True)
    WORK.mkdir(parents=True, exist_ok=True)
    ctx.tools = build_tools_disk(name, a.fs, a.workload, ctx.test_opt,
                                 a.max_sectors_kb, ctx.release,
                                 tau=c.get("tau", False), fsck=not a.no_fsck,
                                 wbt=a.wbt_lat_usec, mkfs=a.mkfs)
    ctx.test_img = WORK / ("test-" + name + ".img")

    pkgs = WORK / "rootfs-packages.txt"
    meta = {
        "tool": "killtest", "fs": a.fs, "workload": a.workload,
        "trials": a.trials, "test_opt": ctx.test_opt, "wait_ms": ctx.wait_ms,
        "max_sectors_kb": a.max_sectors_kb, "wbt_lat_usec": a.wbt_lat_usec,
        "test_size_gib": a.test_size,
        "fsconf": c, "mkfs": a.mkfs or c["mkfs"],
        "kernel": ctx.kernel, "release": ctx.release,
        "kernel_version": ctx.kversion, "qemu": ctx.qemu,
        "qemu_version": qemu_version(ctx.qemu), "smp": ctx.smp, "mem": ctx.mem,
        "drive_opts": ctx.drive_opts, "append": ctx.append,
        "rootfs": str(ctx.rootfs),
        "rootfs_packages": pkgs.read_text().split("\n") if pkgs.exists() else [],
        "fsck": not a.no_fsck,
        "host": socket.gethostname(), "started_utc": utcstamp(),
        "busy_at_start": busy,
    }
    (rundir / "run.json").write_text(json.dumps(meta, indent=1) + "\n")
    say("%s/%s: %d trials, TEST_OPT '%s', WAIT_MS %d, kernel %s, -> %s"
        % (a.fs, a.workload, a.trials, ctx.test_opt, ctx.wait_ms, ctx.release,
           rundir))

    recs = []

    def stop(signum, frame):
        if ctx.live is not None:
            kill_vm(ctx.live)
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        for t in range(a.trials):
            # a benchmark that starts mid-run gets the host back
            busy = busy_procs()
            if busy and not a.allow_busy:
                say("stopping before trial %d: %s started on this host"
                    % (t, ", ".join(busy)))
                break
            rec, consoles = run_trial(ctx, t)
            drop_empty_qemu_logs(ctx.logs, t)
            recs.append(rec)
            with open(rundir / "trials.jsonl", "a") as f:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")
            keep = a.keep_console == "all" or t == 0 or \
                (a.keep_console == "failed" and rec["verdict"] != "clean")
            if not keep:
                for con in consoles:
                    if con.exists():
                        con.unlink()
            extra = ""
            if rec["verdict"] == "torn":
                extra = " (%d/%d threads)" % (rec["torn_threads"],
                                              rec.get("threads", 0))
            elif rec.get("fail"):
                extra = " (%s)" % rec["fail"]
            prog = ""
            if rec.get("chunks"):
                prog = "  new %.0f%%" % (100.0 * rec["verified_chunks"]
                                         / rec["chunks"])
            say("%s/%s t%03d %s%s  kill@%sms%s  %.0fs"
                % (a.fs, a.workload, t, rec["verdict"], extra,
                   rec.get("kill_after_start_ms", "-"), prog, rec["trial_s"]))
    except KeyboardInterrupt:
        if ctx.live is not None:
            kill_vm(ctx.live)
        say("interrupted after %d trial(s)" % len(recs))
    finally:
        for f in (ctx.tools, ctx.test_img):
            if f.exists() and not a.keep_images:
                f.unlink()
    text = summarize(recs, "%s_%s" % (a.fs, a.workload))
    (rundir / "summary.txt").write_text(text + "\n")
    print(text)
    return 0


# ----------------------------------------------------------------- DB test

def zfs_cmds(a, c, settings):
    """A DB run's mkfs, mount and umount commands.  The revision's pools
    (common.sh do_mkfs) have compression off, the data at the profile's
    logbias -- or --zfs-logbias: latency copies the pages an fsync commits
    into the ZIL, throughput writes them out as whole blocks the log points
    to -- and the WAL/redo in zfspool/log at $TEST_DIR/log (DB_LOG_DIR)."""
    cmds = {"MKFS_CMD": c["mkfs"],
            "MOUNT_NEW_CMD": c.get("mount_new", c["mount"]),
            "MOUNT_CMD": c["mount"],
            "UMOUNT_CMD": c.get("umount", "umount $TEST_DIR")}
    if not a.fs.startswith("zfs"):
        return cmds
    props = []
    if a.profile != "sosp":
        props.append("-O compression=off")
    logbias = a.zfs_logbias or settings["zfs_logbias"]
    if logbias:
        props.append("-O logbias=" + logbias)
    if props:
        cmds["MKFS_CMD"] = cmds["MKFS_CMD"].replace(
            " zfspool $TEST_DEV", " %s zfspool $TEST_DEV" % " ".join(props))
    if settings["zfs_log_dataset"]:
        # canmount=noauto, as the pool's: only these commands mount it
        cmds["MKFS_CMD"] += (" && zfs create -o recordsize=128k"
                             " -o logbias=latency -o canmount=noauto"
                             " zfspool/log")
        cmds["MOUNT_NEW_CMD"] += " && zfs mount zfspool/log"
        cmds["MOUNT_CMD"] += " && zfs mount zfspool/log"
        cmds["UMOUNT_CMD"] = "zfs unmount zfspool/log && " + cmds["UMOUNT_CMD"]
    return cmds


def mem_mib(mem):
    """QEMU's -m: MiB, or a number with an M, G or T suffix."""
    m = re.fullmatch(r"(\d+)([MGT]?)B?", mem.strip().upper())
    if not m:
        die("cannot read --mem %r" % mem)
    return int(m.group(1)) << {"": 0, "M": 0, "G": 10, "T": 20}[m.group(2)]


def db_conf(a, c, ctx):
    """run.conf of a DB run, and the database settings it ends up with."""
    settings = ctx.settings
    # a profile's {cache}, in MiB: 25% of the VM's memory, or --cache-mb
    cache = str(a.cache_mb if a.cache_mb else mem_mib(ctx.mem) // 4)
    pg_conf = settings["pg_conf"].replace("{cache}", cache)
    my_opts = settings["my_opts"].replace("{cache}", cache)
    my_init = settings["my_init_opts"]
    # the image keeps the shared_buffers it was prepared with; a run with
    # another cache size gives it at start
    pg_start = ("-c shared_buffers=%sMB" % cache
                if a.cache_mb and "{cache}" in settings["pg_conf"] else "")
    if a.log_default:
        # the databases' own log sizes (MySQL 8.4 innodb_redo_log_capacity
        # 100M, PostgreSQL 17 max_wal_size 1GB) instead of the profile's;
        # a PostgreSQL image prepared with max_wal_size set gets it at start
        my_opts = re.sub(r" ?--innodb_redo_log_capacity=\S+", "", my_opts)
        my_init = re.sub(r" ?--innodb_redo_log_capacity=\S+", "", my_init).strip()
        if "max_wal_size" in pg_conf:
            # (pg_conf separates its lines with a literal backslash-n)
            pg_conf = re.sub(r"\\nmax_wal_size = [^\\]+", "", pg_conf)
            pg_start += " -c max_wal_size=1GB"
    # --pg-set / --my-set: settings of a run, given at start over the
    # image's (PostgreSQL: -c, MySQL: server options)
    for kvs in a.pg_set or []:
        pg_start += " -c " + kvs
    for kvs in a.my_set or []:
        my_opts += " --" + kvs
    pg_start = pg_start.strip()
    zfs_split = a.fs.startswith("zfs") and settings["zfs_log_dataset"]
    if a.fs.startswith("zfs"):
        pg_conf += settings["pg_cow_conf"]
        if a.db == "mysql":
            my_opts += " " + DB_MY_ZFS_OPTS
    v = {
        "FS": a.fs, "WORKLOAD": "db", "TEST_OPT": "",
        "MAX_SECTORS_KB": str(a.max_sectors_kb),
        "WBT_LAT_USEC": "" if a.wbt_lat_usec is None else str(a.wbt_lat_usec),
        "MODPROBE": c.get("modprobe", ""),
        "UDEV": "1" if c.get("udev") else "0",
        **zfs_cmds(a, c, settings),
        # the WAL/redo's directory under $TEST_DIR when not with the data
        "DB_LOG_DIR": "log" if zfs_split else "",
        "DMESG_PAT": DMESG_PAT,
        "DB": a.db, "DBNAME": settings["dbname"],
        "SB_TABLES": str(settings["tables"]), "SB_ROWS": str(settings["rows"]),
        "SB_THREADS": str(settings["threads"]),
        "SB_WORKLOAD": settings["workload"],
        "SB_RAND_TYPE": settings["rand_type"],
        "WARMUP_S": str(settings["warmup_s"]), "AGE_S": str(settings["age_s"]),
        "RUN_S": str(settings["run_s"]), "RERUN_S": str(settings["rerun_s"]),
        "PG_CONF": pg_conf, "MY_OPTS": my_opts, "PG_START_OPTS": pg_start,
        "MY_INIT_OPTS": my_init,
        # recovery takes well under a minute; a server that hangs on a
        # corrupted page is given up on after this
        "DB_START_TIMEOUT": str(a.db_start_timeout), "DBLOG_PAT": DBLOG_PAT,
        # MySQL: stop waiting this long after the log reports a torn page
        "DB_GIVEUP_PAT": DB_TORN_PAT[a.db] if a.db == "mysql" else "",
        "DB_GIVEUP_S": str(a.db_giveup_s),
        "KILL_ON": ctx.kill_on, "KILL_INFLIGHT": str(ctx.kill_inflight),
        "KILL_HOLD_US": str(ctx.kill_hold_us), "KILL_GATE": ctx.kill_gate,
        # the watcher runs SCHED_FIFO for --kill-on random, so that the sample
        # it leaves for the host is no older than its poll interval
        "WATCH_RT_PRIO": str(a.watch_rt_prio if a.watch_rt_prio is not None
                             else (10 if ctx.kill_on in ("random", "checkpoint")
                                   else 0)),
    }
    conf = "".join("%s=%s\n" % (k, shlex.quote(x)) for k, x in v.items())
    eff = {"pg_conf": pg_conf, "my_opts": my_opts, "my_init_opts": my_init,
           "pg_start_opts": pg_start, "cache_mb": int(cache)}
    if a.fs.startswith("zfs"):
        eff["zfs_logbias"] = a.zfs_logbias or settings["zfs_logbias"] or "latency"
        eff["zfs_log_dataset"] = bool(zfs_split)
    return conf, eff


WATCH_BUCKETS = "0|1-3|4-7|8-15|16-31|32-63|64-127|128+"
BURST_DURATIONS = "<100us|<300us|<1ms|<3ms|<10ms|longer"


def parse_db_write(lines, rec):
    parse_write(lines, rec)
    for l in lines:
        if not l.startswith("@@KT "):
            continue
        b = l[5:]
        if b.startswith("WATCH "):
            # ktwatch's samples of the in-flight writes, per report interval
            d = kv(b)
            rec["watch_samples"] = rec.get("watch_samples", 0) + int(d["samples"])
            rec["watch_max_w"] = max(rec.get("watch_max_w", 0), int(d["max_w"]))
            # [uptime, gate open, max in flight, writes, MiB, dirty MiB]
            rec.setdefault("watch_series", []).append(
                [float(d["t"]), int(d["gate"]), int(d["max_w"]),
                 int(d.get("wr_ios", -1)), float(d.get("wr_mib", -1)),
                 round(int(d.get("dirty_kb", -1024)) / 1024, 1)])
            for k in ("hist", "gate_hist"):
                if k in d:
                    h = [int(x) for x in d[k].split(",")]
                    old = rec.get("watch_" + k, [0] * len(h))
                    rec["watch_" + k] = [x + y for x, y in zip(old, h)]
        elif b.startswith("WATCH_BURSTS "):
            # episodes of 8+ writes in flight: by their most writes in
            # flight (w8 = 8-15, ...), each by duration
            bs = rec.setdefault("watch_bursts", {})
            for k, x in kv(b).items():
                if k.startswith("w"):
                    h = [int(y) for y in x.split(",")]
                    bs[k] = [p + q for p, q in zip(bs.get(k, [0] * len(h)), h)]
        elif b.startswith("WATCH_GATE open "):
            rec.setdefault("gate_open_t", []).append(float(kv(b)["t"]))
        elif b.startswith("WATCH_GATE close "):
            rec.setdefault("gate_close_t", []).append(float(kv(b)["t"]))
        elif b.startswith("WATCH_TIMEOUT"):
            rec["watch_timeout"] = True
        elif b.startswith("WATCH_ERR "):
            rec["watch_err"] = b[10:]
        elif b.startswith("WATCH_RC "):
            rec["watch_rc"] = int(kv(b)["rc"])
        elif b.startswith("WATCH_KILL "):
            rec["watch_kill"] = {k: float(x) for k, x in kv(b).items()}
        elif b.startswith("PGVARS ") or b.startswith("MYVARS "):
            rec["db_vars"] = b[7:].strip()
        elif b.startswith("ZFSPROPS "):
            rec["zfs_props"] = b[9:].strip()
        elif b.startswith("WRITE_DONE "):
            rec["write_rc"] = int(kv(b)["rc"])
        elif b.startswith("DBLOG "):
            rec.setdefault("write_dblog", []).append(b[6:])


def parse_db_verify(lines, rec, db):
    for l in lines:
        if not l.startswith("@@KT "):
            continue
        b = l[5:]
        if b.startswith("BOOT "):
            rec["verify_release"] = kv(b).get("release")
        elif b.startswith("MOUNT "):
            d = kv(b)
            rec["mount_rc"], rec["mount_ms"] = int(d["rc"]), int(d["ms"])
        elif b.startswith("DMESG "):
            rec.setdefault("dmesg", []).append(b[6:])
        elif b.startswith("MOUNT_ERR "):
            rec.setdefault("mount_err", []).append(b[10:])
        elif b.startswith("DB_START "):
            d = kv(b)
            rec["db_start_rc"], rec["recovery_ms"] = int(d["rc"]), int(d["ms"])
        elif b.startswith("RERUN "):
            d = kv(b)
            rec["rerun_rc"], rec["rerun_errors"] = int(d["rc"]), int(d["errors"])
        elif b.startswith("RERUN_ERR "):
            rec.setdefault("rerun_err", []).append(b[10:])
        elif b.startswith("DB_STOP "):
            rec["db_stop_rc"] = int(kv(b)["rc"])
        elif b.startswith("DBLOG "):
            rec.setdefault("dblog", []).append(b[6:])
        elif b.startswith("PG "):
            rec["pg_control"] = b[3:].replace("_", " ").strip()
        elif b.startswith("SCAN_FILE "):
            rec.setdefault("scan_files", []).append(b[10:])
        elif b.startswith("SCAN_OUT "):
            rec.setdefault("scan_out", []).append(b[9:])
        elif b.startswith("SCAN "):
            when, d = b.split()[1], kv(b)
            bad = d.get("bad_pages", "?")
            rec["scan_" + when] = int(bad) if bad.isdigit() else None
            if "bad_files" in d:
                rec["scan_%s_files" % when] = int(d["bad_files"])
            if d.get("errors", "0") != "0":
                rec["scan_%s_errors" % when] = int(d["errors"])
            if d.get("short", "0") != "0":
                # a relation file that ends inside a block (pgscan)
                rec["scan_%s_short" % when] = int(d["short"])
        elif b.startswith("DB_KILLED"):
            rec["db_killed"] = True
        elif b.startswith("DBLOG_TAIL "):
            rec.setdefault("dblog_tail", []).append(b[11:])
        elif b.startswith("FAIL "):
            rec["fail"] = b[5:]
        elif b.startswith("TIME "):
            _, label, t = b.split()
            rec.setdefault("guest_time", {})["verify." + label] = float(t)
    rec["torn_log"] = sum(1 for x in rec.get("dblog", [])
                          if DB_TORN_PAT[db].lower() in x.lower())


def db_verdict(rec, console_text):
    """exp_db.sh counted a torn page when the database's log said so during
    recovery or the 30 s run after it.  The offline checksum scans are kept
    beside that, as torn_scan when the log missed what they found."""
    if "Kernel panic" in console_text:
        return "guest_panic"
    if rec.get("kill_on") == "writeback" and "kill_request" not in rec:
        # not killed during writeback: nothing to judge (the VM is not
        # booted again).  --kill-inflight 0 only watches.
        return "watch_only" if rec.get("kill_inflight") == 0 else "no_trigger"
    if rec.get("no_checkpoint"):
        return "no_trigger"           # --kill-on checkpoint: none started
    if rec.get("torn_log"):
        return "torn"
    if "verify_timeout" in rec:
        return "verify_timeout"
    if rec.get("mount_rc", 0) != 0:
        return "mount_failed"
    if (rec.get("scan_post") or 0) > 0 or (rec.get("scan_pre") or 0) > 0:
        return "torn_scan"
    if rec.get("db_start_rc", 1) != 0:
        return "recovery_failed"
    if "scan_post" not in rec:
        return "verify_error"
    return "clean"


def kill_policy(meta):
    if meta.get("kill_on", "time") == "time":
        return "kill %s ms into the run" % meta.get("wait_ms")
    lo, hi = meta["kill_delay_s"]
    if meta["kill_on"] == "random":
        return "kill at a random time %g-%g s into the run" % (lo, hi)
    if meta["kill_on"] == "checkpoint":
        return "kill at a random time %g-%g s after a checkpoint starts" % (lo, hi)
    into = "a checkpoint" if meta.get("kill_gate") == "checkpoint" else "the run"
    if meta["kill_inflight"] == 0:
        return "no kill, in-flight writes watched"
    held = (" for %d us" % meta["kill_hold_us"]) if meta.get("kill_hold_us") else ""
    return ("kill at >= %d writes in flight%s, armed %g-%g s into %s"
            % (meta["kill_inflight"], held, lo, hi, into))


def summarize_db(recs, label):
    out = []
    n = len(recs)
    by = {}
    for r in recs:
        by[r.get("verdict", "?")] = by.get(r.get("verdict", "?"), 0) + 1
    torn = by.get("torn", 0)
    out.append("%s: Reached max trial %d/%d." % (label, torn, n))   # exp_db.sh
    out.append("trials %d: %s" % (n, ", ".join("%s %d" % x for x in sorted(by.items()))))
    judged = [r for r in recs if r.get("verdict") in
              ("torn", "torn_scan", "recovery_failed", "clean")]
    if judged:
        k = sum(1 for r in judged if r["verdict"] in ("torn", "torn_scan"))
        lo, hi = wilson(k, len(judged))
        out.append("torn pages by the log or the checksum scan: %d/%d = %.1f%%"
                   " [95%% CI %.1f-%.1f%%]" % (k, len(judged), 100.0 * k / len(judged),
                                              100 * lo, 100 * hi))
    pages = [r.get("scan_post") for r in recs if r.get("scan_post")]
    pre = [r.get("scan_pre") for r in recs if r.get("scan_pre")]
    if pages or pre:
        out.append("bad pages per torn trial: after recovery %s; before it %s"
                   % (sorted(pages) or "-", sorted(pre) or "-"))
    rt = sorted(r["recovery_ms"] for r in recs if "recovery_ms" in r)
    if rt:
        out.append("database recovery: median %.1f s (max %.1f)"
                   % (rt[len(rt) // 2] / 1000, rt[-1] / 1000))
    ka = [r["kill_after_start_ms"] for r in recs if "kill_after_start_ms" in r]
    if ka:
        out.append("kill after WRITE_START: %.1f-%.1f ms" % (min(ka), max(ka)))
    done = sum(1 for r in recs if r.get("write_done_before_kill"))
    if done:
        out.append("the run had finished before the kill in %d trial(s)" % done)
    w = sorted(r["kill_request"]["w"] for r in recs
               if "w" in r.get("kill_request", {}))
    if w:
        out.append("writes in flight at the kill: median %d (%d-%d)"
                   % (w[len(w) // 2], w[0], w[-1]))
    ak = [r for r in recs if "at_kill" in r and r.get("verdict") in
          ("torn", "torn_scan", "recovery_failed", "clean")]
    if ak:
        rows = []
        for lo, hi in ((0, 0), (1, 15), (16, 63), (64, 1 << 30)):
            sel = [r for r in ak if lo <= r["at_kill"]["w"] <= hi]
            k = sum(1 for r in sel if r["verdict"] in ("torn", "torn_scan"))
            rows.append("%s: %d/%d" % (("%d" % lo) if lo == hi else
                                       ("%d+" % lo) if hi > 1 << 20 else
                                       "%d-%d" % (lo, hi), k, len(sel)))
        out.append("torn by writes in flight at the kill: " + ", ".join(rows))
        inb = sum(1 for r in ak if r["at_kill"]["burst_max"])
        out.append("killed inside a burst of 8+ writes in flight: %d/%d"
                   % (inb, len(ak)))
    g = sorted(r["kill_after_start_ms"] / 1000 - r["gate_after_start_s"]
               for r in recs if "gate_after_start_s" in r and
               ("kill_request" in r or r.get("kill_on") == "checkpoint") and
               not r.get("no_checkpoint"))
    if g:
        out.append("kill after the checkpoint started: %.0f-%.0f s" % (g[0], g[-1]))
    for k, what in (("watch_hist", "while running"),
                    ("watch_gate_hist", "during checkpoints")):
        hs = [r[k] for r in recs if k in r]
        if hs:
            tot = [sum(x) for x in zip(*hs)]
            out.append("in-flight writes sampled %s (%s): %s"
                       % (what, WATCH_BUCKETS, ",".join(map(str, tot))))
    bs = [r["watch_bursts"] for r in recs if "watch_bursts" in r]
    if bs:
        out.append("bursts of 8+ writes in flight, by the most in flight and"
                   " how long (%s):" % BURST_DURATIONS)
        for k in sorted(bs[0], key=lambda x: int(x[1:])):
            tot = [sum(x) for x in zip(*(b[k] for b in bs if k in b))]
            out.append("  %s+ %s" % (k[1:], ",".join(map(str, tot))))
    return "\n".join(out)


def run_vm_until(ctx, phase, pfx, timeout):
    p, con, pro = start_vm(ctx, phase, pfx)
    ctx.live = p
    timed_out = False
    try:
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_vm(p)
    ctx.live = None
    t = Tail(pro)
    t.poll()
    return t.lines, con, timed_out


def prepare_golden(ctx, golden):
    """Format, load, age and keep the test device -- create.exp's two steps."""
    say("%s/%s: preparing the database image (prepare + %d s run) -> %s"
        % (ctx.db, ctx.fs, ctx.settings["age_s"], golden))
    with open(ctx.test_img, "wb") as f:
        f.truncate(ctx.test_size)
    t0 = time.monotonic()
    lines, con, timed_out = run_vm_until(ctx, "dbprep", ctx.logs / "prep",
                                         ctx.prep_timeout)
    info = {"seconds": round(time.monotonic() - t0), "timed_out": timed_out}
    for l in lines:
        if l.startswith("@@KT AGE ") or l.startswith("@@KT DATASIZE ") or \
                l.startswith("@@KT PG ") or l.startswith("@@KT FAIL "):
            info.setdefault("lines", []).append(l[5:])
    if timed_out or "@@KT DONE" not in lines:
        die("preparing the image failed (%s); console %s"
            % (info.get("lines", ["no DONE"])[-1], con))
    os.replace(ctx.test_img, golden)
    info.update({"db": ctx.db, "fs": ctx.fs, "settings": ctx.settings,
                 "my_opts": ctx.my_opts, "release": ctx.release,
                 "kernel_version": ctx.kversion, "qemu": ctx.qemu,
                 "created_utc": utcstamp()})
    Path(str(golden) + ".json").write_text(json.dumps(info, indent=1) + "\n")
    say("image ready in %d s: %s" % (info["seconds"], "; ".join(info.get("lines", []))))
    return info


def open_kill_shm(ctx):
    """The memory the guest's ktwatch writes its kill request into: a file in
    /dev/shm that QEMU maps as an ivshmem-plain device's BAR."""
    path = Path("/dev/shm") / ("killtest-" + ctx.name)
    with open(path, "wb") as f:
        f.truncate(KILL_SHM_SIZE)
    fd = os.open(path, os.O_RDWR)
    try:
        mm = mmap.mmap(fd, KILL_SHM_SIZE)
    finally:
        os.close(fd)
    ctx.kill_shm = path
    return mm


def close_kill_shm(ctx, mm):
    mm.close()
    if ctx.kill_shm.exists():
        ctx.kill_shm.unlink()
    ctx.kill_shm = None


def await_kill_request(p, mm, tail, deadline, arm_at=None, gate_delay=None):
    """--kill-on writeback: wait for ktwatch's request -- the text
    "K w=<n> r=<n>" at offset 64 of the shared page, then a nonzero byte at
    0 -- and SIGKILL QEMU as soon as it is there.  From shortly before the
    trigger can arm (arm_at, or gate_delay s after the guest reports a
    checkpoint starting) it spins on the page; before, it looks every
    millisecond.  Returns (request, time of the kill), or (None, now) without
    killing when the run ended first: WRITE_DONE, the watcher gone without a
    request, QEMU gone, or the deadline passed."""
    next_check = 0.0
    while True:
        if mm[0]:
            os.kill(p.pid, signal.SIGKILL)
            killed = time.monotonic()
            req = mm[64:128].split(b"\n", 1)[0].decode("ascii", "replace")
            return req, killed
        now = time.monotonic()
        if arm_at is None or now < arm_at:
            time.sleep(0.001)
        if now < next_check:
            continue
        next_check = now + 0.02
        for l in tail.poll():
            if l.startswith("@@KT WATCH_GATE open") and gate_delay is not None \
                    and arm_at is None:
                arm_at = now + gate_delay - 2
            if l.startswith("@@KT WRITE_DONE") or l.startswith("@@KT FAIL ") or \
                    (l.startswith("@@KT WATCH_RC ") and kv(l).get("rc") != "1"):
                return None, now
        if p.poll() is not None or now > deadline:
            return None, now


def run_db_trial(ctx, t, golden):
    pfx = ctx.logs / ("t%03d" % t)
    rec = {"trial": t, "db": ctx.db, "fs": ctx.fs, "kill_on": ctx.kill_on}
    extra = ""
    if ctx.kill_on == "writeback":
        rec.update(kill_inflight=ctx.kill_inflight, kill_hold_us=ctx.kill_hold_us,
                   kill_gate=ctx.kill_gate, delay_ms=ctx.delays[t])
        extra = "kt.delay_ms=%d" % ctx.delays[t]
    elif ctx.kill_on in ("random", "checkpoint"):
        rec["delay_ms"] = ctx.delays[t]
    else:
        rec["wait_ms"] = ctx.wait_ms
    t0 = time.monotonic()
    subprocess.run(["cp", "--sparse=always", str(golden), str(ctx.test_img)],
                   check=True)
    rec["copy_s"] = round(time.monotonic() - t0, 1)

    kmm = (open_kill_shm(ctx) if ctx.kill_on in ("writeback", "random", "checkpoint")
           else None)
    try:
        p, wcon, wpro = start_vm(ctx, "dbwrite", str(pfx) + ".write", extra)
        ctx.live = p
        tail = Tail(wpro)
        started = None
        deadline = time.monotonic() + ctx.setup_timeout
        while started is None:
            for l in tail.poll():
                if l.startswith("@@KT WRITE_START"):
                    started = time.monotonic()
            if started is not None or p.poll() is not None or \
                    time.monotonic() > deadline:
                break
            time.sleep(0.005)
        if started is None:
            kill_vm(p)
            ctx.live = None
            tail.poll()
            parse_db_write(tail.lines, rec)
            rec["verdict"] = "setup_failed"
            rec.setdefault("fail", "no WRITE_START")
            rec["trial_s"] = round(time.monotonic() - t0, 1)
            return rec, (wcon,)
        if ctx.kill_on in ("time", "random", "checkpoint"):
            # run.exp: a fixed time into the run; random: a time of its own;
            # checkpoint: that long after the guest reports one starting
            if ctx.kill_on == "checkpoint":
                target = None
                until = started + ctx.settings["run_s"] + 60
                while target is None:
                    for l in tail.poll():
                        if l.startswith("@@KT WATCH_GATE open"):
                            target = time.monotonic() + ctx.delays[t] / 1000.0
                            rec["checkpoint_seen_s"] = round(
                                time.monotonic() - started, 1)
                            break
                    if target is None and (
                            p.poll() is not None or time.monotonic() > until or
                            any(l.startswith("@@KT WRITE_DONE")
                                for l in tail.lines)):
                        rec["no_checkpoint"] = True
                        target = time.monotonic()
                    elif target is None:
                        time.sleep(0.01)
            else:
                target = started + (ctx.wait_ms if ctx.kill_on == "time"
                                    else ctx.delays[t]) / 1000.0
            seq0 = None
            while True:
                now = time.monotonic()
                if now >= target:
                    break
                rem = target - now
                if kmm is not None and seq0 is None and rem < 0.004:
                    # the guest's sample count a few ms before the kill
                    seq0, tseq0 = struct.unpack("I", kmm[28:32])[0], now
                time.sleep(rem - 0.002 if rem > 0.003 else 0.0002)
            tail.poll()
            rec["write_done_before_kill"] = any(
                l.startswith("@@KT WRITE_DONE") for l in tail.lines)
            p.send_signal(signal.SIGKILL)
            killed = time.monotonic()
            if kmm is not None:
                # ktwatch's last sample, taken some 30 us before the kill
                w, r, gate, bmax, bus, seq = struct.unpack("6I", kmm[8:32])
                rec["at_kill"] = {"w": w, "r": r, "checkpoint": gate,
                                  "burst_max": bmax, "burst_us": bus,
                                  "samples": seq}
                if seq0 is not None and killed > tseq0:
                    # samples per second over the last few ms: about 30000
                    # when the watcher kept running, 0 when the sample is stale
                    rec["at_kill"]["recent_rate"] = round(
                        (seq - seq0) / (killed - tseq0))
        else:
            arm_at = gate_delay = None
            if ctx.kill_inflight > 0:
                if ctx.kill_gate == "checkpoint" and ctx.db == "postgres":
                    gate_delay = ctx.delays[t] / 1000
                else:
                    arm_at = started + ctx.delays[t] / 1000 - 2
            req, killed = await_kill_request(
                p, kmm, tail, started + ctx.settings["run_s"] + 120, arm_at,
                gate_delay)
            if req is not None:
                rec["kill_request"] = {k: int(x) for k, x in kv(req).items()
                                       if x.isdigit()}
            elif p.poll() is None:
                p.send_signal(signal.SIGKILL)
        p.wait()
    finally:
        if kmm is not None:
            close_kill_shm(ctx, kmm)
    ctx.live = None
    tail.poll()
    parse_db_write(tail.lines, rec)
    rec["kill_after_start_ms"] = round((killed - started) * 1000, 2)
    rec["setup_s"] = round(started - t0, 1)
    ws = rec.get("guest_time", {}).get("write.overwrite")
    if ws is not None and rec.get("gate_open_t"):
        rec["gate_after_start_s"] = round(rec["gate_open_t"][0] - ws, 1)
    if (ctx.kill_on == "writeback" and "kill_request" not in rec) or \
            rec.get("no_checkpoint"):
        if rec.get("watch_rc") == 0:
            rec["fail"] = "ktwatch sent a request the host never got"
        rec["verdict"] = db_verdict(rec, "")
        rec["trial_s"] = round(time.monotonic() - t0, 1)
        return rec, (wcon,)

    lines, vcon, timed_out = run_vm_until(ctx, "dbverify", str(pfx) + ".verify",
                                          ctx.verify_timeout)
    if timed_out:
        rec["verify_timeout"] = ctx.verify_timeout
    parse_db_verify(lines, rec, ctx.db)
    try:
        ctext = vcon.read_text(errors="replace")
    except FileNotFoundError:
        ctext = ""
    rec["verdict"] = db_verdict(rec, ctext)
    rec["trial_s"] = round(time.monotonic() - t0, 1)
    return rec, (wcon, vcon)


def cmd_db(a):
    c = DBFSCONF[a.fs]
    busy = busy_procs()
    if busy and not a.allow_busy:
        die("this host is running %s; a VM would perturb it and be perturbed"
            " (--allow-busy to run anyway)" % ", ".join(busy))
    ctx = make_ctx(a, a.fs, "db")
    ctx.db = a.db
    ctx.settings = dict(DB_PROFILES[a.profile])
    for k in ("tables", "rows", "threads", "age_s", "run_s", "rerun_s",
              "rand_type", "workload"):
        if getattr(a, k) is not None:
            ctx.settings[k] = getattr(a, k)
    ctx.wait_ms = a.wait_ms if a.wait_ms is not None else ctx.settings["wait_ms"]
    ctx.kill_on = a.kill_on or ctx.settings["kill_on"]
    ctx.kill_inflight = KILL_INFLIGHT if a.kill_inflight is None else a.kill_inflight
    if ctx.kill_on in ("random", "checkpoint"):
        ctx.kill_inflight = 0          # the guest only watches
    if ctx.kill_on == "checkpoint" and a.db != "postgres":
        die("--kill-on checkpoint is for PostgreSQL; InnoDB checkpoints all"
            " along (fuzzy checkpointing): --kill-on random")
    ctx.kill_hold_us = KILL_HOLD_US if a.kill_hold_us is None else a.kill_hold_us
    ctx.kill_gate = ("checkpoint" if ctx.kill_on == "checkpoint"
                     else a.kill_gate or KILL_GATE[a.db])
    if a.kill_delay_s:
        lo, hi = (float(x) for x in a.kill_delay_s.split(":"))
    elif ctx.kill_on == "random":
        lo, hi = RANDOM_DELAY_S
    else:
        lo, hi = KILL_DELAY_S[a.db]
    seed = a.seed if a.seed is not None else random.randrange(1 << 31)
    rng = random.Random(seed)
    ctx.delays = [int(rng.uniform(lo, hi) * 1000) for _ in range(a.trials)]
    test_size = a.test_size or ctx.settings["test_size"]
    ctx.test_size = test_size << 30
    ctx.setup_timeout, ctx.verify_timeout = a.setup_timeout, a.verify_timeout
    ctx.prep_timeout = a.prep_timeout
    conf, ctx.effective = db_conf(a, c, ctx)
    ctx.my_opts = ctx.effective["my_opts"]

    name = "%s_%s_%s" % (utcstamp(), a.db, a.fs)
    if a.profile != "sosp":
        name += "_" + a.profile + ("" if a.mem == "32G" else "_mem" + a.mem)
    if ctx.settings["rand_type"]:
        name += "_" + ctx.settings["rand_type"]
    if ctx.settings["workload"] != DB_SOSP["workload"]:
        name += "_" + ctx.settings["workload"].replace("oltp_", "")
    if a.threads is not None:
        name += "_t%d" % a.threads
    if a.cache_mb:
        name += "_cache%dM" % a.cache_mb
    if a.log_default:
        name += "_logdefault"
    if a.tag:
        name += "_" + a.tag
    if a.zfs_logbias and a.zfs_logbias != ctx.settings["zfs_logbias"]:
        name += "_logbias-" + a.zfs_logbias
    ctx.name = name
    # an image per profile: it is prepared, and aged, with its settings
    # The revision profile's caches follow --mem (PostgreSQL's go into the
    # image's postgresql.conf), so its images are per memory size too.
    tag = ""
    if a.profile != "sosp":
        tag = "-" + a.profile + ("" if a.mem == "32G" else "-mem" + a.mem)
    if a.zfs_logbias and a.zfs_logbias != ctx.settings["zfs_logbias"]:
        tag += "-logbias-" + a.zfs_logbias
    if a.log_default and a.db == "mysql":
        tag += "-logdefault"           # the redo files are made at --initialize
    golden = Path(a.image) if a.image else WORK / ("db-%s-%s%s.img"
                                                   % (a.db, a.fs, tag))
    # a trial's copy of the image, and the image itself when it is made now
    need_space(ctx.test_size * (2 if a.reprep or not golden.exists() else 1),
               "db")
    rundir = Path(a.out) / name if a.out else RESULTS / name
    ctx.logs = rundir / "logs"
    ctx.logs.mkdir(parents=True)
    WORK.mkdir(parents=True, exist_ok=True)
    ctx.tools = build_tools_disk(name, a.fs, "db", "", a.max_sectors_kb,
                                 ctx.release, tau=False, conf=conf, db=True)
    ctx.test_img = WORK / ("test-" + name + ".img")

    meta = {
        "tool": "killtest", "test": "db", "db": a.db, "fs": a.fs,
        "trials": a.trials, "profile": a.profile, "settings": ctx.settings,
        "effective": ctx.effective, "my_opts": ctx.my_opts,
        "kill_on": ctx.kill_on, "wait_ms": ctx.wait_ms,
        "max_sectors_kb": a.max_sectors_kb,
        "wbt_lat_usec": a.wbt_lat_usec, "test_size_gib": test_size,
        "db_start_timeout": a.db_start_timeout, "db_giveup_s": a.db_giveup_s,
        "fsconf": c, "image": str(golden),
        "kernel": ctx.kernel, "release": ctx.release,
        "kernel_version": ctx.kversion, "qemu": ctx.qemu,
        "qemu_version": qemu_version(ctx.qemu), "smp": ctx.smp, "mem": ctx.mem,
        "drive_opts": ctx.drive_opts, "append": ctx.append,
        "rootfs": str(ctx.rootfs),
        "host": socket.gethostname(), "started_utc": utcstamp(),
        "busy_at_start": busy,
    }
    if ctx.kill_on in ("writeback", "random", "checkpoint"):
        meta.update(kill_inflight=ctx.kill_inflight, kill_hold_us=ctx.kill_hold_us,
                    kill_gate=ctx.kill_gate,
                    kill_delay_s=[lo, hi], seed=seed, delays_ms=ctx.delays)
    recs = []

    def stop(signum, frame):
        if ctx.live is not None:
            kill_vm(ctx.live)
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, stop)
    try:
        if a.reprep or not golden.exists():
            meta["image_info"] = prepare_golden(ctx, golden)
        else:
            j = Path(str(golden) + ".json")
            meta["image_info"] = json.loads(j.read_text()) if j.exists() else {}
            say("reusing %s (%s)" % (golden, meta["image_info"].get("created_utc", "?")))
        (rundir / "run.json").write_text(json.dumps(meta, indent=1) + "\n")
        say("%s/%s (%s): %d trials, %s, kernel %s, -> %s"
            % (a.db, a.fs, a.profile, a.trials, kill_policy(meta), ctx.release,
               rundir))
        for t in range(a.trials):
            busy = busy_procs()
            if busy and not a.allow_busy:
                say("stopping before trial %d: %s started on this host"
                    % (t, ", ".join(busy)))
                break
            rec, consoles = run_db_trial(ctx, t, golden)
            drop_empty_qemu_logs(ctx.logs, t)
            recs.append(rec)
            with open(rundir / "trials.jsonl", "a") as f:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")
            keep = a.keep_console == "all" or t == 0 or \
                (a.keep_console == "failed" and rec["verdict"] != "clean")
            if not keep:
                for con in consoles:
                    if con.exists():
                        con.unlink()
            extra = ""
            if rec.get("fail"):
                extra = " (%s)" % rec["fail"]
            if "kill_request" in rec:
                extra += "  killed at %d writes in flight, %.1fs into the run" % (
                    rec["kill_request"].get("w", -1),
                    rec["kill_after_start_ms"] / 1000)
            elif "at_kill" in rec:
                k = rec["at_kill"]
                extra += "  killed %.1fs into the run, %d writes in flight%s" % (
                    rec["kill_after_start_ms"] / 1000, k["w"],
                    " (burst of %d, %d us old)" % (k["burst_max"], k["burst_us"])
                    if k["burst_max"] else "")
            say("%s/%s t%03d %s%s  log=%s scan=%s/%s  recovery %ss  %.0fs"
                % (a.db, a.fs, t, rec["verdict"], extra, rec.get("torn_log", "-"),
                   rec.get("scan_pre", "-"), rec.get("scan_post", "-"),
                   round(rec.get("recovery_ms", 0) / 1000, 1), rec["trial_s"]))
    except KeyboardInterrupt:
        if ctx.live is not None:
            kill_vm(ctx.live)
        say("interrupted after %d trial(s)" % len(recs))
    finally:
        for f in (ctx.tools, ctx.test_img):
            if f.exists() and not a.keep_images:
                f.unlink()
    if not (rundir / "run.json").exists():
        (rundir / "run.json").write_text(json.dumps(meta, indent=1) + "\n")
    text = summarize_db(recs, "%s_%s" % (a.fs, a.db))
    (rundir / "summary.txt").write_text(text + "\n")
    print(text)
    return 0


def cmd_summary(a):
    for d in a.dirs:
        recs = load_trials(d)
        meta = json.loads((Path(d) / "run.json").read_text())
        if meta.get("test") == "db":
            print("== %s  (%s, %s on %s, %s profile, %s)"
                  % (d, meta.get("release"), meta["db"], meta["fs"],
                     meta.get("profile", "sosp"), kill_policy(meta)))
            print(summarize_db(recs, "%s_%s" % (meta["fs"], meta["db"])))
            continue
        print("== %s  (%s, TEST_OPT '%s', WAIT_MS %s)"
              % (d, meta.get("release"), meta.get("test_opt"),
                 meta.get("wait_ms")))
        print(summarize(recs, "%s_%s" % (meta["fs"], meta["workload"])))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def vm_args(p):
        p.add_argument("--kernel", help="bzImage [%s; tau configs %s]"
                       % (BASE_KERNEL, TAU_KERNEL))
        p.add_argument("--qemu", default=QEMU,
                       help="[9.2.4 from mkqemu.sh if built, else tools/bin: %s]"
                            % QEMU)
        p.add_argument("--rootfs", default=str(ROOTFS))
        p.add_argument("--smp", type=int, default=16, help="vCPUs [16, as run.exp]")
        p.add_argument("--mem", default="32G", help="guest memory [32G, as run.exp]")
        p.add_argument("--append", default="", help="extra kernel command line")
        p.add_argument("--drive-opts", default="",
                       help="appended to the test -drive, e.g. ',cache=none'"
                            " [none: QEMU's default cache=writeback, as run.exp]")

    p = sub.add_parser("probe", help="boot once and report the guest environment")
    vm_args(p)

    p = sub.add_parser("run", help="run kill trials")
    vm_args(p)
    p.add_argument("--fs", required=True, choices=sorted(FSCONF))
    p.add_argument("--workload", default="seq", choices=WORKLOADS,
                   help="seq | rand (now really random: -R) | rand_single |"
                        " append  [seq]")
    p.add_argument("--trials", type=int, default=100, help="[100, as exp_all.sh]")
    p.add_argument("--test-opt", help="fs.c options [per --fs, as run_<fs>.exp]")
    p.add_argument("--wait-ms", type=int,
                   help="kill this long after the overwrite starts"
                        " [per --fs, as run_<fs>.exp]")
    p.add_argument("--mkfs", help="format command instead of the --fs one, with"
                                  " $TEST_DEV for the device, e.g. to give mkfs"
                                  " another round's geometry")
    p.add_argument("--wbt-lat-usec", type=int,
                   help="writeback throttling target on the test device; 0 turns"
                        " it off, as in the SOSP round's kernel (CONFIG_BLK_WBT=n)"
                        " [the kernel's default]")
    p.add_argument("--max-sectors-kb", type=int, default=4,
                   help="cap on the test device's requests; 0 leaves the"
                        " default [4, as run.exp]")
    p.add_argument("--test-size", type=int, default=16,
                   help="test device GiB [16, as exp.sh at 884f9ff; the"
                        " runs before it used 8]")
    p.add_argument("--setup-timeout", type=int, default=900)
    p.add_argument("--verify-timeout", type=int, default=900)
    p.add_argument("--no-fsck", action="store_true",
                   help="skip the read-only fsck after verifying (information"
                        " only; the SOSP round had none)")
    p.add_argument("--keep-console", default="failed",
                   choices=("all", "failed", "none"),
                   help="console logs to keep: all, those of trials that were"
                        " not clean (and trial 0), or none [failed]")
    p.add_argument("--keep-images", action="store_true",
                   help="keep the tools disk and the last test image")
    p.add_argument("--allow-busy", action="store_true",
                   help="run even if benchmarks or another VM are running")
    p.add_argument("--out", help="parent directory for the result directory"
                                 " [tools/killtest/results]")

    p = sub.add_parser("db", help="run the database kill trials (exp_db.sh)")
    vm_args(p)
    p.add_argument("--db", required=True, choices=("postgres", "mysql"))
    p.add_argument("--fs", required=True, choices=sorted(DBFSCONF))
    p.add_argument("--trials", type=int, default=20, help="[20, as exp_all.sh]")
    p.add_argument("--profile", default="sosp", choices=sorted(DB_PROFILES),
                   help="database settings: sosp (the SOSP round's) or"
                        " revision (bench/scripts', caches at 25%% of --mem,"
                        " kill during writeback) [sosp]")
    p.add_argument("--kill-on", choices=("time", "writeback", "random", "checkpoint"),
                   help="time: --wait-ms into the run, as run.exp;"
                        " writeback: when the guest sees --kill-inflight"
                        " writes in flight; random: at a uniform random time"
                        " in --kill-delay-s [30:270], recording what was in"
                        " flight; checkpoint (PostgreSQL): a random time in"
                        " --kill-delay-s [0:240] after a checkpoint starts"
                        " [per --profile]")
    p.add_argument("--kill-inflight", type=int,
                   help="writes in flight that trigger the kill; 0 never"
                        " kills and only reports what the guest sees [%d]"
                        % KILL_INFLIGHT)
    p.add_argument("--kill-hold-us", type=int,
                   help="the writes must have stayed in flight this long"
                        " [%d: at once]" % KILL_HOLD_US)
    p.add_argument("--kill-delay-s", metavar="LO:HI",
                   help="arm the trigger at a uniform random time in"
                        " [LO, HI] s into the run, or into a checkpoint with"
                        " --kill-gate checkpoint [mysql 30:240, postgres 0:240]")
    p.add_argument("--kill-gate", choices=("none", "checkpoint"),
                   help="checkpoint: armed only during PostgreSQL checkpoints"
                        " [postgres: checkpoint, mysql: none]")
    p.add_argument("--seed", type=int, help="for the arming delays [random]")
    p.add_argument("--watch-rt-prio", type=int,
                   help="SCHED_FIFO priority of the guest's watcher, 0 for"
                        " none [10 for --kill-on random, else 0]")
    p.add_argument("--wait-ms", type=int,
                   help="kill this long after the measured run starts [61000:"
                        " run.exp's 60 s timeout + WAIT_MS 1000]")
    p.add_argument("--tables", type=int, help="[32]")
    p.add_argument("--rows", type=int, help="rows per table [500000]")
    p.add_argument("--threads", type=int, help="[32]")
    p.add_argument("--age-s", type=int, help="run before the image is kept [300]")
    p.add_argument("--run-s", type=int,
                   help="the measured run's length [300; revision 600]")
    p.add_argument("--rerun-s", type=int, help="the run after recovery [30]")
    p.add_argument("--workload", dest="workload",
                   choices=("oltp_write_only", "oltp_update_non_index",
                            "oltp_update_index", "oltp_delete", "oltp_insert",
                            "oltp_read_write"),
                   help="sysbench workload of the runs [oltp_write_only, as"
                        " run.sh]; the image is the same for all")
    p.add_argument("--cache-mb", type=int,
                   help="the databases' caches (shared_buffers, buffer pool)"
                        " in MiB, instead of the profile's [revision: 25%% of"
                        " --mem]; the image is reused")
    p.add_argument("--pg-set", action="append", metavar="KEY=VALUE",
                   help="PostgreSQL setting for the runs (pg_ctl -o '-c ...');"
                        " repeatable")
    p.add_argument("--my-set", action="append", metavar="KEY=VALUE",
                   help="MySQL server option for the runs (--KEY=VALUE);"
                        " repeatable")
    p.add_argument("--tag", help="added to the result directory's name")
    p.add_argument("--log-default", action="store_true",
                   help="leave the log sizes at the databases' defaults (MySQL"
                        " redo 100M, PostgreSQL max_wal_size 1GB) instead of"
                        " the profile's [revision: 16G]; MySQL gets its own"
                        " image")
    p.add_argument("--zfs-logbias", choices=("latency", "throughput"),
                   help="zfs-*: the data's logbias, a separate image [the"
                        " profile's: sosp ZFS's default, latency; revision"
                        " throughput, the WAL/redo in zfspool/log at latency]")
    p.add_argument("--rand-type", choices=("special", "uniform", "gaussian",
                                           "pareto"),
                   help="sysbench's row distribution in the runs [its default,"
                        " special: 99%% of the accesses to a third of each"
                        " table]; the image is the same for all")
    p.add_argument("--image", help="prepared database image [work/db-<db>-<fs>.img,"
                                   " -<profile>.img but for sosp; made if missing]")
    p.add_argument("--reprep", action="store_true",
                   help="prepare the image again even if it exists")
    p.add_argument("--wbt-lat-usec", type=int,
                   help="writeback throttling on the test device [kernel default]")
    p.add_argument("--max-sectors-kb", type=int, default=4,
                   help="cap on the test device's requests during the run [4,"
                        " as run_db.sh]")
    p.add_argument("--test-size", type=int,
                   help="GiB [16, as exp_db.sh; revision 40, for its redo]")
    p.add_argument("--setup-timeout", type=int, default=1800)
    p.add_argument("--verify-timeout", type=int, default=3600)
    p.add_argument("--prep-timeout", type=int, default=7200)
    p.add_argument("--db-start-timeout", type=int, default=600,
                   help="seconds the database may take to come up after the"
                        " crash; a server still not up is killed [600]")
    p.add_argument("--db-giveup-s", type=int, default=60,
                   help="MySQL: seconds to keep waiting after its log reports"
                        " a corrupted page (it never comes up then) [60]")
    p.add_argument("--keep-console", default="failed",
                   choices=("all", "failed", "none"))
    p.add_argument("--keep-images", action="store_true")
    p.add_argument("--allow-busy", action="store_true")
    p.add_argument("--out", help="parent directory for the result directory"
                                 " [tools/killtest/results]")

    p = sub.add_parser("summary", help="summarize result directories")
    p.add_argument("dirs", nargs="+")

    a = ap.parse_args()
    return {"probe": cmd_probe, "run": cmd_run, "db": cmd_db,
            "summary": cmd_summary}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
