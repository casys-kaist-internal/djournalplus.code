# libra09 benchmark results

`SUMMARY.md` lists the machine and every measured point; the runs themselves stay outside
git, on libra09, in `bench/workspace/results/libra09/` (each with `summary.txt`, `summary.csv`
-- a row per measurement: TPS, latency, device and DB write volumes -- and `env.txt`).
`bench/scripts/export_results.py` remakes `SUMMARY.md` from them; `run_campaign.sh` runs it
after every step. The machine: `bench/machines/libra09.{txt,env}`.

## Runs

sysbench, 16 tables x 32M rows (~120 GB), 64 GB of usable memory, caches 16 GB, 300 s per
point (`bench/scripts/sysbench/run_main.sh`).

| | MySQL | PostgreSQL | what |
|---|---|---|---|
| Stage 1 | `20260929_063532` | `20260930_054131` | ext4, xfs; protection (DWB/FPW) on and off; write_only, update_index, update_non_index, insert |
| ext4 data=journal | `20260929_231455` | `20260930_223555` | ext4-dj40, protection off, the four workloads |
| btrfs | `20261001_171503` | `20261001_123918` | protection off, the four workloads |
| ZFS, old layout | `20261002_031438` | `20261001_212126` | zfs-16k / zfs-8k as one dataset, logbias latency, OpenZFS 2.2.2. To run again with the data/log split (2026-10-06) |
| uniform | `20261001_032505_uniform`, `044332_uniform`, `20261002_072816_uniform`, `083534_uniform` | `20261001_052459_uniform`, `064502_uniform`, `20261002_064708_uniform`, `080556_uniform` | write_only at 64 threads, `--rand-type uniform`: ext4 on/off, ext4-dj40, btrfs, ZFS (old layout) |
| crashed | `20261002_010451_crashed-aio` | | ZFS with native AIO on, until the host hard-locked (64 threads, 3rd run); since then native AIO is off on ZFS |

Raw only, not exported: `sysbench/diag/` (ZFS and btrfs diagnosis, 2026-10-02/03), `fio/`
(pwrite and ext4 data=journal microbenchmarks, 2026-10-03), `pgbench/` and `tpcc/` (earlier
rounds), every `99_Archive/`. The QEMU kill tests: `tools/killtest/results/libra09/SUMMARY.md`.
