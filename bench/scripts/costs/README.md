# costs/: EVAL_PLAN R3 (§6.5 Costs), what truncate and unlink cost tau

Tools only: the numbers for the paper come from libra09 on the measurement
kernel (#1982, 81f4707b); the libra08 runs (a VM on #401, the same tau code)
only checked that the tools measure what they say.

| Item | Script | What |
|---|---|---|
| 1 truncate | `run_r3.sh` | `ftruncate(fd, 0)` of a 1 GiB file, journal residency 0 and 1 GiB |
| 2 unlink | `run_r3.sh` | `unlink(2)` of such a file (closed: its eviction runs inside the call) |
| 3 DB | `run_r3_drop.sh` | `DROP TABLE sbtest1` on a running PostgreSQL / MySQL, tau-EXT4 vs EXT4_App |
| 4 calls | `run_main.sh` with `PROFILE=r3` (`../sysbench/profile.sh`) | every truncate / unlink / punch / rename over a file during the §6.4 write-only 64-thread run, per file |

Helpers: `r3op.py` (one timed call with its windows; also used by
`run_r3_drop.sh`), `r3_report.py` (results.jsonl -> results.csv,
summary.md), `r3_calls.bt` + `r3_calls_report.py` (item 4, and the calls of
`run_r3_drop.sh`'s runs). The script headers have the details.

## What is measured

- **latency**: the call (items 1-2); the statement from the client and from
  the server (item 3: psql `\timing`, MySQL `performance_schema` TIMER_WAIT).
- **device writes**: the block layer's `block_rq_issue` on the test device
  (tracefs, trace clock mono; on an NVMe multipath head such as libra09's
  PM1735, whose path disk has no dev_t in sysfs, `block_bio_remap` of the head's
  bios), checked against `/sys/block/<dev>/stat` of the device or its path node
  (`trace_ok`), split by time into the call (`sync_*`) and after it (`after_*`:
  until the tau segments are back, at least `AFTER_MIN` s, then a syncfs), and by
  place into `home` (the blocks the file(s) had before the call, FIEMAP without
  sync; after the host's first commit such writes are counted as `reuse`: ext4
  may have given the blocks to another file by then) and `other` (journals,
  metadata). A syncfs before the call keeps earlier metadata out. A truncate's
  revoke tags are in `sync_other_bytes`.
- **residency**: `tau_journal_usage` (`/sys/module/tau_journal/parameters/`,
  in every tau kernel): the journal's used segments after the overwrite minus
  before it, times the segment size.
- **segments back**: the time from the call's return until the used segments are
  back at that count (one segment of slack: a truncate's own commit), and the
  host's first jbd2 commit after the call (ext4). `AFTERS="wait sync"`: by the
  host's own commit (ext4 every 5 s, XFS's log worker up to 30 s), or a syncfs
  right after the call (what is left is tau's next journald pass).
- **tau probe counters** (`tau_probe_*`: free_cond, free_skip, free_hold,
  jwrite_revoke, dead_*, flush_submit, ...) during and after the call, only where
  the kernel has `CONFIG_TAU_PROBE_TORN`. libra09's tau configuration
  (`bench/machines/kernel/config-6.8.0tjournal+`) does not: there the tag bytes
  are the device bytes.
- **void runs** (`r3_report.py`): reclaim scanned the shrinkers between the
  overwrite and the call (`/proc/vmstat`: tau then checkpoints the file's oldest
  tx whole), the device was busy before a truncate/unlink, the trace missed
  device writes, or a res1g tau file had less than its size in the journal.
  Nothing in these scripts drops caches.

## Running it (libra09)

`source set_env.sh` first; the test device (`TARGET_DISK`) is mkfs'd and
restored as by every bench script. `HOST_CHECK` as `run_main.sh`.

On the tau kernel (#1982):

    bash bench/scripts/costs/run_r3.sh r3                                   # tau-EXT4: 24 runs, ~10 min
    bash bench/scripts/costs/run_r3_drop.sh postgres r3                     # tau-EXT4, write 0 and 300 s: ~30 min
    bash bench/scripts/costs/run_r3_drop.sh mysql r3
    PROFILE=r3 FS_GROUPS=ext4-tau FS_FPWON= FS_FPWOFF=ext4-tau \
      bash bench/scripts/sysbench/run_main.sh postgres oltp_write_only      # item 4: ~25 min
    PROFILE=r3 FS_GROUPS=ext4-tau FS_FPWON= FS_FPWOFF=ext4-tau \
      bash bench/scripts/sysbench/run_main.sh mysql oltp_write_only

Baselines (EXT4, EXT4_App) either on the base kernel (6.8.0-base+, a reboot):

    bash bench/scripts/costs/run_r3.sh r3                                   # EXT4
    bash bench/scripts/costs/run_r3_drop.sh postgres r3                     # EXT4_App
    bash bench/scripts/costs/run_r3_drop.sh mysql r3

or on the tau kernel, labeled `-kcheck` (no reboot): `KCHECK=1` before each of
those, with `CONFIGS="EXT4 tau-EXT4"` / `CONFIGS="EXT4_App tau-EXT4"` to run
both sides in one go. XFS: `CONFIGS="XFS tau-XFS"` (run_r3.sh),
`CONFIGS="XFS_App tau-XFS"` (run_r3_drop.sh, images `xfs`/`xfs-tau`).

Results: `bench/workspace/results/<host>/r3/<date>_r3_<tag>/` and
`.../r3/<date>_r3drop_<dbms>_<tag>/` (`env.txt`: machine, kernel, commits,
devices; `results.csv`, `summary.md`); item 4 in run_main.sh's own directory
(`..._prof-r3`, with a `NOT_THROUGHPUT` note: its TPS are not results),
`<block>.r3calls.txt` per database.
