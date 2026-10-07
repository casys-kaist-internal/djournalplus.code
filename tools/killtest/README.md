# killtest

The SOSP round's torn-write experiment -- boot a VM, start an fsync-heavy
overwrite, kill QEMU, boot again, check every 16 KiB chunk -- ported from
Yewon Choi's `taujournal-test.code` (casys-kaist-internal/taujournal-test.code
at 1c65ec9: `scripts/exp.sh`, `scripts/exp/run.exp`, `run_<fs>.exp`,
`tests/src/fs.c`) so that it runs from this tree, without sudo, expect or a
login.

```sh
WITH_ZFS=1 WITH_DB=1 tools/killtest/mkrootfs.sh   # once (sudo)
tools/killtest/mkqemu.sh                      # optional: QEMU 9.2.4, as in the SOSP round
tools/killtest/killtest.py probe              # what the guest sees
tools/killtest/killtest.py run --fs ext4 --workload seq --trials 100
tools/killtest/killtest.py db --db postgres --fs ext4 --trials 20
tools/killtest/killtest.py db --db mysql --fs xfs --profile revision --trials 20
tools/killtest/killtest.py summary tools/killtest/results/<host>/<run>
```

Both halves of the SOSP round's test are here: the microbenchmark (`run`,
from `exp.sh`) and the databases (`db`, from `exp_db.sh`; see *The database
test* below).

## One trial

Same steps as `run.exp`:

1. Boot (16 vCPUs, 32 GiB).  The test disk is an emulated NVMe
   (`-device nvme,serial=deadbeef`) backed by a fresh sparse 16 GiB file, with
   QEMU's default `cache=writeback`.  Set `max_sectors_kb=4` on it, format it,
   mount it.
2. `fs -Z`: 32 threads, one file each, fill them with zeros in 16 KiB
   `pwrite()`s, `fsync` every 8; remount; `fs -Z -V` checks the zeros.
3. Print `WRITE_START`, start `fs` (the same files, now with a pattern), and
   `SIGKILL` QEMU `WAIT_MS` later.
4. Boot again, mount -- the file system's recovery runs here -- and run
   `fs -V`: each chunk must be all zeros or all pattern.  Anything else is a
   torn write.  Then a read-only fsck, for information.

A trial is **torn** when the verifier prints `torn write(s) detected`, as
`exp.sh` counted.  The other verdicts only say why a trial could not be
judged: `setup_failed`, `mount_failed`, `verify_error`, `verify_timeout`,
`guest_panic`.

| `--fs` | from | mkfs, mount | TEST_OPT | WAIT_MS |
|---|---|---|---|---|
| `ext4` | run_ext4.exp | `mkfs.ext4 -F` | `-t 32 -s 64M -b 16K -F 8` | 100 |
| `ext4-dj` | run_ext4-dj.exp | `mkfs.ext4 -F`, `-o data=journal` | `-t 32 -s 8M -b 16K -F 8` | 300 |
| `xfs` | run_xfs.exp | `mkfs.xfs -f` | same | 1000 |
| `f2fs` | run_f2fs.exp | `mkfs.f2fs -f` | same | 500 |
| `btrfs` | run_btrfs.exp | `mkfs.btrfs -f` | same | 1000 |
| `zfs-16k` | run_zfs-16k.exp | pool on the disk, `recordsize=16K` | same | 1000 |
| `tau-ext4` | run_taujournal.exp | fork `mke2fs`, `-o tjournal` | same `+ -T` | 1000 |
| `tau-xfs` | run_xfs-tau.exp | fork `mkfs.xfs`, `-o tjournal` | same `+ -T` | 1000 |

Workloads (`--workload`): `seq`, `rand` (random chunk order), `rand_single`
(one shared file, a region per thread), `append` (fragment free space, then
write new files).  Results land in `results/<host>/<UTC time>_<fs>_<workload>/`
(`KILLTEST_RESULTS` overrides `results/<host>`; the rates depend on the machine):
`run.json` (settings, kernel, QEMU, package versions), `trials.jsonl` (one
record per trial: verdict, torn threads, where each torn chunk splits, how
many chunks were new, kill time, recovery mount time, kernel lines, fsck),
`summary.txt`, and `logs/` (the guest's markers for every boot, and the
console of trial 0 and of every trial that was not clean).  Results stay on
the machine that made them (`logs/` is packed as `logs.tar.xz` when a run is
filed); git keeps one summary per machine, `results/<host>/SUMMARY.md`.

## The database test

`killtest.py db` is `exp_db.sh` with `exp_db/create.exp` and `run.exp`, and the
settings of `bench/scripts` at the SOSP round's commit (32f592b):

