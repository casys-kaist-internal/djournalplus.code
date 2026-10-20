# libra09 benchmark results

`SUMMARY.md` lists the machine and every measured point of sysbench and of BenchBase TPC-C;
the runs themselves stay outside git, on libra09, in `bench/workspace/results/libra09/`
(sysbench runs each with `summary.txt`, `summary.csv` -- a row per measurement: TPS, latency,
device and DB write volumes -- and `env.txt`; TPC-C runs with BenchBase's output per
measurement and `summary.md`). `bench/scripts/export_results.py` remakes `SUMMARY.md` from
them; the sysbench campaigns and `run_tpcc.sh` run it at the end. The machine:
`bench/machines/libra09.{txt,env}`.

## Runs

sysbench, 16 tables x 32M rows (~120 GB), 64 GB of usable memory, caches 16 GB, 300 s per
point (`bench/scripts/sysbench/run_main.sh`).

| | MySQL | PostgreSQL | what |
|---|---|---|---|
| Stage 1 | `20260929_063532` | `20260930_054131` | ext4, xfs; protection (DWB/FPW) on and off; write_only, update_index, update_non_index, insert |
| ext4 data=journal | `20260929_231455` | `20260930_223555` | ext4-dj40, protection off, the four workloads |
| btrfs, old settings | `20261001_171503` | `20261001_123918` | protection off, the four workloads; superseded by `btrfs` below |
| ZFS, old layout | `20261002_031438` | `20261001_212126` | zfs-16k / zfs-8k as one dataset, logbias latency, OpenZFS 2.2.2; for write_only superseded by the motivation runs below (data/log split) |
| uniform, old settings | `20261001_032505_uniform`, `044332_uniform`, `20261002_072816_uniform`, `083534_uniform` | `20261001_052459_uniform`, `064502_uniform`, `20261002_064708_uniform`, `080556_uniform` | write_only at 64 threads, `--rand-type uniform`: ext4 on/off, ext4-dj40, btrfs, ZFS (old layout); superseded by `uniform` below |
| crashed | `20261002_010451_crashed-aio` | | ZFS with native AIO on, until the host hard-locked (64 threads, 3rd run): the Linux 6.8 aio_complete() bug, fixed in the 6.8.0-base+ kernel (caeb4b0a11b3); native AIO is on everywhere since 2026-10-08 |
| motivation, no TRIM | `20261008_113515` | `20261008_051022`, `20261008_061809` | write_only on kernel 6.8.0-base+, fixed seeds: ext4/xfs on/off, ext4-dj40, ZFS with the data/log split. Superseded: the SSD's latency drifted up during the campaign and MySQL ran last (`sysbench/diag/drift_20261008_2311`) |
| drift check | `20261008_231822`, `20261009_001853` | | MySQL XFS_App write_only after a full blkdiscard of the SSD, fixed / clock seeds |
| motivation, TRIM | `20261009_081451` | `20261009_015201` | the same with a blkdiscard of the test SSD before every restore; MySQL is the paper's Figure 2 data (`paper/motivation/sysbench_write_only/`), PG still forced a CHECKPOINT before each measurement (superseded) |
| motivation, PG checkpoints | | `20261009_151712` | PG write_only with the TRIM and without the forced CHECKPOINT (`PG_PRE_CHECKPOINT=0`): the paper's PG data |
| SSD sensitivity | `20261009_212738_fullfill` | `20261010_023220_fullfill` | EXT4 Raw/App, EXT4_Data, ZFS with the test SSD written over its whole capacity after the trim (`VARIANT=fullfill`) |
| profiling | `20261013_141643_prof-diag`, `20261014_074820_prof-diag` (off-CPU) | `20261013_122418_prof-diag`, `20261013_154102_prof-diag` | §3 Tables 2/3: write_only at 64 threads with counters, then a diagnosis window (`PROFILE=diag`): PG log sync on EXT4 Raw/App, EXT4_Data, ZFS (the second run measures 64 after 1–32 threads, as Figure 2), MySQL free-page waits and an off-CPU profile of the user threads on EXT4 Raw/App, ZFS perf profiles. Not exported; analysis in `paper/motivation/sysbench_profile_20261013/`. Smoke tests: `20261013_115659_prof-diag`, `20261013_121345_prof-diag` |
| evaluation workloads | `20261016_044321`, `20261016_165915`, `20261017_093244` | `20261015_223600`, `20261016_105303`, `20261017_032251` | EVAL_PLAN DB1: oltp_update_index, oltp_update_non_index, oltp_insert on the six baseline configurations with the Figure 2 protocol (`run_motivation.sh workloads`), 2026-10-15 to 10-18; paper data in `paper/evaluation/sysbench_workloads/` |
| delete, stopped | | `20261016_231053` | oltp_delete on EXT4/XFS Raw/App, then stopped: sysbench's delete-only workload runs out of hot rows, and most DELETEs find no row (see that README); not in the paper |
| uniform | `20261017_202936_uniform` | `20261017_171541_uniform` | write_only with `--rand-type=uniform` on EXT4 Raw/App and EXT4_Data, the Figure 2 protocol and thread sequence (`run_motivation.sh uniform`), 2026-10-18; paper data in `paper/motivation/sysbench_write_only/sensitivity_uniform/` |
| btrfs | `20261019_061714` | `20261019_020217` | the four workloads on btrfs (defaults: CoW, data checksums, discard=async on 6.8), protection off, the Figure 2 protocol (`run_motivation.sh btrfs`), 2026-10-19; unstable (seconds-long btrfs commits, see the paper README); paper data in `paper/evaluation/sysbench_workloads/`, TPC-C on btrfs in `paper/evaluation/tpcc_benchbase/` |

Raw only, not exported: in `benchbase/` the pilot at 100 warehouses, the image and copy logs and the first single-point 1,100-warehouse runs (`postgres/20261014_140913`, `mysql/20261014_165433`); the sweeps are in `SUMMARY.md` and are the paper's data in `paper/evaluation/tpcc_benchbase/` (2026-10-14/15, BTRFS 10-19; its README); `vectordb/` (pgvector, paper data in `paper/evaluation/pgvector/`); `sysbench/diag/` (ZFS and btrfs diagnosis, 2026-10-02/03), `fio/`
(pwrite and ext4 data=journal microbenchmarks, 2026-10-03), `pgbench/` and `tpcc/` (earlier
rounds), every `99_Archive/`. The QEMU kill tests: `tools/killtest/results/libra09/SUMMARY.md`.
