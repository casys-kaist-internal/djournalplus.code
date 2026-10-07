# tautest — crash-recovery and concurrency tests for taujournal

These are the tests used to validate the tau journal on ext4 and XFS: they
check that data an application fsync-acked survives a power cut, and that the
write/commit/checkpoint paths hold up under concurrency.

Everything runs against a **real NVMe device passed through to the QEMU guest**
(`tools/qemu/run_vm.sh`). A power cut is simulated by `SIGKILL`-ing qemu, which
drops anything that had not reached the device.

> **These tests destroy the test device.** Every run starts with `mkfs` on
> `$TAU_DEV` (default `/dev/nvme0n1`) inside the guest.

## Layout

```
tools/tautest/
├── src/                    workload programs (built inside the guest)
│   ├── tauwrite.c          write a pattern + fsync   (must survive a crash)
│   ├── tauwrite_nofsync.c  write, no fsync           (negative control)
│   ├── taurace.c           writer thread + fsync thread on one range
│   ├── tauappend.c         append records, report throughput and latency
│   ├── tauoverwrite.c      rewrite existing blocks (setup phase excluded)
│   ├── tausync.c           write + a chosen durability barrier (fsync/sync/...)
│   ├── taushort.c          a write whose source buffer faults partway (short copy)
│   └── tauabort.c          writers until the journal aborts; acks; post-recovery check
├── Makefile                builds the three binaries, installs to ~/tautest
├── guest/                  run inside the VM
│   ├── common.sh           device/mount/mkfs helpers, md5 expectations
│   ├── matrix-write.sh     lay out the matrix (run before the crash)
│   ├── matrix-verify.sh    mount after recovery and check every file
│   ├── stress.sh           concurrency hunt for kernel BUGs and hangs
│   ├── db-common.sh        shared mkfs/mount/wait helpers for the DB tests
│   ├── db-smoke.sh         bring PostgreSQL / MySQL up on a tau filesystem
│   ├── db-workloads.sh     a spread of workload shapes on one filesystem
│   ├── append-bench.sh     append throughput, tau vs vanilla
│   ├── overwrite-bench.sh  overwrite throughput and write amplification
│   ├── rewrite-same.sh     rewrite one region repeatedly, across TAU_SMALL_TX
│   ├── write-attrib.sh     split device writes into journal vs in-place
│   ├── sync-write.sh       one file per durability barrier
│   ├── sync-verify.sh      check which barriers survived the crash
│   ├── sync-race-write.sh  big write aimed at the in-flight commit window
│   ├── sync-race-verify.sh check it, with size/first-difference diagnostics
│   ├── revoke-write.sh     set up a revoke-tag case (gap/stale + controls) and arm
│   ├── revoke-verify.sh    mount after the crash and check what recovery kept
│   ├── seg-order.sh        set up / verify the segment-release-order case (#17)
│   ├── seg-reuse.sh        set up / verify stale txs in a reused segment (#25)
│   ├── seg-straddle.sh     set up / verify a checkpointed straddling newest tx (#27)
│   ├── split-write.sh      set up a write that spans journaled and in-place blocks (#21)
│   ├── split-verify.sh     check the write came back whole or not at all
│   ├── trunc-reuse.sh      free a tau file's blocks, let another file reuse them (#20)
│   ├── range.sh            collapse / insert / zero / unaligned punch+truncate / big fallocate
│   ├── shortcopy.sh        a short copy into a block the page cache had not read (#24)
│   ├── odirect.sh          O_DIRECT on a tjournal mount: plain file, tau file, refused open (#40)
│   ├── seg-adopt.sh        journal segments a crash left mapped past a hole (#37)
│   ├── abort.sh            inject a fault, check fail-stop, umount + mount, verify (#22, #7)
│   ├── trunc-race.sh       truncate / punch hole racing writes and fsync
│   ├── umount-stress.sh    mount/write/umount churn (->sync_fs vs teardown)
│   ├── db-crash-prepare.sh load a DB and leave a workload running
│   ├── db-crash-verify.sh  restart it after the crash and check the invariant
│   ├── fsync-anatomy.sh    one fsync request by request: phases, flushes, FUA (ftrace)
│   ├── db-bench.sh         sysbench update + insert on a tau fs: TPS, p95, flush/s, tau commits/s
│   ├── flushorder.sh       dm-log-writes: every crash state a device cache allows
│   ├── xfs-hold-probe.sh   measure whether the XFS ordering bracket is reached
│   └── xfs-hold-stress.sh  repeat the workload that wedges that bracket
└── host/                   run on the host, drives the VM over ssh
    ├── vm.sh               boot / crash / reboot / sync helpers
    ├── crash-test.sh       boot → write → crash → boot → verify
    ├── stress-test.sh      run the concurrency hunt in the guest
    ├── sync-test.sh        crash-check sync(2)/syncfs(2), not just fsync
    ├── sync-race-test.sh   multi-round crash test for the commit/segment paths
    ├── revoke-test.sh      crash-check revoke-tag lifetime (fsync, checkpoint drop)
    ├── seg-order-test.sh   crash-check segment release order (bug #17)
    ├── seg-reuse-test.sh   crash-check stale txs in a reused segment (bug #25)
    ├── seg-straddle-test.sh crash-check a checkpointed straddling newest tx (bug #27)
    ├── split-test.sh       crash-check one write's blocks journaled and in place (bug #21)
    ├── epoch-test.sh       power-cut inside an allocating commit: host metadata vs the record (#44, #49-#51)
    ├── db-rollback-test.sh a live database over a rolled-back commit (#44)
    ├── flushorder-test.sh  flush order through dm-log-writes, with a control (§21)
    ├── trunc-reuse-test.sh crash-check replay over blocks freed and reused (bug #20)
    ├── range-test.sh       range operations keep the data, runtime and crash (#26 #36 #38 #39)
    ├── shortcopy-test.sh   a faulting write leaves the rest of its block alone (#24)
    ├── odirect-test.sh     O_DIRECT through tau for tau files, real for the rest (#40)
    ├── seg-adopt-test.sh   segments a crash left mapped come back to a full FS (#37)
    ├── abort-test.sh       a journal abort stops cleanly and recovers, per fault site (#22, #7)
    ├── trunc-race-test.sh  truncate / punch racing writes and fsync (bugs #28-#30)
    ├── db-crash-test.sh    crash a running database and check it recovers
    └── xfs-hold-test.sh    drive xfs-hold-stress.sh over several configurations
```

## Prerequisites

* A guest image reachable over ssh at `localhost:5555` with passwordless sudo.
* `TAUFS_KERNEL` pointing at the kernel tree (defaults to
  `../codes/djournalplus-kernel.code` relative to `tools/`), already built —
  `run_vm.sh` boots `arch/x86/boot/bzImage` directly.
* **Patched mkfs binaries in the guest.** Stock mkfs cannot create the tau
  journal, which lives in the filesystem itself:
  * XFS: `xfsprogs-dev/mkfs/mkfs.xfs` — creates `tjournal`/`tjournal_dummy` in
    the root directory. Journal geometry: `-l tjsegsize=,tjmaxsize=`
    (defaults: 128 MiB segments, journal ≈ 10% of the device).
    `tjmaxsize` only sizes the segment map, whole map blocks of 256 segments
    (32 GiB at 128 MiB): `tjmaxsize=1G` journals up to 32 GiB. The cap is
    the mount option `tjournal_size=` (GiB), on XFS as on ext4.
  * ext4: `e2fsprogs/misc/mke2fs` — creates the tau journal at mkfs time.
* Mount option is `-o tjournal` on both filesystems.

Override paths through the environment if your layout differs:

```sh
TAU_DEV=/dev/nvme1n1 TAU_MNT=/mnt/tau \
MKFS_XFS=$HOME/xfsprogs-dev/mkfs/mkfs.xfs \
MKE2FS=$HOME/e2fsprogs/misc/mke2fs \
  ./host/crash-test.sh both
```

## Running

From the host, with the kernel already built:

```sh
cd tools/tautest

./host/crash-test.sh both      # crash recovery, ext4 + XFS   (~15 min)
./host/crash-test.sh xfs       # one filesystem only

./host/stress-test.sh both     # concurrency hunt             (long, see below)
./host/stress-test.sh ext4 300 6 5    # rounds, racers, seconds per round
```

