# djournalplus.code

τJournal (tjournal; formerly DJPLUS), data journaling for ext4 and xfs: the
kernel and file-system tools, the benchmarks and the crash tests.

## Layout

| path | what |
|---|---|
| `codes/djournalplus-kernel.code/` | the τJournal kernel, Linux 6.8 (submodule; `$TAUFS_KERNEL`) |
| `codes/e2fsprogs/` | mke2fs fork that makes the tau journal (submodule, branch `tau`; `$TAUFS_E2FSPROGS`) |
| `codes/xfsprogs-dev/` | mkfs.xfs fork (submodule; `$TAUFS_XFSPROGS`) |
| `set_env.sh` | environment for every script; reads this machine's `bench/machines/<host>.env` |
| `bench/scripts/` | performance benchmarks: `sysbench/` (run_main.sh, run_campaign.sh, create_image.sh, parse_main.py), `tpcc/`, `mysql/` and `postgres/` (install, server settings), `common.sh` (mkfs, mount, images), `host_setup.sh`, `machine_info.sh`, `export_results.py` |
| `bench/machines/` | per machine: `<host>.env` (SSDs, memory budget) and `<host>.txt` (machine_info.sh snapshot) |
| `bench/results/<host>/` | per-machine summary of the benchmark runs (`SUMMARY.md`) and what each run was (`README.md`) |
| `bench/mysql-server/`, `bench/postgresql/` | MySQL 8.4 and PostgreSQL 17 sources (submodules) |
| `bench/hammerDB/` | TPC-C templates for HammerDB |
| `bench/workspace/` | not in git: the PostgreSQL install, stock mkfs, HammerDB, and the raw results (`results/<host>/`) |
| `tools/killtest/` | QEMU kill test: torn pages after a crash, microbenchmark and databases; summary in `results/<host>/SUMMARY.md` |
| `tools/torner/` | Torner: crash states enumerated from a dm-log-writes log (the plan in `CRASH_TODO.md`) |
| `tools/qemu/` | VM scripts for the τJournal kernel (`run_vm.sh`, `run_vm_torner.sh`, `create_rootfs.sh`, `passthrough.sh`, gdb), QEMU 7.2.1; disk images in `vm_imgs/` (not in git) |
| `tools/crashmonkey/` | CrashMonkey, ported to Linux 6.8 (submodule) |
| `tools/bin/` | links to the QEMU build, on `PATH` by set_env.sh (not in git) |
| `configs/` | kernel configs (not in git) |

```shell
git submodule update --init --recursive
source set_env.sh        # from the repository root, in every shell
```

`machine_info.sh` records the commits of the three `codes/` trees, and whether
they had local changes, in every result's machine snapshot.

## A new machine

1. Copy `bench/machines/libra09.env` to `bench/machines/$(hostname -s).env` and
   set the test and backup SSDs (`nvme list` model names), the memory the
   benchmarks may use (`TAU_MEM_GB`) and the boot arguments that hold back the
   rest as unused huge pages (`TAU_BOOT_ARGS`, in GRUB). The database caches
   (25%) and the ZFS ARC cap (50%) follow from `TAU_MEM_GB`; the dataset does not.
2. Boot the τJournal kernel (below), `source set_env.sh` (it mounts the backup
   SSD at `/mnt/tau_backup`), then `bench/scripts/host_setup.sh apply` and
   `check`.
3. Build the databases and tools: `bench/scripts/mysql/install_mysql.sh`,
   `bench/scripts/postgres/install_postgres.sh`,
   `bench/scripts/install_stock_mkfs.sh` (baselines use the distro mkfs; the
   system ones are the tau forks, built and installed from `$TAUFS_E2FSPROGS`
   and `$TAUFS_XFSPROGS`), `bench/scripts/tpcc/install_tpcc.sh`.
4. Make the file-system images once per database:
   `TARGET_FILESYSTEM="ext4 xfs" bench/scripts/sysbench/create_image.sh mysql`.
5. Run: `bench/scripts/sysbench/run_campaign.sh <log>` (host setup and
   snapshot, images, every configuration) or `run_main.sh <db> [workloads]`.
   Raw results go to `bench/workspace/results/<host>/`; `run_campaign.sh`
   writes their summary to `bench/results/<host>/SUMMARY.md` with
   `bench/scripts/export_results.py` (run it by hand after `run_main.sh`), so
   machines can be compared in git.

## Crash tests

- `tools/killtest/` boots a VM, kills QEMU while the workload writes, and
  checks every 16 KiB chunk or the database's recovery and pages
  ([README](tools/killtest/README.md)). A port of the SOSP round's
  `taujournal-test.code`.
- `tools/torner/` records a workload with dm-log-writes in the VM and replays
  crash states from the log ([README](tools/torner/README.md)); its VM is
  `tools/qemu/run_vm_torner.sh`.

## Kernel

Build on the host, then boot it on the host or in QEMU (`tools/qemu/`). If a
newer gcc fails, use gcc-9 (gcc-13 broke the build of an older tree).

```shell
cp configs/vm_config $TAUFS_KERNEL/.config   # or host_config_6.8
cd $TAUFS_KERNEL
make menuconfig   # optional
make -j
sudo make modules_install
sudo make install
```

## PCIe passthrough to QEMU

Check the user's memlock limit with `ulimit -l`. If it is not "unlimited",
add to `/etc/security/limits.conf` (for user jhlee):

```
jhlee    soft    memlock    unlimited
jhlee    hard    memlock    unlimited
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

   The same address goes into `tools/qemu/run_vm.sh`.

QEMU and GDB: `tools/qemu/README.md`.
