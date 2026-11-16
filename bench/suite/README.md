# bench/suite: the fast test, libra09 performance half

The user's decisions of 2026-11-16 (relayed by tau-ops):
- every τ performance number measured so far is **version beta**: kernel #1982 = τ `new_main` 81f4707b;
- τ `new_main` cc3d37bc (τ code 157b5750) is **v1.0**;
- every τ kernel change gets a **fast test** (target 6 h; libra08's correctness half runs in parallel in VMs);
  the paper's numbers come from the **full test**.

`fast_perf.sh` is the libra09 performance half. It runs on the τ kernel under test, on the PM1735 (the 990 PRO 4TB
is for the full test only), and only calls the existing tools (`sysbench/run_main.sh`, `benchbase/run_tpcc.sh`,
`micro/run_fio.sh` as phase A's v2, `sysbench/parse_main.py`) plus fio on the raw test device. Their default paths
are unchanged. It does not measure baselines: τ÷App and τ÷Raw use beta's (`baselines_libra09.csv`), and FP0 guards
that premise.

Files: `fast_perf.sh` (driver), `fast_report.py` (metrics, guard, report), `versions/<VERSION>.env` (the expected
kernel and τ mkfs of a version), `baselines_libra09.csv` (beta baselines with their sources).

## Steps

| step | what | commands | estimate |
|---|---|---|---:|
| checks | kernel identity, τ mkfs, host, timers in the window | (read only) | <1 min |
| fp0a | raw PM1735, no file system: 16 KiB randwrite QD32 × 4 jobs, then 16 KiB writes at QD1 | `sudo fio ... --filename=$TAU_DEVICE` (60 s + 5 s ramp each) | 2.5 min |
| fp0b | KCHECK: PG sysbench oltp_write_only 64 on stock EXT4 (Raw), 10-min warm-up + 5 min | `env KCHECK=1 FS_GROUPS=ext4 FS_FPWON= FS_FPWOFF=ext4 THREADS_LIST=64 LAST_POINT_RUNS=1 WARMUP_TIME=600 RUNNING_TIME=300 run_main.sh postgres oltp_write_only` | 29 min |
| fp1 | micro: τ-EXT4, τ-XFS × e1 overwrite, append × T1, T64, sync1 at T64, 60 s each | `env CONFIGS="tau-EXT4 tau-XFS" EXPS="e1 sync1" OPS="overwrite append" THREADS_LIST="1 64" REPS=1 REPS_TOP=1 RUNTIME=60 FIRST_MODE=time run_fio.sh fast_<V>` | 44 min |
| fp1 | sync1 at T1 (a second call: run_fio.sh runs sync1 at TOP_T only) | `env CONFIGS="tau-EXT4 tau-XFS" EXPS=sync1 TOP_T=1 THREADS_LIST=1 REPS_TOP=1 RUNTIME=60 run_fio.sh fast_<V>_sync1t1` | 17 min |
| fp2 | sysbench oltp_write_only 64, 10-min warm-up + 5 min, PG and MySQL × τ-EXT4, τ-XFS (4 restores) | `env FS_GROUPS="ext4-tau xfs-tau" FS_FPWON= FS_FPWOFF="ext4-tau xfs-tau" THREADS_LIST=64 LAST_POINT_RUNS=1 WARMUP_TIME=600 RUNNING_TIME=300 run_main.sh <db> oltp_write_only` | 112 min |
| fp3 | TPC-C 1,100 WH, 64 terminals, 10-min warm-up + 5 min, PG and MySQL × τ-EXT4 (2 restores) | `env FS_GROUPS=ext4-tau FS_FPWON= FS_FPWOFF=ext4-tau THREADS_LIST=64 LAST_POINT_RUNS=1 WARMUP_TIME=600 RUNNING_TIME=300 run_tpcc.sh <db>` | 61 min |
| fp4 | kernel log, SMART, discards, huge pages, linger, timer services that ran; metrics and REPORT.md | (read only) | 3 min |
| | | **total** | **~4.5 h** |

Estimates: PM1735 restores measured in phase A on #1982 (11-11/12): ext4-tau images 12.1–14.0 min (183–194 GB),
xfs-tau 9.6–10.3 min (133–144 GB), the stock ext4 sysbench image 12 min; run_fio.sh's per-configuration trim, mkfs,
128 GiB layouts per thread count and 300 s settle (after a whole-device discard the PM1735 runs slower for 4–5 min).
Add ~3 min for the reboot into the kernel. Ways to shorten, all off by default because they change the protocol
between versions: `FP1_SYNC1_T1=0` (−17 min), a 5-min TPC-C warm-up (−10 min), a shorter micro settle (−3 min per
fresh file system).

## Decisions

- **Stop before anything is written** if the running kernel is not the version's (`uname -r`, `uname -v`, the boot
  image, `/boot/vmlinuz-*` and `/boot/config-*` md5, the image's version banner, `tau_journal` present with
  `tau_shrink_seeks` 32), if `codes/e2fsprogs` / `codes/xfsprogs-dev` are not at the version's τ mkfs, or if the host
  is not ready (test device not the PM1735, a DB/fio/VM running, linger off, 1 GiB huge pages in use).
- **Guard (FP0)**: the first fast run of `REF_VERSION` (beta) records KCHECK and the raw fio. Later runs go on only if
  KCHECK is within ±3% of it (`GUARD=strict`, the draft's rule), or, with `GUARD=device`, if the raw randwrite IOPS is
  within ±5% (the device holds, whatever the kernel under test does to the stock EXT4 path). Either way both values
  and their deltas are logged, so a KCHECK move can be told apart from a device change.
- **FAIL**: a kernel fault line since boot (BUG:, WARNING:, Oops, general protection, soft lockup, or a Call Trace
  outside a hung-task report), a failed step, τ inactive in a τ run (DB: τ-flagged fds 0 or no `tjournal`; micro:
  tau_fds not n/n, or O_DIRECT|O_TAU_UNTORN accepted), a SMART critical warning or new media errors, an unfinished
  run (an oops reboots the host: kernel.panic=30, panic_on_oops=1, softlockup_panic=1 during the run, as phase A).
- **Warnings only** (not FAIL), against the previous version's fast run: DB throughput ±3%, micro IOPS ±5%, p99 ±10%,
  both directions; hung-task reports; huge pages not freed; timer services (apt-daily, man-db, ...) that ran during
  the run; error-log entries that grew.
- TPC-C tpmC is compared on the database basis (as the baselines' `tables.md`); the BenchBase basis is shown too.
  τ÷App and τ÷Raw are indicative: the fast protocol (10-min warm-up + 5 min, one run) is shorter than the
  baselines'.

## Output

`$TAU_RESULTS/versions/<VERSION>/fast/<UTC>/`: `MANIFEST.txt` (kernel ids and tau_journal parameters, τ mkfs commits
and md5, stock mkfs md5, postgres/mysqld version and md5 with their source commits, umbrella HEAD with the uncommitted
paths and submodules, image sizes and mtimes with their provenance, the test device, machine_info.sh), `REPORT.md`,
`metrics.json`, `fast.log`, `STATUS`, `checks/` (steps.tsv, smart before/after, temperatures, kernel log, fp4.env),
`raw_fio/`, and the tools' own run directories (`TAU_RESULTS` points into the output directory for them). Nothing
else under `$TAU_RESULTS` changes. `run_tpcc.sh` ends with `export_results.py`, which rewrites the tracked
`bench/results/<host>/SUMMARY.md` from `TAU_RESULTS`; the driver keeps a copy before each TPC-C run and puts it back.

## Usage

```bash
VERSION=beta DRY=1 bench/suite/fast_perf.sh             # checks and the commands, nothing run or written
nohup setsid env VERSION=beta bench/suite/fast_perf.sh > /dev/null 2>&1 < /dev/null &   # on the beta kernel
python3 bench/suite/fast_report.py report <out> --prev <out> --baselines bench/suite/baselines_libra09.csv
```

### beta-fast (the first run)

#1982 is still installed as `/boot/vmlinuz-6.8.0tjournal+` (md5 0f059813... = the tree's 11-11 bzImage, banner #1982,
`/lib/modules/6.8.0tjournal+`), so a one-shot boot is enough: `sudo grub-reboot "Advanced options for Ubuntu>Ubuntu,
with Linux 6.8.0tjournal+"`, reboot, then the command above. GRUB's saved default stays base+, so the next plain
reboot returns to it. To start without anyone at the console, the @reboot route of final_tau (`reboot.sh` + `at_boot.sh`)
needs a phase that runs this script; not added yet (the run needs the user's approval first).

## Kernel names (survey for the user's decision; nothing changed)

Today the τ release is `6.8.0tjournal+`: `EXTRAVERSION = tjournal` in the τ tree's top Makefile (commit f40bd8fde7c3)
plus `make LOCALVERSION=+` (final_tau/prep.sh). Code that depends on the name:

- **τ-kernel tests by substring** `*tjournal*`: `micro/run_fio.sh` (τ configs and kcheck allowed only there),
  `micro/run_micro.sh`, `costs/run_r3.sh`, `costs/run_r3_drop.sh`, `sysbench/profile.sh` (appends the τ probes).
  A name without "tjournal" (e.g. `6.8.0-tau-v1.0`) makes run_fio.sh refuse τ configs and profile.sh silently drop
  the τ probes.
- **Exact name** `6.8.0tjournal+`: final_tau `phaseA.sh`, `m4_chain.sh`, `phaseB.sh` (`strings /boot/vmlinuz-6.8.0tjournal+`),
  `reboot.sh` (the `grub-reboot` entry and the banner check), `prep.sh` (module paths, the `.old-<build>` move, the
  install check, the VM initrd copy). These fail closed, but need the release as a parameter.
- **VM initrd names** `initrd.img-6.8.0tjournal+[-<build>]`: `tools/qemu/run_vm.sh` (default `VM_INITRD=/boot/initrd.img-6.8.0tjournal+`),
  `tools/t1seq2/run_seq2.sh`, `tools/recidem/{run,nth,c2}.sh`, `tools/crashmonkey/run_tau_suite.sh`,
  `tools/torner/campaign/table.sh`, `sysbench/run_recovery_vm.sh`. Risk: run_vm.sh's default would pair beta's
  initrd (modules of 6.8.0tjournal+) with a renamed tree bzImage without any error.
- Not name-dependent: `run_main.sh`, `run_tpcc.sh`, `run_burst.sh` (baselines by `TAU_BASE_KERNEL=6.8.0-base+`; τ by
  FS name), `run_pgvector.sh` (`*6.8.0*`), `common.sh`, `set_env.sh`, `host_setup.sh`, killtest.py.
- Cosmetic: `bench/machines/kernel/config-6.8.0tjournal+`, the inventory's kernel list, READMEs.

Suggestion: keep "tjournal" and add the version, `make LOCALVERSION=-v1.0` → `6.8.0tjournal-v1.0` (with LOCALVERSION
set, setlocalversion adds no "+"), leaving beta installed as `6.8.0tjournal+` (#1982; renaming beta would mean a
rebuild, a different binary from the measured one). Then only the exact-name and initrd sites need a release
parameter; the substring tests keep working. Better still, test τ by `/sys/module/tau_journal` (as fast_perf.sh does)
rather than by name. /boot has 776 MB free; a τ kernel takes ~110 MB (83 MB of it the initrd).