Every test at once, and the overnight soak -- the same list:

```sh
./host/suite.sh                        # each test once (~3.5 h), summary.txt at the end
HOURS=8 ./host/suite.sh                # the soak: the list again and again until 8 h are up
ONLY='unlink|crash' ./host/suite.sh    # a subset, by name
```

Each test checks one guarantee, most of them the one a numbered bug broke, and a
fixed bug brings its test into the list -- so the suite grows with every fix.
They are system tests, not unit tests: a real kernel in a VM, a real NVMe,
syscalls only, and a power cut where the guarantee is about crashes. Three kinds:

- **scenario** -- deterministic; one pass means the path is right: crash, sync,
  revoke, seg-*, split, trunc-reuse, range, shortcopy, odirect, unlink, abort,
  falloc, repair.
- **race hunt** -- probabilistic; a clean pass is weak evidence, which is what
  the soak's repetition is for: stress, trunc-race, sync-race, cp-race,
  xfs-hold, torn.
- **workload** -- a real database end to end: db-crash (PostgreSQL, MySQL),
  pg-torn.

A new test goes into `TESTS` in `host/suite.sh` (name, deadline, command). Past
its deadline a test's qemu is killed and the test fails, with the console tail
and the guest's dmesg kept next to its log.

The host scripts copy `guest/` and `src/` into the VM, build the binaries there,
and drive the boot/crash cycle. To work inside the guest by hand:

```sh
cd ~/tautest && make && make install PREFIX=$HOME/tautest
~/tautest/guest/matrix-write.sh ext4     # then crash the VM from the host
~/tautest/guest/matrix-verify.sh ext4    # after rebooting
~/tautest/guest/stress.sh ext4 200 6 5
```

## What the crash matrix covers

`matrix-write.sh` writes these, all fsync-acked, then forces checkpointing with
large writes. `matrix-verify.sh` re-mounts after the crash and compares md5s.

| File | Pattern | What it exercises |
|------|---------|-------------------|
| `fA` | 3 MB | baseline single transaction |
| `fB` | 200 MB | spans more than one 128 MB journal segment |
| `fC` | 3 MB written twice (33 → 44) | overwrite: second write goes in place with a revoke record; recovery must not replay the older journaled copy |
| `fD` | 3 MB at 0, 3 MB at 8 MB | two transactions (tid 0 and 1) with a hole between them |
| `fE` | 5000 B at offset 512 | unaligned offset, partial blocks |
| `fF` | 3 MB, **no fsync** | negative control — any content is acceptable |
| `fG` | 2 MB written three times (91 → 92 → 93) | the re-journal cycle: anchored → revoke → re-journal |
| `race` | 1 MB, writer + fsync threads, then a settled write | write-during-commit (`BH_TauPending`), revoke handling under concurrency |

Expected digests are computed at verify time from the same patterns, so
adjusting sizes in `matrix-write.sh` does not require touching the checks.

