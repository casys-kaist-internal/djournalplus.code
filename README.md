# taujournal.code

τJournal (tjournal; formerly DJPLUS), data journaling for ext4 and xfs: the
kernel and file-system tools, the benchmarks and the crash tests.

## Layout

| path | what |
|---|---|
| `codes/djournalplus-kernel.code/` | the τJournal kernel, Linux 6.8 (submodule; `$TAUFS_KERNEL`). τ work is on branch `new_main`; `v6.8.0-base` is the baseline kernel (base+). See *Branches and pins* |
| `codes/e2fsprogs/` | mke2fs fork that makes the tau journal (submodule, branch `tau`; `$TAUFS_E2FSPROGS`) |
| `codes/xfsprogs-dev/` | mkfs.xfs fork (submodule; `$TAUFS_XFSPROGS`) |
| `set_env.sh` | environment for every script; reads this machine's `bench/machines/<host>.env` |
| `bench/scripts/sysbench/` | sysbench: `run_main.sh`, `run_campaign.sh`, `create_image.sh`, `parse_main.py`, `paper_tables.py`; motivation (`run_motivation.sh`, `run_motiv*.sh`); profiling (`profile.sh`, `*.bt`, `profile_tables.py`, `offcpu_tables.py`); recovery time R2 (`run_recovery.sh`, `run_recovery_vm.sh` + `recovery_vm_guest.sh`, `recovery_report.py`; PG crash trials: `wal_trials.py`, `killcheck.py`, `redostart.py`, `kill_trace.py`) |
| `bench/scripts/micro/` | §6.3 microbenchmarks: `run_fio.sh` (atomicw or fio; M3 tracing with `m3_*.bt`, `m3_*report.py`), `run_micro.sh`, `atomicw.c`, `tau_preload.c`, `micro_tables.py` |
| `bench/scripts/costs/` | EVAL_PLAN R3, what truncate and unlink cost tau (`run_r3.sh`, `run_r3_drop.sh`; [README](bench/scripts/costs/README.md)) |
| `bench/scripts/benchbase/` | BenchBase TPC-C: `install.sh` builds the pinned upstream with `patches/`, `run_tpcc.sh`, `run_burst.sh`, `paper_tpcc.py`, pilot scripts |
| `bench/scripts/tpcc/` | HammerDB TPC-C (templates in `bench/hammerDB/`) |
| `bench/scripts/vectordb/` | pgvector through VectorDBBench: `install.sh`, `fetch_dataset.sh`, `run_pgvector.sh`, `parse_pgvector.py` |
| `bench/scripts/mysql/`, `postgres/` | install and server settings |
| `bench/scripts/` | also `common.sh` (mkfs, mount, images), `host_setup.sh`, `machine_info.sh`, `install_stock_mkfs.sh`, `hold_memory.sh`, `export_results.py`; old scripts in `99_Archive/` |
| `bench/suite/` | the fast test of every τ kernel change (~6 h): `fast_correct.sh` (correctness, in VMs; items in `fc/`) and `fast_perf.sh` (performance); versions in `versions/` (beta, v1.0, v1.1); [README](bench/suite/README.md), [fast_perf](bench/suite/README.fast_perf.md) |
| `bench/machines/` | per machine: `<host>.env` (SSDs, memory budget, boot arguments) and `<host>.txt` (machine_info.sh snapshot); `kernel/`: the configs of the installed kernels (`config-6.8.0tjournal+`, `config-6.8.0-base+`) |
| `bench/results/<host>/` | per-machine summary of the benchmark runs (`SUMMARY.md`) and what each run was (`README.md`) |
| `bench/docs/` | notes: sysbench workloads and DB defaults, the OSDI experiment plan, atomic-write micro results |
| `bench/mysql-server/`, `bench/postgresql/` | MySQL 8.4 and PostgreSQL 17 sources (submodules) |
| `bench/VectorDBBench/` | VectorDBBench (zilliztech) (submodule) |
| `bench/benchbase/` | BenchBase (cmu-db) (submodule at the pinned commit; `bench/scripts/benchbase/install.sh` applies our patches and builds into `bench/workspace/benchbase/`) |
| `bench/hammerDB/` | TPC-C templates for HammerDB (HammerDB itself in `bench/workspace/`) |
| `bench/workspace/` | not in git: the PostgreSQL install, stock mkfs, HammerDB, and the raw results (`results/<host>/`; τ rounds under `results/<host>/versions/<version>/{fast,full,extra}/`) |
| `tools/tautest/` | crash-recovery and concurrency tests of the tau journal in a VM with the test NVMe passed through ([README](tools/tautest/README.md); **destroys the test device**) |
| `tools/killtest/` | QEMU kill test: torn pages after a crash, microbenchmark and databases ([README](tools/killtest/README.md)); summary in `results/<host>/SUMMARY.md` |
| `tools/torner/` | Torner: crash states enumerated from a dm-log-writes log ([README](tools/torner/README.md)) |
| `tools/recidem/` | is τ's mount-time replay idempotent (EVAL_PLAN T3 #9): VM kills during recovery (`run.sh`, `nth.sh`, `c2.sh`) |
| `tools/t1seq2/` | CrashMonkey ACE seq-2 sample on τ (EVAL_PLAN T1; [README](tools/t1seq2/README.md)) |
| `tools/crashmonkey/` | CrashMonkey, ported to Linux 6.8 and τ (submodule, branch `port-linux-6.8`) |
| `tools/qemu/` | VM scripts (`run_vm.sh`, `run_vm_torner.sh`, `create_rootfs.sh`, `passthrough.sh`, `gdb.sh`), QEMU 7.2.1; disk images in `vm_imgs/` (not in git) |
| `tools/bin/` | links to the QEMU build, on `PATH` by set_env.sh (not in git) |
| `configs/` | local kernel configs (not in git) |