- **Image, once per database and file system** (`work/db-<db>-<fs>.img`):
  format as `common.sh` did (ext4 and ext4-dj: `mke2fs -E
  lazy_itable_init=0,lazy_journal_init=0`; zfs-8k for PostgreSQL and zfs-16k
  for MySQL: `ashift=12` and that recordsize), `initdb --data-checksums` with
  `full_page_writes = off` and `max_wal_size = 2GB` / `mysqld
  --initialize-insecure`, sysbench `oltp_read_write prepare` with 32 tables of
  500,000 rows (about 4 GB), then -- as `create.exp` did -- one 300 s run of
  `oltp_write_only`, and keep what that leaves.
- **Trial**: copy the image, `max_sectors_kb=4`, start the database (MySQL:
  doublewrite off, buffer pool 16G), 10 s of warm-up, then `oltp_write_only`
  with 32 threads; SIGKILL 61 s into it (`run.exp`: "Start Benchmarking", 60 s,
  then `WAIT_MS` 1000).  Boot again: the file system recovers on mount, the
  database on start, then runs 10 + 30 s more.
- **Verdict**: torn when the database's log says what `exp_db.sh` looked for --
  `invalid page` (PostgreSQL) or `Database page corruption on disk` (MySQL).
  Every page is also checked offline, before recovery -- `innochecksum` on
  the tables as the crash left them; for PostgreSQL `src/pgscan.c`,
  `pg_checksums --check`'s check on a cluster that was not shut down, which
  `pg_checksums` refuses -- and after it (`pg_checksums`, or `pgscan` again
  when recovery failed).  A trial whose log missed what a scan found is
  `torn_scan`; one where the database did not come back is
  `recovery_failed`.  MySQL never comes up after its log reports a corrupted
  page during recovery; it is given up on `--db-giveup-s` (60) later.

### Killing during writeback (`--profile revision`)

With the SOSP round's protocol the kill lands at a fixed time, and a torn
page needs it to land while a data page is being written: four 4 KiB
requests (MySQL) or two (PostgreSQL) of which some have reached the image
and some have not.  Data pages are written in bursts -- a checkpoint's
writeback, an `fsync` of the tablespaces -- and between bursts the device
sees log writes, which have their own checksums.  `--kill-on writeback`
aims the kill at the bursts:

- **Trigger** (`src/ktwatch.c`, in the guest): it polls the test device's
  `/sys/block/nvme0n1/inflight` every 20 us and, once armed, sends a request
  the first time `--kill-inflight` (64) or more writes are in flight
  (`--kill-hold-us`: for that long).  64 is where the data pages are: in
  runs that only watched (below), data-page writeback came in bursts of
  64-127 4 KiB writes lasting 0.3-1 ms -- MySQL's 16-page flush batches,
  PostgreSQL's 256 kB checkpoint writebacks -- while log writes stayed
  under 32 and mostly under 300 us.
- **Kill path**: the request is a store into a page the host shares with
  the VM (an `ivshmem-plain` device backed by a file in `/dev/shm`), on
  which the host spins; SIGKILL follows some 15 us later.  It cannot be an
  I/O port or a serial line: QEMU serves those under its big lock, which
  its NVMe emulation holds while it takes a batch of requests off the
  queue, so the kill would wait until the batch is handed to the I/O
  threads -- which need only microseconds to put 4 KiB writes into the
  host's page cache.  A first version did that (through `isa-debugcon`): five
  kills with 21-64 writes in flight, no torn page.
- **Arming**: at a random time, uniform in `--kill-delay-s` (`--seed`
  repeats them), into the measured run (MySQL, 30-240 s: its page cleaner
  and checkpointer write data pages all along), or into a checkpoint
  (PostgreSQL, 0-240 s after `checkpoint starting`: a database that fits in
  shared_buffers has its data pages written by checkpoints only, which a
  spread checkpoint does over 270 s).  The first timed checkpoint starts 5
  minutes after the server, so PostgreSQL's runs last 10 minutes.
- A trial whose run ends before the trigger fires is `no_trigger` and not
  judged.  `--kill-inflight 0` never kills and reports, every 10 s, how many
  writes it saw in flight and the bursts of 8 or more by size and length
  (`summary` adds them up), to choose the threshold.

The first runs (`results/libra09/SUMMARY.md` §3.4, 10 trials
each) tore pages in MySQL on ext4 9 times and on xfs 4, in PostgreSQL 6 and
6; with the SOSP round's fixed kill time the same file systems gave 0-2 of
20 (`results/libra09/SUMMARY.md` §3.2).