The verifier also fails on any `kernel BUG`, `invalid opcode`, `soft lockup` or
hung-task report since boot -- and on tau's own checkpoint stall reports and a
stale `BH_TauOnWrite` found at unmount (bug.md #6) -- and requires a clean
unmount at the end. Every test that checks `kernel_faults()` does the same.

## What the stress test covers

`stress.sh` runs several `taurace` processes against separate files while large
writes keep the checkpoint daemon busy. It stops at the first kernel complaint
and triggers `sysrq-w` (blocked-task stacks) if a racer hangs.

This is the workload that surfaced the write-during-commit bugs. **Be patient**:
individual failures took anywhere from 30 seconds to ~30 minutes of continuous
hammering to appear, so a short clean run does not prove much. A few hundred
rounds is a reasonable bar.

## Database smoke test

`db-smoke.sh` checks that real software runs on a tau filesystem: initdb /
start / load / run / clean shutdown, then looks for anything the server or the
kernel complained about. It is not a benchmark — it is the "does the patch
break Postgres or MySQL" check. Filesystem names and mount options follow
`bench/scripts/common.sh`.

```sh
~/tautest/guest/db-smoke.sh ext4-tau postgres 10   # scale 10 pgbench
~/tautest/guest/db-smoke.sh xfs-tau  mysql
~/tautest/guest/db-smoke.sh ext4-tau both
```

It needs the binaries the bench tree builds. They are not in the guest by
default; copy them from the host (both sides are the same distro, so the
binaries work as-is):

```sh
# PostgreSQL (~35 MB)
tar -C bench/workspace -cf - pg_install |
  ssh -p 5555 host 'tar -C ~/djournalplus.code/bench/workspace -xf -'

# MySQL (~270 MB): mysqld links against build/lib via RPATH, so recreate the
# library_output_directory name it was built with.
cd bench/mysql-server/build
tar -chf - bin/mysqld bin/mysql bin/mysqladmin share lib |
  ssh -p 5555 host 'tar -C ~/djournalplus.code/bench/mysql-server/build -xf -'
ssh -p 5555 host 'cd ~/djournalplus.code/bench/mysql-server/build &&
                  ln -sfn ./lib library_output_directory &&
                  sudo apt-get install -y libaio1t64 libnuma1'
```

PostgreSQL runs with `full_page_writes = off`, which is the setting tau is
meant to make safe and therefore the interesting one to exercise.

### Workload shapes

One benchmark shape proves little — a journal is stressed differently by bulk
sequential writes than by tiny random updates. `db-workloads.sh` walks a spread
of them on one filesystem and checks each for server and kernel errors:

```sh
~/tautest/guest/db-workloads.sh ext4-tau 30 20    # scale, seconds per pattern
```

| # | Pattern | Shape it exercises |
|---|---------|--------------------|
| 1 | bulk load (COPY) | large sequential writes + index build |
| 2 | tpcb-like, 16 clients | small random updates, append to history |
| 3 | simple-update, 16 clients | write-dense, no read |
| 4 | select-only, 32 clients | read-only, no journal traffic |
| 5 | tpcb-like, 64 clients | many inodes committing at once |
| 6 | simple-update, 1 client | fsync per commit, tiny transactions |
| 7 | tpcb-like, `full_page_writes=on` | much larger sequential WAL traffic |
| 8 | tpcb-like, frequent checkpoints | in-place writeback and journal recycling under load |
| 9 | 200 × 1.2 MB values | TOAST, large out-of-line writes |
| 10 | 500k row insert | append-only growth |

Afterwards it re-checks the pgbench invariants. Note which one applies:
`simple-update` only touches accounts and history, not tellers and branches, so
after a mixed run the three balance sums are **not** expected to be equal. What
must hold is `accounts == SUM(history.delta)` and `tellers == branches`.

The runs pass `--no-vacuum` deliberately: without it pgbench does
`truncate pgbench_history` at the start of **every** run, so history would only
reflect the last pattern and the invariant check would be meaningless.

### Append: what tau costs

Appending is where tau has the most work to do — the blocks do not exist yet,
so delayed allocation plus commit-time allocation sit on the fsync path.
`append-bench.sh` measures each filesystem three ways so the cost can be
attributed:

```sh
~/tautest/guest/append-bench.sh both
```

* **vanilla** — plain mount, no tjournal
* **tau-mount** — tjournal mount, file *not* activated
* **tau-file** — tjournal mount, opened `O_TAU_UNTORN`

Measured on the passthrough NVMe (two runs, MB/s, higher is better):

| pattern | ext4 vanilla | ext4 tau-file | xfs vanilla | xfs tau-file |
|---------|--------------|---------------|-------------|--------------|
| 4 KB record, fsync each | 23–26 | 21–23 (−11%) | 31–33 | 26–27 (−15%) |
| 16 KB record, fsync each | 66–76 | 70–79 | 105–112 | 92–97 (−13%) |
| 4 KB × 16 per fsync | 248–266 | 238–260 (−3%) | 288–302 | 257–273 (−10%) |
| 1 MB records, no fsync | 1085–1352 | 894–1028 (−20%) | 886–1468 | 871–905 |

Two things to read out of this:

* **tau-mount tracks vanilla.** Mounting with `tjournal` costs nothing on its
  own; the cost appears only for files that are actually journaled.
* **The streaming row is the noisy one.** Vanilla varied by 1.5× between runs
  on the same device, so treat single numbers there with suspicion; tau-file
  was the stable side at 870–1030 MB/s.

The reason is visible directly in the device counters. Writing 512 MB of
appends and unmounting (so the checkpoint completes), read from NVMe SMART
`Data Units Written`:

| | vanilla | tau-file | amplification |
|---|---------|----------|---------------|
| ext4 | 620 MB | 1179 MB | **1.9×** |
| xfs | 511 MB | 1025 MB | **2.0×** |

tau writes every block twice — once into the journal, once in place at
checkpoint — which is the expected price of a data journal. So append-heavy,
throughput-bound workloads pay close to 2× in device bandwidth, while
fsync-latency-bound ones (small records, commit per record) lose only 10–15%,
because there the device round-trip dominates and tau's journal write is
sequential.

### Overwrite: where the hybrid pays off

An append always pays the journal: a new block is a first dirty, and since #344
an append into the anchored block EOF sits in is journaled too rather than
revoked (bug.md #52). A rewrite of
an already-anchored block can go straight to its original location with only a
small revoke tag journaled — that is the point of the undo-redo hybrid, and
`overwrite-bench.sh` measures how much of it materialises. The file is created
and fsynced in a **separate setup step that is not measured**, so the journaled
first write is excluded.

```sh
~/tautest/guest/overwrite-bench.sh both
```

Device write amplification, from NVMe SMART, two runs (vanilla is 1.0× in every
case, so only tau is listed):

| pattern | ext4 | xfs |
|---------|------|-----|
| 512 MB sequential rewrite, one fsync | 2.0× / 2.0× | 2.0× / 2.0× |
| 16 KB random, fsync every write | 3.4× / 1.8× | 1.7× / 1.7× |
| 16 KB random, fsync every 16 | **1.1× / 1.5×** | **1.1× / 1.1×** |

Throughput follows the same shape: −10% to −20% for the batched patterns,
about −45% when every single write is fsynced.

So the hybrid does deliver — the batched random-overwrite case, which is what a
database doing group commit looks like, lands near 1.1× instead of the 2× an
append pays. But it is **pattern dependent, not universal**: a bulk sequential
rewrite still costs 2×, and fsync-per-write costs ~1.7× plus a descriptor and
commit record per fsync.

ext4 looked much less stable than XFS in these numbers (3.4× vs 1.8×, 1.1× vs
1.5× between runs). That turned out to be a measurement artifact, not tau:
`mke2fs` zeroes inode tables in the background, and on a 512 GB device that
`ext4lazyinit` traffic lands inside the measured window. Every script here now
passes `-E lazy_itable_init=0`, after which ext4 repeats as tightly as XFS.

### Same-location rewrite: what a hot block actually costs

`rewrite-same.sh` is the narrow version of the question: rewrite **one region**
over and over, fsyncing each time, and see whether the second and later writes
get cheaper. The region sizes straddle `TAU_SMALL_TX` (512 journal blocks, 2 MB),
the point below which `tau_should_do_checkpoint()` forces a checkpoint.

```sh
~/tautest/guest/rewrite-same.sh both
```

Device bytes per logical byte, tau (vanilla is 1.00× throughout):

| region | blocks | device per write | WAF |
|--------|--------|------------------|-----|
| 4 KB   | 1      | 14 KB   | 3.50× |
| 64 KB  | 16     | 74 KB   | 1.13× |
| 1 MB   | 256    | 1034 KB | 1.01× |
| 4 MB   | 1024   | 4081 KB | 1.00× |

The overhead is a **constant ~10 KB per fsync**, independent of size — so it is
not a rate, it is a fixed per-commit toll that amortises away by 1 MB. Note
where it lands relative to append: an append pays ~2× no matter how large it is,
because the data itself is written twice. A rewrite converges to 1.00×, because
the data is written exactly **once** per fsync.

### Attributing the writes

`write-attrib.sh` answers "which thread issued those bytes, and did they go to
the journal or to the file's own blocks?". It records `block:block_rq_issue`,
buckets each request by the issuing task's comm, and classifies the target
sector against the file's physical extent from `filefrag`.

```sh
~/tautest/guest/write-attrib.sh ext4 tau 4096 20000
```

Pairing that with the ftrace function tracer on `tau_journal_get_write_access`,
`tau_commit_transaction`, `tau_get_descriptor_buffer` and `tau_mark_wbdone`
gives an interleaved timeline, which is what actually explains the 4 KB row.
Two cycle types alternate, and they must:

```
cycle A  re-journal      descriptor + data   8 KB
                         commit record       4 KB     = 12 KB
cycle B  revoke/in-place data, in place      4 KB
                         descriptor + revoke 8 KB
                         commit record       4 KB     = 16 KB
```

Average 14 KB, matching the measurement exactly. The alternation is required by
the untorn-write guarantee: after cycle B has overwritten the block in place,
the journal copy has been revoked, so a second consecutive in-place overwrite
would have no intact copy to fall back on if it tore. Hence
`tau_journal_get_write_access()` re-journals whenever an fsync has intervened
(`tid_gt(recent_fsync_tid, jh->b_tid)`, `transaction.c:508`).

`TAU_SMALL_TX` is **not** what costs the writes here. The in-place write in
cycle B is issued by commit's own `filemap_flush`, and `tau_do_checkpoint` runs
only once at the end — by the time the daemon looks, there is nothing left to
write back.

One avoidable cost does show up: cycle B calls `tau_get_descriptor_buffer()`
twice. The commit loop at `commit.c:579` is a `do {} while (tx->t_buffers)`, so
it allocates and submits a descriptor block on its first iteration even when the
transaction has **no data buffers at all** — a revoke-only commit writes a 4 KB
descriptor holding nothing but a header. That is 4 of the 14 KB.
`alloced_descriptor_blocks` is only ever read by a debug print, so nothing in
the space accounting depends on that block existing.

### Crashing a running database

`db-crash-test.sh` is the end-to-end durability check: it loads a database on a
tau filesystem, leaves a write workload running, cuts the power, and then
verifies the recovered database — two layers of recovery have to be clean, tau
replaying its journal at mount and the database replaying its own WAL/redo at
startup.

```sh
./host/db-crash-test.sh both postgres 20   # ext4-tau + xfs-tau
./host/db-crash-test.sh xfs-tau mysql
```

The verdict is a transactional invariant, not just "it started":

* **PostgreSQL** — every pgbench transaction moves the same delta through
  accounts, tellers and branches, so those three sums must be equal to each
  other and to `SUM(delta)` in `pgbench_history`. If a committed transaction
  were torn by the filesystem, they would diverge.
* **MySQL** — the workload only moves balance between rows, so `SUM(bal)` must
  still be exactly 100 × 1000 after recovery.

Two things worth knowing if you extend the MySQL side:

* `RAND()` in a `WHERE` clause is re-evaluated **per row**, so
  `WHERE id = 1 + FLOOR(RAND()*100)` matches zero or many rows and lets the
  total drift. Draw the ids into session variables first.
* Do not keep the expected value in `/tmp` — it does not survive the reboot,
  and an unreadable expectation silently turns the check into a pass.

### sync(2) and syncfs(2), not just fsync

`sync-test.sh` is the same crash cycle as the matrix, but each file is made
durable by a **different barrier** — one file per barrier, so a single crash
says exactly which ones hold.

```sh
tools/tautest/host/sync-test.sh both
```

This exists because fsync and sync take completely different routes into the
filesystem. `fsync(2)` on a tau file lands in `ext4_tau_sync_file()` /
`xfs_tau_sync_file()`, which commit the tau transaction directly. `sync(2)` and
`syncfs(2)` instead go through `sync_inodes_sb()`, which hands the page-cache
work to a **bdi kworker** — so the tau hook in `ext4_writepages()` cannot fire
(it is restricted to task context on purpose: a writeback kthread must not
drive a tau commit), and XFS has no `->writepages` tau hook at all. Neither
`ext4_sync_fs()` nor `xfs_fs_sync_fs()` knew about tau, so there was no
fallback: sync-acked data was **silently lost**, with zero kernel faults.

The fix hooks `->sync_fs`, which is the one step of the sync path that runs in
the caller's context and covers `sync(2)`, `syncfs(2)`, umount and freeze
alike. Two things are easy to get wrong there:

- The commit control needs `.user = 1`, the same as fsync. That flag is what
  pulls the pending revoke block into the transaction. Without it a file whose
  only outstanding change is an **in-place overwrite** has `reserved == 0` and
  is skipped, so `s_sync2` (fsync, then overwrite, then `sync(2)`) rolls back
  to the fsync'd content while every other file passes.
  `.user = 1` was still not enough when a background commit had already
  taken the running transaction: the user commit found nothing to commit
  and dropped the pending tags. Fixed 2026-09-23 -- see `revoke-test.sh`
  below, case `gap`.
- Test ordering. `sync(2)` and `syncfs(2)` are whole-filesystem barriers, so
  anything written before them is carried along for free. `s_sfr` and `s_none`
  have to be written **last** or they pass for the wrong reason.

`sync_file_range(2)` is reported but not asserted: it writes no metadata and
issues no cache flush, so it is not a durability barrier by definition. It uses
`WB_SYNC_NONE`, which is indistinguishable from background writeback, and it
does not call `->sync_fs` — so a tau file gets nothing from it.

**This was a regression, and the baseline is worth understanding.** Running the
same test on `new_main` (49b49ae9b2f8):

| | fsync | sync(2) | syncfs(2) | overwrite+sync |
|---|---|---|---|---|
| new_main, ext4 | PASS | PASS | PASS | PASS |
| new_main, xfs | PASS | PASS | PASS | FAIL |
| this branch, before the fix | PASS | FAIL | FAIL | FAIL |
| this branch, after the fix | PASS | PASS | PASS | PASS |

The `!PF_KTHREAD` gate is byte-identical on `new_main` (it dates from
2025-09-30) and XFS has never had a `->writepages` tau hook, so the sync path
never reached a tau commit there either. What made it pass is visible in the
recovery log: on `new_main` it is **empty** — nothing was replayed. Blocks were
allocated at write time, so ordinary VM writeback simply wrote the data to its
home location. That is accidental durability, and it is not torn-write
protected; the XFS overwrite column is where it shows through.

Allocating delalloc blocks at commit time removes that safety net — writeback
has no block to write to, so the data goes nowhere at all. After the `->sync_fs`
fix the recovery log carries real replay and revoke records, so sync-acked data
is now journaled rather than merely flushed.

Note that the session-start commit `6889bfa84e1f` is useless as a baseline: the
fsync control fails there too, because its recovery bugs were only fixed
afterwards. Pick a baseline where the control passes.

### Revoke tags: fsync after a background commit, and stale tags

`revoke-test.sh` checks the one promise the undo path makes: an in-place rewrite
of a block whose committed copy is still in the journal (TauRedo -> TauUndo) is
durable once fsync returns. The rewrite records a revoke tag; only a user commit
(fsync, `->sync_fs`) carries it; recovery then skips the old journal copy. Design
and history: `codes/djournalplus-kernel.code/taudocs/revoke.md`, bug entries #12/#13.

```sh
tools/tautest/host/revoke-test.sh both all 1     # ~1 minute per case
```

| case | what happens before the crash | after recovery |
|---|---|---|
| `gap-ctl` | T1 = 4 MiB of 0x41 + fsync; block 0 := 0x42; fsync | block 0 = 0x42, rest 0x41 |
| `gap` | same, but idle past the commit age first, so a background commit takes the running tx before the fsync | same |
| `stale-ctl` | T1 + fsync; block 0 := 0x42; 4 MiB of 0x43 + fsync | all 0x43 |
| `stale` | same, but T1 is checkpointed (age 1 s) between the two writes, so block 0 is dropped, then journaled again under its old pending tag | same |

Each `-ctl` case differs from its bug case in exactly one step and passes on any
kernel; all four pass on a fixed one.

The setup checks itself and reports INCONCLUSIVE instead of PASS when it did not
build the state it claims:

- probe deltas per step (`revoke_taken`, `commits`, `jwrite_revoke`,
  `tx_dropped`) -- the log reads as which kernel path each step took, and needs
  `CONFIG_TAU_PROBE_TORN=y`;
- the home block of block 0 is zeroed with O_DIRECT right after T1 and read back
  the same way, so a value in the log was written during this run (mkfs leaves
  the previous case's data in the same physical block). Zeroing it is harmless:
  block 0 is TauRedo at that point, so its home copy is stale anyway;
- up to three attempts from mkfs when a precondition fails. On #254 tau_journald
  checkpointed T1 right after its commit in 2 of 8 setups (bug #16); on #255 and
  later, 0 of 8.

Results, both filesystems alike:

| kernel | gap-ctl | gap | stale-ctl | stale |
|---|---|---|---|---|
| #254 (before) | PASS | **FAIL** (block 0 = 0x41, fsync committed nothing) | PASS | **FAIL** (block 0 = 0x42; recovery "revoked 2") |
| #255 (fsync without a running tx fixed) | PASS | PASS | PASS | **FAIL** (expected) |
| #256 (scoped tags) | PASS | PASS | PASS | PASS |

Not covered: a write racing a commit before pass 1 allocates the block (bug
#14a) -- `revoke_pblk_fixup` stayed 0 even through `stress-test.sh both 60 6 5`.

### Segment release order: a drained transaction ahead of an older one

`seg-order-test.sh` (XFS, `tjsegsize=4m`) leaves T1 on the checkpoint list,
writes T2 across several segments, empties T2 through a re-journal handoff into
an fsync'd T3, forces a segment-map flush, and cuts power. Recovery must replay
through T3.

```sh
tools/tautest/host/seg-order-test.sh xfs
```

| kernel | recovery | 8-20 MiB after recovery |
|---|---|---|
| #267 (before) | stops at tid 0: `no more segment for transaction 1` | **0x33** -- the fsync'd 0x44 lost, rolled back |
| #268 (fix, bug.md #17) | tid 0-3 | 0x44 |

ext4 is not covered: its mkfs has no small-segment option wired into the
harness, and at 128 MiB a transaction would need hundreds of MB to own a
middle segment.

### Stale transactions in a segment the file got back

`seg-reuse-test.sh` (XFS, `tjsegsize=4m`) relies on segments being handed out
lowest entry first. The file's small txs fill the start of E0, two large ones
run E0->E1->E2, all of it is checkpointed and E0/E1 are freed; the file's next
fsync'd tx spills from E2 into the start of E0 without a descriptor, and
another file takes E1. E0 now starts with live spill-over followed by the old
small txs, whose chain leads into a segment no longer the file's -- the layout
of the 2026-09-25 crash-test failure. Recovery must replay only the newest tx.

```sh
tools/tautest/host/seg-reuse-test.sh xfs
```

| kernel | recovery | result |
|---|---|---|
| #284 (fix, bug.md #25) | stale start found (`first transaction 10`), chain breaks at 50; replays tid 53 only (its tail) | PASS |

The old scan starts at the lowest first descriptor (tid 10) and stops at 50,
so it writes old 0xaa over the checkpointed 0xcc and never reaches tid 53.
Not run on a pre-fix kernel.

### The newest transaction straddled a segment and was checkpointed

`seg-straddle-test.sh` (4 MiB segments: XFS `-l tjsegsize=4m`, ext4
`-E tau_segsize=4m` through `TAU_MKE2FS_OPTS`): a file rewritten by `taurace`
cycles its journal between two segments, so the one it gets back still holds
its own older transactions. Rounds of a 1 s race, each followed by one
`taurace <file> <size> settle`, until that settle commit enters a new segment
(`tau_probe_seg_published` rises); five seconds for it to be checkpointed,
which frees its first segment, then another file's commit rewrites the disk
map, and power is cut. The file's second segment is left as [the settle's tail
and commit][older transactions of the same file], and recovery must replay
none of them: the file stays all 0x2a. RESULT is INCONCLUSIVE when recovery
reports no orphan commit -- the settle started a segment rather than
straddling into one, and nothing was at stake.

```sh
tools/tautest/host/seg-straddle-test.sh xfs     # or ext4
```

| kernel | recovery | result |
|---|---|---|
| #298 (fix, bug.md #27) | `orphan commit 7925 ... checkpointed through tid 7925, nothing to replay` | PASS, all 0x2a |
| #299, the floor switched off (control) | stale start `first transaction 1633`, replays 1636-1638 | FAIL, 97 blocks of 0xa0 |
| #300 ext4 (2 runs) | `first transaction 12400` behind `orphan commit 12413`, nothing replayed | PASS, all 0x2a |

### One write split between journal and in place

`split-test.sh` (bug.md #21): a write whose blocks would not all take the same
path -- one has to be journaled (clean, or new), another would go in place
(TauRedo, or TauUndo with its tag pending) -- then no fsync, a background
commit (which takes the journaled blocks but not the revoke tags), a plain
file's fsync to force the host FS's log, and a power cut. The write must come
back whole or not at all. Blocks come out of their first commit TauUndo when
they were allocated by it, and a tx under `TAU_SMALL_TX` is checkpointed at
once, so the setup allocates the page, lets the checkpoint drop it, and
carries 4 MiB of filler in every tx that has to stay.

| case | before the write | the write | whole or nothing |
|---|---|---|---|
| `split` | block 0 clean, block 1 TauRedo | 8 KiB 0x43 | 0x40 0x42, or 0x43 0x43 |
| `extend` | blocks 0-1 TauRedo, block 2 a hole | 12 KiB 0x44 | 0x41 0x41 hole, or 0x44 x3 |
| `split-ctl` | as `split` | 8 KiB 0x43 + fsync | 0x43 0x43 |
| `inplace` | blocks 0-1 TauRedo | 8 KiB 0x43 (all in place) | 0x41 0x41, or 0x43 0x43 |

```sh
tools/tautest/host/split-test.sh both        # ~2 minutes per case
```

| kernel | `split` | `extend` | controls |
|---|---|---|---|
| #303 (before) | FAIL 0x43 0x42, both filesystems | FAIL 0x41 0x41 0x44, both (0x41 0x41 hole without the log force: XFS publishes the new block after the record, ext4 commits its allocation within 5 s) | PASS |
| #304 (atoz) | PASS 0x43 0x43, `atoz_mixed+1` | PASS 0x44 x3 | PASS |

### Blocks a tau file freed and another file reused

`trunc-reuse-test.sh` (bug.md #20; `TAU_FS_SIZE`, default 8g): A, a tau file,
writes 128 MiB of 0xA1 in 4 MiB writes and fsyncs -- txs over `TAU_SMALL_TX`,
so they stay in the journal. The journal margins are then set to 0, so the
journal does not hand segments back once the filesystem is full; a fallocate'd
filler leaves 16 MiB free; A frees blocks (`trunc`: truncate to 0, `punch`: a
64 MiB hole at 32 MiB, `collapse`: the same 64 MiB collapsed away) and the host
log is forced (XFS keeps freed extents busy until its log commits, and
allocates around them). B, a plain file, then writes 0xBB until ENOSPC and
fsyncs: A's freed blocks are nearly all the free space, more than the host FS
keeps in reserve, so B lands on them. The filesystem stays full through the
power cut, so the next mount also checks that the journal can be backed again
(bug.md #37). After recovery B must read all 0xBB; a 0xA1 block is A's journal
copy replayed over B. INCONCLUSIVE when B landed on none of A's blocks.

`keep` checks the home write that comes before the revoke: A's blocks are
TauRedo over a home one version older (0xA1 journaled over 0xA0), A is
truncated to 4 MiB and power is cut at once, before the host's truncate is
durable (ext4 mounted `commit=60`; XFS waits for a log force). A must come back
at 8 MiB of 0xA1 -- the tail's journal copies are revoked, so it is the home
write that brings it back. 4 MiB is INCONCLUSIVE: the truncate became durable.

```sh
tools/tautest/host/trunc-reuse-test.sh both     # ~2 minutes per case
```

| kernel | ext4 trunc | ext4 punch | XFS trunc | XFS punch | keep (both) |
|---|---|---|---|---|---|
| #305 (before #20) | FAIL, 32768 blocks 0xA1 | FAIL, 16384 | FAIL, 32768 | FAIL, 16383 | -- |
| #307 (`tau_revoke_range()`) | PASS, `revoked 32768` | PASS, `replayed 16384, revoked 16384` | PASS | PASS | PASS, 1024 blocks written home, `revoked 1024` |

Those runs removed the filler before the power cut. From #309 it stays, which
also checks #37:

| kernel | ext4 collapse | XFS collapse | XFS trunc |
|---|---|---|---|
| #307 | FAIL, 16384 blocks 0xA1 | mount ENOSPC (#37) | mount ENOSPC (#37) |
| #309 | PASS, `replayed 16384, revoked 16384` | PASS | PASS (all eight cases pass) |

### Range operations: collapse, insert, zero, unaligned punch and truncate

`range-test.sh` (bug.md #36, #38, #39, #26, #20): one tau file, five 4 MiB
regions. R0-R3 are TauRedo -- 0x20-0x23 journaled over a home of 0x10-0x13
that the checkpoint wrote and dropped -- and R4 (0x24) is in the running tx.
Then one operation, a check of the contents right away (no crash needed for
most of what this finds), an fsync and a host log force, a power cut, and the
same check after recovery.

| case | operation | expected |
|---|---|---|
| `collapse` | `fallocate -c` R1 | R0 R2 R3 R4 |
| `insert` | `fallocate -i` 4 MiB at R1 | R0, 4 MiB of zeros, R1-R4 |
| `zero` | `fallocate -z` R1 | R0, zeros, R2-R4 |
| `upunch` | punch 10192 bytes at R1 + 1000 (both edges partial) | the punched bytes zero, the rest of both edge blocks kept |
| `uzero` | `fallocate -z`, the same range | as `upunch` |
| `utrunc` | truncate to R1 + 5000, then extend to 8 MiB | R0, 5000 bytes of R1, zeros |
| `extend` | `fallocate` to 1 GiB, on a 1 GB journal (`tjournal_size=1`) | R0-R4, zeros |

```sh
tools/tautest/host/range-test.sh both        # ~1.5 minutes per case
```

| kernel | XFS | ext4 |
|---|---|---|
| #307 (before) | `collapse`, `insert` FAIL at runtime: the shifted TauRedo regions read their stale homes (0x12, 0x13), R4 reads zeros, and the block before the shift point reads 0x10 (`xfs_prepare_shift()` drops it too); `upunch` FAIL at runtime, the kept parts of both edge blocks read 0x11; `utrunc` kernel BUG `transaction.c:532` (#38); `extend` FAIL `Invalid argument` (#26); `zero` PASS | `collapse`, `insert` FAIL at runtime as on XFS; `upunch`, `utrunc` FAIL after the power cut, the zeroed part of the edge block reads 0x21 again (#39); `zero`, `extend` PASS |
| #309 | all PASS | `upunch`, `utrunc` still FAIL after the power cut (the edge tag alone: nothing wrote the zeroing home); the rest PASS |
| #310 (ext4 edge zeroing written home) | all PASS, `uzero` too | all PASS, `uzero` too |

`extend` needs the small journal: with the default one (a tenth of the device)
a transaction may hold the whole 1 GiB of zeroing and #307 passes it too.
`uzero` was added with #310; #311 (a block a tx holds keeps its zeroing in the
tx) passes `upunch`, `uzero` and `utrunc` on ext4 again.

### A short copy into a block the page cache had not read

`shortcopy-test.sh` (bug.md #24): a 64 KiB file of 0xC3 written without tau
and dropped from the page cache, then `taushort` opens it `O_TAU_UNTORN` and
writes one block from a buffer whose next page is `PROT_NONE`: the copy stops
after 100 bytes, the kernel reports a short copy (ext4 logs `partial write`),
and the write is retried for the 100 bytes that were copied. The block must
read 100 bytes of 0x5A and then 0xC3, at once and after a power cut.

```sh
tools/tautest/host/shortcopy-test.sh both
```

| kernel | XFS | ext4 |
|---|---|---|
| #307 (before) | PASS (the retry reads the block: iomap asks its own per-block uptodate bit, which the short copy did not set) | FAIL at runtime: the 3996 bytes after the copy read zero instead of 0xC3 |
| #309 | PASS | PASS |

### Multi-segment transactions: the segment chain on disk

A transaction that outgrows one 128 MB journal segment used to be unreplayable.
`sync-race-test.sh` at 256 MB shows it plainly — before the fix, **every** round
logged:

```
TAU: failed to find valid descriptor block in segment at pba 35
TAU: no more segment for transaction 0
TAU: no valid transaction found for ino 133
```

Recovery replayed nothing in 16 of 16 rounds. Rounds still passed about
two-thirds of the time, but only because the checkpoint happened to finish the
in-place writeback before the power cut — durability was down to timing, not to
the journal. That is why the pass/fail rate looked like a flaky XFS bug and why
fsync and sync failed at identical rates.

Two things were wrong, both about the *order* of a transaction's segments:

- A segment was only recognised as belonging to a transaction if it contained a
  **descriptor block** for that inode. A descriptor covers 406 blocks and a
  segment holds 32768, so the tail of a big transaction — a few hundred data
  blocks plus the commit record — carries no descriptor at all. That segment was
  dropped from the chain and the walk ran off the end.
- Segments were ordered by `first_transaction`, the tid of their first
  descriptor. Every segment of a *single* multi-segment transaction carries the
  same tid, so the order was undefined. It was not pba order either: the
  allocator takes the lowest free seg-map slot while `tau_reserve_log_space()`
  pushes reservations onto the front of the list, so the real chain here ran
  32803 → 65571 → 35.

The chain was a runtime linked list that nothing recorded on disk. It now is:
every block that carries a header stores `h_next_segment` — the segment
following the one that block sits in — at the same offset in the descriptor,
revoke and commit headers. Recovery follows that instead of sorting. Data blocks
have no header, which is exactly why the link is read from the descriptor being
consumed rather than from the block being stepped over; the commit block needs
one too, because the step to the *next* transaction can cross a boundary as
well. Segments with no descriptor are kept but never chosen as a scan start.

**This is an on-disk format change** (`TAU_REVOKE_TAGS_PER_BLOCK` drops 255 →
254, `h_epoch` moves to offset 32). An existing journal must be recreated with
mkfs; the test harness does that every round anyway.

After the fix the same 256 MB case logs `replay done ... replayed 65536 blocks`
and passes 6/6.

### O_DIRECT on a tjournal mount

`odirect-test.sh` (bug.md #40): on a tjournal mount a file tau does not journal
gets real direct I/O; a tau file's direct I/O is done buffered, through tau (a
TauRedo block's newest copy is in the page cache and the journal, not at home);
and `O_TAU_UNTORN | O_DIRECT` at open is refused. The test checks each: a
`dd oflag=direct` to a plain file, the refused open, then on a tau file a direct
read after a tau write, a direct write (it must produce a tau commit), a direct
read of that, and the same data after a power cut.

The same test checks mmap (bug.md #42): a tau file's shared mapping is never
writable -- `PROT_WRITE | MAP_SHARED` is refused, a read-only shared mapping
cannot be `mprotect()`ed writable, a private writable mapping works and leaves
the file alone -- and a file mapped writable elsewhere cannot be made tau
(`O_TAU_UNTORN` gets `EBUSY` until it is unmapped). All eight pass on #324.

```sh
tools/tautest/host/odirect-test.sh both
```

| kernel | XFS | ext4 |
|---|---|---|
| #313 (HEAD acc3da59) | FAIL: the plain file's `O_DIRECT` write refused (`xfs_file_open()` cleared `FMODE_CAN_ODIRECT` for the whole mount) | PASS |
| #314 | PASS | PASS |

Until #314, InnoDB's startup probe failed on XFS-tau, so MySQL there ran
`innodb_flush_method=fsync` while ext4-tau ran `O_DIRECT`.

### Journal segments a crash left mapped past a hole

`seg-adopt-test.sh` (bug.md #37, XFS only -- the journal file is reachable
from a mount without `-o tjournal` there): mkfs a 16 GiB XFS, mount with
tjournal (it backs as many 128 MiB segments as the FS margin allows), force the
log, power cut. Then, on a plain mount, punch out segment 8 of `tjournal_dummy`
and fill the FS to ~1 GiB free, and mount with tjournal again. The mount's grow
takes the first eight segments without the margin check and stops at the hole;
everything past it must still come back to the filesystem while mounted. PASS
when free space 5 s into the tjournal mount is more than 1 GiB above what it
was before. (A clean unmount truncates the journal file on both filesystems, so
the loss is only ever for the length of a mount.)

```sh
tools/tautest/host/seg-adopt-test.sh xfs
```

| kernel | free before the tjournal mount | 5 s into it |
|---|---|---|
| #313 (HEAD acc3da59) | 1025 MiB | 1025 MiB -- 82 segments (10 GiB) dead: FAIL |
| #314 | 1025 MiB | 4097 MiB (`took 82 journal segments`; journald gives back down to the 4 GiB margin): PASS |

### A journal abort: fail-stop and recovery

`abort-test.sh [xfs|ext4|both] [sites]` (bug.md #22, #7; design `taudocs/plan.md`
§7). Needs `CONFIG_TAU_PROBE_TORN`: `tau_inject_fault=<site>` makes the next pass
through that point of the commit fail once.

| site | where |
|---|---|
| 1 | the write loop, with journal copies built but not submitted |
| 2 | a submitted journal write comes back failed |
| 3 | the commit record is not written |
| 4 | publishing the segment map fails |
| 5 | pass 2, after the record (allocating commits only) |
| 6 | right after pass 1 of an allocating commit |

`tauabort` runs four writers (8 KiB stamped pages, appends and overwrites, an
fsync every four writes) and acks a page at the generation an fsync covered.
Three seconds in, the fault is armed. Pass: every writer stops on `EIO` within
30 s of the abort (no D state), a new `O_TAU_UNTORN` file is refused, a plain
file on the same filesystem is still writable -- except ext4 when the abort
caught an allocation in flight, where ext4 stops its own journal and goes
read-only by design -- umount completes, and after mounting again every page is
whole and at least as new as its last acked generation.

```sh
tools/tautest/host/abort-test.sh both        # ~1 minute per site
```

| kernel | XFS 1-6 | ext4 1-6 |
|---|---|---|
| #315 | site 1: oops in `xfs_vm_writepages()` during umount (sync after the journal was torn down) | -- |
| #316 | all PASS | all PASS (site 6: host read-only, as designed) |

Recovery on a real machine after an abort: read dmesg, fix the device if that
was the cause, `umount`, `mount` (tau replays), restart the database. No reboot,
fsck or mkfs.

### An unlinked file is let go without an unmount

`unlink-test.sh [xfs|ext4|both] [live|crash|all]` (bug.md #24). tau used to hold
every tau file's inode until unmount, so an unlinked one kept its blocks and its
`tau_t`; now tau_journald lets go of a file once it is unlinked and nothing else
holds it. Needs `CONFIG_TAU_PROBE_TORN`: `tau_alloced - tau_freed` is the number
of files tau still holds.

- `live`: a 256 MiB file (64 MiB rewritten) unlinked -- held count back and
  the space back within 30 s; a file unlinked while open and written on -- held
  until the close, reads back its latest data; 200 files, half truncated to 0
  first as PostgreSQL drops a relation; a hard link keeps the file, a rename over
  the last name lets it go. `dead_retry` must stay 0, then a clean umount and
  mount.
- `crash`: A 128 MiB (32 MiB rewritten) on a nearly full 8 GiB filesystem,
  unlinked and let go; B fills the space until ENOSPC and must reuse A's blocks
  (INCONCLUSIVE otherwise); power cut. After recovery B must be all 0xBB -- none
  of A's journal copies replayed over it -- and A must not come back.

| kernel | XFS | ext4 |
|---|---|---|
| #318 | live FAIL: the `tau_t` was freed only when background reclaim freed the `xfs_inode`, so the held count lagged by tens of seconds -- and an `xfs_inode` recycled before that kept the stale `i_tau` | -- |
| #319 | live PASS (every file let go within 1 s, 203 released, 0 put back); crash PASS (B reused all 32768 of A's blocks, all 69680 blocks 0xBB after the power cut) | live PASS (same); crash PASS (32768 reused, all 141931 blocks 0xBB) |

### A block that misses the transaction at write_end

`writeend-test.sh [xfs|ext4|both]` (bug.md #41). Needs `CONFIG_TAU_PROBE_TORN`:
`tau_inject_fault=7` makes the next `dirty_block()` take the block out of the
running tx and fail, as if it had left the tx inside the write window. Two
faulted 64 KiB writes into an 8 MiB file -- an overwrite (in place with a revoke
tag) and an append (journaled) -- each fsync'd, then a power cut. Before the fix
the write reported success and that block was in no transaction, so recovery
brought back the old data; now write_end redoes the folio (`wr_end_redo`) and
both writes must come back whole.

| kernel | XFS | ext4 |
|---|---|---|
| #322 (control: redo taken out, `WEND_CONTROL=1`) | FAIL: 2 blocks old after the power cut, one per faulted write | FAIL: the same 2 blocks |
| #321, #323 | PASS: 2 folios redone, both writes whole | PASS (same) |

### Timestamps: lazytime, fsync at datasync level

`mtime-test.sh [xfs|ext4|both] [live|crash|all]` (bug.md #24). A tau file's
timestamps change in memory and reach the disk with the inode's next write;
its fsync forces size and blocks but not the timestamps.

- `live`: a write moves mtime; a clean umount keeps it; 200 rewrites with an
  fsync each cost fewer than 50 host journal commits (ext4, `/proc/fs/jbd2`) or
  log forces (XFS, `stats`) -- one per fsync would mean the timestamps are
  being forced again.
- `crash`: S rewritten, fsync'd and `syncfs`'d; F rewritten and fsync'd only;
  power cut. Both files' data must be whole, S's mtime the synced one, F's
  mtime either the old or the new one -- never anything else.

| kernel | XFS | ext4 |
|---|---|---|
| #321, #323 | live PASS: mtime moved, kept across umount, 0 log forces for 200 fsyncs; crash PASS: S kept by the sync, F the old mtime | live PASS: 1 jbd2 commit for 200 fsyncs; crash PASS (same) |

Before #321 an ext4 tau file's mtime never moved, and every XFS tau fsync after
a write forced the log for the timestamp.

### An allocating commit and the host journal

`epoch-test.sh [xfs|ext4|both] [convert|split|gate|all, or a comma list] [rounds]`
(bug.md #49, #50, #51). Needs `CONFIG_TAU_PROBE_TORN`: `tau_inject_delay` makes
the next allocating commit sleep once at a site -- between two pass-1 runs,
after pass 1, after the record -- so another file's fsync can force the host
log inside the commit and the power cut lands there. Free space is salted with
0xEE first (a 4 GB filesystem filled to ENOSPC and emptied), so a block made
visible without its data shows the salt; ext4 mounts with `commit=600` so no
timed jbd2 commit closes the window.

- `convert`: write into a fallocate'd extent; cut after pass 1, the host log
  forced. Must read zero or the new data, never the salt (#50).
- `split`: two delalloc runs in one commit; host log forced between them, cut
  after the record. Whole or nothing, no salt (#49).
- `gate`: blocks 0-1 fsync'd, one write over block 1 and new blocks 2-3; cut
  after the record, before the host has the allocation. Recovery must refuse
  the commit (#51).
- `publish`: `gate` with another file's fsync after the record, so the
  allocation is durable and the conversion is not. On XFS that was #44 (block
  1 new, blocks 2-3 lost); recovery now rolls the tx back. On ext4 the one
  jbd2 transaction makes it whole.
- `partial` (XFS only, not in `all`): holes at blocks 4 and 8 of a 64 KiB
  file, one tx writing blocks 3-4 and 8, the cut between the two conversions of
  pass 2 after another file's fsync made the first durable. The tx must be
  rolled back and the block converted without its data zeroed (no salt).

`NOROLLBACK=1` switches the rollback off for the recovery mount
(`tau_inject_fault=8`), to see what the cases look like without it.

Size-only cases (bug.md #45, #46; part of `all`). Each starts from 100 bytes
fsync'd and a clean remount, so the next write to the block is journaled
rather than written in place (in place, the host's own writeback logs the size
and hides the bug):
- `append`: 100 B appended + fsync, power cut: size 200.
- `append-umount`: the same, then a clean umount + mount before the cut.
- `append-torn`: 50 B at offset 80 (20 overwritten, 30 appended), no fsync,
  cut after the record: all old or all new.
- `isize`: the append's commit held after its record while a second append
  grows the block to 300 in memory; the first commit finishes, power cut:
  size 200 (the commit's size, not the live one).

| kernel | XFS | ext4 |
|---|---|---|
| #342 | `append`, `append-umount` FAIL: size 100 | PASS |
| #343 | all four PASS (`append-torn`: rolled back by size; with `NOROLLBACK=1` A*80 C*20) | all four PASS (`append-torn`: the gate refused the tx) |

Appends into a TauRedo block (bug.md #52; part of `all`). F is 4 KiB of A and
100 B of B, a clean remount, then 10 B of b over block 1 + fsync with
`tau_cp_small_tx` 0, so block 1 (EOF inside it) stays TauRedo -- by default a
one-block tx is checkpointed at once and the block is clean again:
- `undo-bg`: 100 B appended in block 1, block 0 overwritten, no fsync; the
  background commit (it takes no revoke tags) runs, then the cut.
- `undo-wb`: 100 B appended in block 1, block 1 written back by plain
  writeback (`sync_file_range` WRITE), another file's fsync, cut.
- `undo-sparse`: 10 B rewritten in block 1, block 3 written past EOF (it must
  not commit: `tau_max_commmit_age` 600), block 1 written back, another file's
  fsync, cut.

The append must come back whole or not at all; `undo-sparse` must keep the
old size.

| kernel | XFS | ext4 |
|---|---|---|
| #343 | all three FAIL: size 4296 / 4296 / 8192, the tail zeros | `undo-bg` FAIL (size 4296, zeros); the other two PASS |
| #344 | all three PASS (`undo-bg` whole, size 4296; the others old, 4196) | all three PASS |

### A database over a rolled-back commit

`db-rollback-test.sh [postgres|mysql|both] [rounds] [scale]` (XFS-tau only;
bug.md #44). A live database with a growing table -- pgbench (its history
table), or MySQL transfers that also insert into a `hist` table -- then
`tau_inject_delay` holds the next allocating commit right after its record,
another file's fsync makes the allocation durable, and the power is cut. After
the reboot tau recovery must report a rollback ("rolled back"; none is
INCONCLUSIVE) and the database must recover over it: pgbench's four sums equal;
MySQL `SUM(bal)` = 100000 and every account's balance equal to what its `hist`
rows say.

| kernel | PostgreSQL | MySQL |
|---|---|---|
| #342 | 3/3 PASS, rolled back 1606 / 4 / 1560 new blocks, WAL redo ~480 MB | 3/3 PASS, rolled back 256 new blocks each, 22-27 K hist rows consistent |

| kernel | XFS | ext4 |
|---|---|---|
| #334 (delay sites only) | convert PASS (00,00), split PASS (-,-) | convert FAIL: 8192 salt bytes; split FAIL: block 0 new, block 16's allocation lost; gate FAIL: 30,44,-,- |
| #335, #336 | convert, split, gate PASS (gate: "epoch not durable", whole tx refused) | convert PASS (00,00), split PASS (41,42), gate PASS (30,30,-,-) |
| #339 `publish` | FAIL: 30,44,-,- (#44) | PASS: 30,44,44,44 |
| #341, rollback off | `publish` FAIL 30,44,-,-; `partial` FAIL 45,45,00 | -- |
| #341 | `all` PASS (`publish` 30,30,-,-: rolled back); `partial` PASS 30,00,00, 1 block zeroed | `all` PASS |

### Flush order: what a device write cache can lose

A qemu kill does not cut the device's power, so the device never loses its
write cache and every crash test here passes with a missing flush.
`flushorder-test.sh [xfs|ext4|both] [cases] [fsyncs]` (taudocs/design.md §21)
runs a workload on loop devices in the guest's `/dev/shm` through
dm-log-writes, which logs a plain write only once a later flush makes it
durable and a FUA write when it completes. The log is then replayed entry by
entry, and at every flush, FUA and mark the disk is copied, mounted (tau
recovery) and the file checked: every write whole, in order, and every write
an fsync returned for present (a mark follows each fsync). Cases: `append`
(allocating commits), `falloc` (conversions), `subappend` (size-only commits),
`overwrite` (no host log force). The control (`RECORD_FUA_ONLY=1`, kernel knob
`tau_record_fua_only`) sends every record FUA without PREFLUSH -- durable
before its data -- and `overwrite` must FAIL. Needs `drivers/md/dm-log-writes.ko`
from the kernel tree (`make drivers/md/dm-log-writes.ko`); the host script
copies it in.

| kernel | XFS | ext4 |
|---|---|---|
| #345, 24 fsyncs | all four PASS, 301 crash states; 23/23/24/0 records without a flush | all four PASS, 298 states |
| #345, control | FAIL 45 of 51 states | FAIL 47 of 49 |

### One fsync, request by request

`guest/fsync-anatomy.sh <ext4|xfs> <vanilla|tau> <overwrite|append> [fsyncs] [pages]`
traces every block request between `sys_enter_fsync` and `sys_exit_fsync`:
requests, bytes, serial phases (a request issued with none outstanding: the
fsync waited before it could send it), cache flushes and FUA writes; `DUMP=n`
prints the first n fsyncs request by request. 8 KiB page per fsync, #344/#345:

| | PM1733 vanilla | PM1733 tau | 980 PRO vanilla | 980 PRO tau #344 | 980 PRO tau #345 |
|---|---|---|---|---|---|
| ext4 overwrite | 25 us, 1 phase | 57 us, 2 phases | 5.40 ms, 1 flush | 5.28 ms, 1 flush | 5.26 ms |
| ext4 append | 135 us, 3 phases | 147 us, 4 phases | 5.57 ms, 1 flush | 10.8 ms, 2 flushes | 5.56 ms, 1 flush |
| XFS overwrite | 26 us, 1 phase | 58 us, 2 phases | 5.42 ms | 5.26 ms | 5.27 ms |
| XFS append | 101 us, 2 phases | 170 us, 3 phases | 5.45 ms | 10.5 ms, 2 flushes | 5.52 ms, 1 flush |

The PM1733 has no volatile cache (`nvme id-ctrl` vwc 0): the block layer drops
FLUSH/FUA, and what a tau fsync pays there is one more serial phase -- the
commit record after its data. The 980 PRO (`3c:00.0`, write back, a flush
about 5 ms) pays per flush, and #345 made an allocating commit's record ride on
the host log commit's flush.

### Open bug: the XFS commit ordering bracket deadlocks

`guest/xfs-hold-probe.sh` wedges the whole filesystem in about 25 seconds on the
current tree, at stock mount options. Run it before anything else in this area:

```sh
./guest/xfs-hold-probe.sh 30 8 3 6 64m 8    # secs racers bigwriters churners log logbufs
```

tau's publish pass opens an ordering bracket that pins the CIL commit iclogs
(`xlog_cil_tau_hold_begin`), then asks for a commit LSN
(`xlog_cil_tau_hold_lsn` → `xlog_cil_force_seq` → `xlog_cil_push_now(async=false)`
→ `flush_workqueue`). The CIL push it waits for needs iclog space, and the pins —
which only drop at `hold_end`, after `hold_lsn` returns — deny it. Nothing else
has to be running for this to close.

The wedge takes down `xfsaild`, the CIL workers, the tau checkpoint thread and
every fsync caller, all in uninterruptible sleep. **SIGKILL does nothing**, so:

* don't wrap the workload in `timeout` and don't `wait` for it — poll for
  completion markers with your own deadline, or the script hangs alongside the
  workload and you get no diagnosis;
* dump `/proc/<pid>/stack` for every `D` task *while it is wedged* — that is what
  shows the cycle. `sysrq-w` output can be pushed out of the dmesg ring;
* the only way out is killing qemu.

Three things that are **not** the trigger, each checked: a small log (mkfs refuses
under 64MB on this device anyway), `logbufs=2` (the default 8 wedges too), and the
log running out of grant space (the probe never even reached a
`xlog_grant_head_wait`). What does trigger it is CIL pressure — the metadata
churners are what turned a workload that previously passed into one that wedges
on the first try.

## Reading a failure

* **Content mismatch in `matrix-verify.sh`** — a durability bug. Compare the
  reported digest against the patterns above to see which generation survived;
  a byte histogram (`od -An -tu1 file | tr ' ' '\n' | sort | uniq -c`) tells you
  whether the file rolled back wholesale or is torn between generations.
* **`kernel BUG` / assert** — the console log (`/tmp/tau-vm-console.log` on the
  host by default) has the stack. It survives a wedged guest, unlike ssh.
* **A racer that "hangs"** — usually the aftermath of an assert, not a deadlock:
  a thread dying inside a commit leaves transaction state behind, and everything
  else then blocks on it. Look for a `kernel BUG` earlier in the console log
  before assuming a lock cycle.
* **`soft lockup` on idle CPUs, all at one instant** — the whole VM stopped, not
  the guest kernel: every report is `swapper` in `pv_native_safe_halt` or a task
  in user mode, all "stuck for 21s", next to `clocksource: Long readout
  interval` with `cs_nsec` ≈ `wd_nsec` ≈ the stall, and the host's ssh timed out
  meanwhile. An idle vCPU cannot lock up while the VM runs. **Cause: the host's
  NUMA balancing** (this host is two-socket, kernel 6.8). Caught on 2026-10-01
  with a host-side trace (bpftrace, `task_numa_work`, `mmu_notifier`
  invalidation windows, KVM faults per second): for exactly the 23 s the guest
  lost, qemu's threads held mmu-notifier invalidations of 60-700 ms back to back
  (10-32 a second), a NUMA scan took 1.5 s, and the vCPUs retried 0.5-3.3
  million page faults a second; before and after, neither. KSM took no part.
  torn-xfs, host as it was: 1 freeze in 36 runs (3 in the ~30 soak runs
  before); with `kernel.numa_balancing=0`: 0 in 36. **Fix, in the harness**:
  `host/vm.sh` now boots with `VM_NUMA=1` -- guest RAM bound to the host's two
  nodes (`run_vm.sh`), which NUMA balancing does not scan: a torn-xfs run then
  shows no scan over 20 ms and no invalidation over 50 ms. The host's own
  setting is untouched (the bare-metal benchmarks run on it). Upstream KVM
  changed the fault retry after 6.8 ("Retry fault before acquiring mmu_lock if
  mapping is changing"). Only a freeze over 20 s trips the soft lockup
  detector, so shorter ones went unseen.
* Useful guest state while wedged:
  ```sh
  ps -eo pid,stat,comm | awk '$2 ~ /D/'      # blocked tasks
  sudo cat /proc/<pid>/stack                 # where each one is stuck
  echo w | sudo tee /proc/sysrq-trigger      # dump all blocked tasks
  ```

## Debugging technique that worked

When an assert fires rarely, converting it into a state dump is far more
effective than reasoning about the code:

1. Replace the assert with a `pr_warn` that prints every relevant buffer/journal
   flag, then let the workload continue (set the missing state if needed).
2. Run the stress test until it prints. The flag combination usually identifies
   the invariant that broke.
3. Add a `WARN_ON_ONCE` at each suspected origin to confirm which path produces
   that state — this typically fires within seconds, even when the original
   assert took half an hour.

That sequence is how the `J_ASSERT_BH(buffer_taudirty)` failure in
`write_buffer()` was traced back to `tau_write_end_fn()` skipping
`dirty_block()` for buffers that had already been filed into a transaction.

### Truncate and punch hole racing a commit

`trunc-race-test.sh [ext4|xfs|both] [seconds]`: on one tau file, two writers
(`tauwrite`, 16 KiB at random offsets, fsync), a punch-hole/truncate loop and an
fsync loop, for 60 s per filesystem. Passes if the kernel logged no BUG, no
filesystem shutdown or journal abort, and no WARNING other than the expected
`taufreed` one. No test covered this before; the first run found bugs #28-#30.

| kernel | ext4 | XFS |
|---|---|---|
| S1+S2 (pre-S3) | -- | kernel BUG `commit.c:770` in 16 s (#28) |
| #290 (S3) | PASS | kernel BUG `commit.c:93` (#28) |
| #291 | PASS | NULL deref in forget (#29), journald stuck |
| #292 | PASS | XFS in-memory corruption, shutdown (#30) |
| #293 | PASS | PASS |