```shell
git submodule update --init --recursive
source set_env.sh                          # from the repository root, in every shell
```

`machine_info.sh` records the commits of the three `codes/` trees, and whether
they had local changes, in every result's machine snapshot.

## Conventions

- **One kernel per configuration**: τ configurations run only on the τ kernel;
  baselines only on the baseline kernel (`TAU_BASE_KERNEL`, kernel branch
  `v6.8.0-base`) with the stock mkfs (`bench/scripts/install_stock_mkfs.sh`,
  into `bench/workspace/stock`). The system `mke2fs` and `mkfs.xfs` built from
  `codes/` are the tau forks and make tau journals.
- **Name NVMe devices by serial** (`nvme list`): `/dev/nvmeN` can change from
  boot to boot. `tools/qemu/run_vm.sh` passes `NVME_PCIE_ADDR` to the VM.
- **Versions**: τ measurements are labeled by kernel version
  (`bench/suite/versions/`). A kernel change gets the fast test
  (`bench/suite/`).

## Branches

- Kernel: τ is branch `new_main`; the baseline kernel is `v6.8.0-base`.
- Results name the commits they ran (kernel, this repository, the DB and mkfs
  submodules), and `machine_info.sh` records them in each run's snapshot.

## A new machine

1. Copy an existing `bench/machines/<host>.env` to `bench/machines/$(hostname -s).env` and
   set the test and backup SSDs (`nvme list` model names), the memory the
   benchmarks may use (`TAU_MEM_GB`) and the boot arguments (`TAU_BOOT_ARGS`, in
   GRUB, e.g. 1 GiB huge pages that hold back the rest of the memory).
   The database caches (25%) and the ZFS ARC cap (50%) follow from
   `TAU_MEM_GB`; the dataset does not.
2. Boot the kernel for what you will measure (above), `source set_env.sh` (it
   mounts the backup SSD at `/mnt/tau_backup`), then
   `bench/scripts/host_setup.sh apply` and `check`.
3. Build the databases and tools: `bench/scripts/mysql/install_mysql.sh`,
   `bench/scripts/postgres/install_postgres.sh`,
   `bench/scripts/install_stock_mkfs.sh`, `bench/scripts/benchbase/install.sh`,
   `bench/scripts/tpcc/install_tpcc.sh`, `bench/scripts/vectordb/install.sh`.
4. Make the file-system images once per database:
   `TARGET_FILESYSTEM="ext4 xfs" bench/scripts/sysbench/create_image.sh mysql`.
5. Run: `bench/scripts/sysbench/run_campaign.sh <log>` (host setup and
   snapshot, images, every configuration) or `run_main.sh <db> [workloads]`.
   Raw results go to `bench/workspace/results/<host>/`; `run_campaign.sh`
   writes their summary to `bench/results/<host>/SUMMARY.md` with
   `bench/scripts/export_results.py` (run it by hand after `run_main.sh`), so
   machines can be compared in git.

## Crash tests

- `tools/tautest/`: fsync-acked data survives a power cut (qemu SIGKILL), and
  the write/commit/checkpoint paths under concurrency.
- `tools/killtest/` boots a VM, kills QEMU while the workload writes, and
  checks every 16 KiB chunk or the database's recovery and pages. A port of the
  earlier kill-test harness.
- `tools/torner/` records a workload with dm-log-writes in the VM and replays
  crash states from the log; its VM is `tools/qemu/run_vm_torner.sh`.
- `tools/crashmonkey/` (seq-1) and `tools/t1seq2/` (ACE seq-2 sample).
- `tools/recidem/`: a crash during recovery.
- `bench/suite/fast_correct.sh` runs a fixed selection of these against a
  pinned kernel.

## Kernel

Build on the host, then boot it on the host or in QEMU (`tools/qemu/`).

```shell
cd $TAUFS_KERNEL && git checkout new_main       # base+: v6.8.0-base
cp $TAUFS_ROOT/bench/machines/kernel/config-6.8.0tjournal+ .config   # base+: config-6.8.0-base+
make olddefconfig
make -j
sudo make modules_install
sudo make install
```

## PCIe passthrough to QEMU

Check the user's memlock limit with `ulimit -l`. If it is not "unlimited",
add to `/etc/security/limits.conf` (for the user who runs the VMs):

```
<user>    soft    memlock    unlimited
<user>    hard    memlock    unlimited
```

and `sudo systemctl restart systemd-logind`. Then:

1. Enable VT-d in the BIOS.
2. Make Linux use the IOMMU: add `intel_iommu=on` to
   `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, `sudo update-grub`,
   reboot, and check `dmesg | grep DMAR`.
3. Bind the NVMe drive to vfio (the PCI address from `lspci -D | grep -i nvme`):

   ```shell
   tools/qemu/passthrough.sh 0000:86:00.0         # nvme -> vfio-pci
   tools/qemu/passthrough.sh 0000:86:00.0 reset   # back to the nvme driver
   ```

   `tools/qemu/run_vm.sh` takes the address as `NVME_PCIE_ADDR`.

QEMU and GDB: `tools/qemu/README.md`.