### Killing at a random time (`--kill-on random`)

The kill comes at a uniform random time in `--kill-delay-s` (30-270 s) into
the run, from a host timer; nothing in the guest decides it.  To make random
kills land in data-page writeback often enough, the VM is small: with
`--mem 2560M` the caches are 640 MB (25%) and the tables (4-5 GB) are 1.9
times memory and 7.5 times the caches -- the ratios of the performance runs
on the host (about 120 GB of data, 64 GB, 16 GB caches) -- so data pages are
evicted and written all along.  Watching only, the device then had 64 or
more writes in flight 13% of the time for PostgreSQL and 9% for MySQL (1.3%
and 1.4% at 32 GB).  The guest's watcher, SCHED_FIFO (`--watch-rt-prio`),
leaves its latest sample in the shared page; the host reads it after the
kill, with how fast samples were still coming (`at_kill`), and `summary`
splits the outcome by what was in flight.  `--rand-type uniform` (the
revision's sensitivity variant) touches the whole database instead of
mostly a third of it: more dirty data and more writeback
(`results/libra09/SUMMARY.md` §3.5: 3-5 of 20 random kills
tore pages in every configuration).  MySQL on ext4 then tears mostly with no
write in flight -- but only with the 4 KiB request cap below: without it,
1 of 20 random kills tore, 0 of 18 with nothing in flight
(`results/libra09/SUMMARY.md` §3.9), so that too is the device model,
not the page cache.

The `revision` profile is the performance runs' settings
(`bench/scripts/{postgres,mysql}/api.sh`) with the caches at 25% of the
VM's memory, as they are at 25% of the host's: `shared_buffers` and the
buffer pool 8 GB of 32, `max_wal_size` and `innodb_redo_log_capacity` 16 GB,
MySQL with `innodb_flush_method=fsync`, no binary log, no redo spin-waits
(`innodb_log_spin_cpu_pct_hwm=0`); PostgreSQL with `log_checkpoints`, and
without WAL zero-fill and recycling on ZFS.  Protection is off, as in the
SOSP round.  ZFS is laid out as `common.sh` makes it, after OpenZFS's
workload tuning guide: the data with `logbias=throughput`, so that a page an
fsync commits is written out as a whole block the log points to instead of
being copied into the ZIL -- with the default (latency) a copy split across
two log blocks can replay half new (`results/libra09/SUMMARY.md` §3.3,
openzfs/zfs#17879) -- and the WAL/redo in their own dataset, `zfspool/log`
at `$TEST_DIR/log`, at the defaults (recordsize 128K, logbias latency).
`--zfs-logbias latency` puts the data back on the ZIL, in an image of its
own.  The profile's images are prepared and aged with these settings
(`work/db-<db>-<fs>-revision.img`; MySQL's redo at its run-time capacity from
`--initialize` on, as `create_image.sh` does) on a 40 GiB test device.  The
tables are the SOSP round's (32 x 500,000 rows), so the data fits in the
caches; the performance runs' data does not.

The databases are this tree's builds (`bench/workspace/pg_install`, PostgreSQL
17.5; `bench/mysql-server/build`, MySQL 8.4.5), copied onto the tools disk;
the rootfs carries their system libraries and sysbench (`WITH_DB=1`).  The
server runs as the unprivileged `ktdb`.  One deviation from the SOSP round:
MySQL on ZFS runs with `innodb_use_native_aio=OFF` (OpenZFS's tuning guide;
with native AIO a host running OpenZFS 2.2.2 hard-locked, 2026-10-02).

## What this crash model can and cannot produce

- **A write QEMU completed is never lost.**  With `cache=writeback` every
  completed guest write sits in the host page cache, which outlives the QEMU
  process; a guest FLUSH becomes an `fdatasync` of the image, but nothing here
  depends on it.  A crash state where a completed but unflushed write is
  missing -- a volatile device cache (Torner's model R) -- never occurs.
- **What can be missing is what was in flight.**  `max_sectors_kb=4` splits
  every write into 4 KiB requests (QEMU's NVMe takes 512 KiB), so a 16 KiB
  chunk becomes four requests and the kill can land between them: a device
  whose atomic unit is 4 KiB tearing a larger write (Torner's model T).
  Without that cap a 16 KiB write is a single request; MySQL on ext4 then
  tore 1 of 20 random kills instead of 7 (`results/libra09/SUMMARY.md` §3.9).
  The cap is kinder than the hardware's guarantee: the perf runs' PM1735 and
  the 990 PRO promise atomicity across a power failure for 512 B (`nvme id-ctrl`
  AWUPF 0 with 512 B blocks).
- **One crash point per trial**, a fixed time into the overwrite (or, for
  the databases with `--kill-on writeback`, the first moment past a random
  time that enough writes are in flight).  The rate depends on timing --
  host, QEMU version, how far the workload had got -- which is the
  reviewers' objection to "killed N times, saw M%".  Torner enumerates the
  crash states instead.
- **Atomicity only.**  Each chunk goes from zeros to a pattern once; nothing
  records which writes were fsynced, so a lost durable write reads as "old"
  and is not flagged.
- **The rates do not carry over between environments.**  The first runs here
  (`results/libra09/SUMMARY.md` §3.1) reproduce the SOSP round's ext4
  data=journal rate, but not its xfs or ext4 rates -- with the same harness,
  the same settings and the workload killed at the same point.  The QEMU
  version, the device size and writeback throttling were each ruled out.

## Differences from the SOSP harness

| | taujournal-test.code | killtest |
|---|---|---|
| guest control | expect over the serial console, root login | init stub (`guest/init`) runs `guest.sh` from a tools disk; markers come back on a second serial port |
| rootfs | debootstrap noble + apt, systemd | debootstrap noble (minbase) with the same distro tools, booted read only; no systemd (udevd for zfs only) |
| baseline kernel | vanilla v6.8 (`6.8.0-ge8f897f4afef`), built with `kernels/vmconfig` | `/boot/vmlinuz-6.8.0+`: vanilla 6.8 with `/boot/config-6.8.0+`; modules from the host |
| writeback throttling | not built (`CONFIG_BLK_WBT=n`) | on (`wbt_lat_usec` 2000); `--wbt-lat-usec 0` turns it off |
| tau kernel | `6.8.0tjournal+` | `codes/djournalplus-kernel.code/arch/x86/boot/bzImage` (`--kernel` to change) |
| QEMU | 9.2.4 | 9.2.4 when `mkqemu.sh` has built it, else 7.2.1 (`tools/bin`); `--qemu` to choose |
| privileges | QEMU under sudo (`SUDO_KEY`); `build_kernel.sh` installs into the host's `/boot` | the kvm group; sudo only in `mkrootfs.sh` |
| `rand` | same as `seq`: `run.exp` never passed `-R` (every SOSP rand log reads `rand_write=NO`) | `-R` |
| tau | `-o tjournal` without `O_TAU_UNTORN`, which tau needs per file | `-T`; the forks' default tau journal (`-J tau_journal_size=` and `-l tjsize=` are gone) |
| `rand_single` verify | ran `fs` -- `VERIFY_EXE` was set proc-locally | `fs_single` |
| test device | `test.bin` reused (`dd count=0` keeps its contents), reformatted; 8 GiB until 884f9ff (2026-03-29), 16 GiB after | a fresh sparse file per trial, 16 GiB (`--test-size`) |
| mkfs in the guest | `mke2fs 1.47.2` and an xfsprogs ≥ 6.10 (`parent=0`), per their logs -- neither is noble's | noble's stock: e2fsprogs 1.47.0, xfsprogs 6.6.0 |
| ext4 settings | changed during the round: `-s 8M` at several WAIT_MS -- about 300, 100 and 30 ms, judging by how far the overwrite had got -- 0/100 each, then `-s 64M` at 100 ms, 1/100 | the last, `run_ext4.exp` at 884f9ff |
| kill time | `WAIT_MS` after typing the command | `WAIT_MS` after `WRITE_START`, printed right before the program starts |
| zfs | `zfs mount` after the `zfs set`s failed with "already mounted", unchecked | the same properties given at `zpool create`; mount only if not mounted |
| network | virtio-net | none |

`fs.c` and `fs_single.c` are the originals, built the same way (`-Wall -g`,
so `-O0`; statically linked here).

## Notes

- **This host is shared with benchmarks.**  `run` refuses to start, and stops
  before the next trial, while `mysqld`, `postgres`, `sysbench`, `fio`,
  `pgbench` or another QEMU is running (`--allow-busy` overrides).  One VM at
  a time: parallel VMs would change the timing being measured.
- Baselines are formatted with the distro mkfs of the rootfs; the host's
  `mke2fs`/`mkfs.xfs` and those in the perf VM image are tau forks.
  `work/rootfs-packages.txt` records the versions.
- `work/` (gitignored) holds the rootfs, and per run a tools disk and the test
  image, which are deleted at the end (`--keep-images` keeps them).
- tau results describe the kernel build they ran on; its recovery path is
  still being patched.
