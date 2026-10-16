#!/bin/bash
# Motivation sysbench (paper §3, Figure 2) on a freshly booted host: host setup
# and snapshot, the ZFS images with the WAL/redo in their own dataset, then
# oltp_write_only on every baseline configuration (EXT4/XFS Raw/App, EXT4_Data,
# ZFS) for PostgreSQL and MySQL. Throughput only: no tracing and no per-second
# iostat (IOSTAT=0); the profiling runs (PROFILE=...) are separate.
# One step resumes the campaign from it (after a failure); several steps run
# just those, in order. The extra steps run only when named: fullfill (SSD
# sensitivity), the profiling steps, and workloads (the evaluation's other
# sysbench workloads with the same protocol, EVAL_PLAN DB1).
# Usage: run_motivation.sh <log file> [step ...]
LOG="$1"
STEPS=(host zfs_images pg mysql)
EXTRA_STEPS=(fullfill profile_smoke profile profile_seq offcpu workloads)
[ -n "$LOG" ] || { echo "Usage: $0 <log file> [${STEPS[*]} ${EXTRA_STEPS[*]}]"; exit 1; }
for s in "${@:2}"; do
  [[ " ${STEPS[*]} ${EXTRA_STEPS[*]} " == *" $s "* ]] || { echo "Unknown step: $s"; exit 1; }
done
if (( $# > 2 )); then
  RUN=("${@:2}")
elif [[ " ${EXTRA_STEPS[*]} " == *" ${2:-} "* ]]; then
  RUN=("$2")
else
  FROM="${2:-host}"
  RUN=()
  for s in "${STEPS[@]}"; do
    if [[ "$s" == "$FROM" || ${#RUN[@]} -gt 0 ]]; then RUN+=("$s"); fi
  done
fi
LOG=$(realpath -m "$LOG")
cd "$(dirname "$(realpath "$0")")/../../.." || exit 1   # repo root, for set_env.sh

run() {  # <db> <command...>: run, then summarize the newest result dir of <db>
  local db=$1 d rc
  shift
  echo "===== $* $(date -u --rfc-3339=seconds)"
  "$@" || { rc=$?; echo "===== FAILED rc=$rc $(date -u --rfc-3339=seconds)"; exit $rc; }
  d=$(ls -td "$TAU_RESULTS/sysbench/$db"/20*/ | head -1)
  python3 bench/scripts/sysbench/parse_main.py "$d" | tee "$d/summary.txt"
  python3 bench/scripts/export_results.py "$TAU_RESULTS"   # summaries into git
}

step() {
  local R=bench/scripts/sysbench/run_main.sh key d f
  echo "===== step $1 $(date -u --rfc-3339=seconds)"
  case $1 in
    host)
      bench/scripts/host_setup.sh apply || exit 1
      bash bench/scripts/machine_info.sh "$TAU_DEVICE_NAME" > "bench/machines/$TAU_HOST.txt"
      ;;
    zfs_images)
      # The earlier ZFS images keep the WAL/redo in the data dataset (refused by
      # run_main.sh); keep them aside instead of overwriting
      key=$(source bench/scripts/common.sh >/dev/null 2>&1; main_image_key)
      for d in postgres mysql; do
        d="$TAU_BACKUP_ROOT/sysbench/$d"
        mkdir -p "$d/old_single_dataset"
        for f in "$d"/zfs-*_"$key".img; do
          [ -e "$f" ] && sudo mv "$f" "$d/old_single_dataset/"
        done
      done
      env TARGET_FILESYSTEM=zfs-8k bench/scripts/sysbench/create_image.sh postgres || exit 1
      env TARGET_FILESYSTEM=zfs-16k bench/scripts/sysbench/create_image.sh mysql || exit 1
      ;;
    pg)
      run postgres env IOSTAT=0 PG_PRE_CHECKPOINT=0 FS_GROUPS="ext4 xfs ext4-dj40 zfs-8k" \
        FS_FPWON="ext4 xfs" FS_FPWOFF="ext4 xfs ext4-dj40 zfs-8k" $R postgres oltp_write_only
      ;;
    mysql)
      run mysql env IOSTAT=0 FS_GROUPS="ext4 xfs ext4-dj40 zfs-16k" FS_FPWON="ext4 xfs" \
        FS_FPWOFF="ext4 xfs ext4-dj40 zfs-16k" $R mysql oltp_write_only
      ;;
    fullfill)
      # SSD sensitivity: the device written once over its whole capacity after
      # the trim, then the same protocol on EXT4 Raw/App, EXT4_Data and ZFS
      run mysql env IOSTAT=0 VARIANT=fullfill FS_GROUPS="ext4 ext4-dj40 zfs-16k" \
        FS_FPWON="ext4" FS_FPWOFF="ext4 ext4-dj40 zfs-16k" $R mysql oltp_write_only
      run postgres env IOSTAT=0 VARIANT=fullfill PG_PRE_CHECKPOINT=0 \
        FS_GROUPS="ext4 ext4-dj40 zfs-8k" FS_FPWON="ext4" FS_FPWOFF="ext4 ext4-dj40 zfs-8k" \
        $R postgres oltp_write_only
      ;;
    profile_smoke)
      # a short pass through the PROFILE=diag hooks: the uprobes (MySQL) and
      # perf record / perf lock contention (ZFS)
      run mysql env PROFILE=diag WARMUP_TIME=60 RUNNING_TIME=60 DIAG_WINDOW_S=20 \
        FS_GROUPS="ext4" FS_FPWON="" FS_FPWOFF="ext4" $R mysql oltp_write_only
      run postgres env PROFILE=diag WARMUP_TIME=60 RUNNING_TIME=60 DIAG_WINDOW_S=20 \
        FS_GROUPS="zfs-8k" FS_FPWON="" FS_FPWOFF="zfs-8k" $R postgres oltp_write_only
      ;;
    profile)
      # §3 Tables 2/3: the motivation protocol at 64 threads (restore, 10-min
      # warm-up, one 5-min measurement with cheap counters only), then the
      # diagnosis window with the costly instruments (profile.sh PROFILE=diag)
      run postgres env PROFILE=diag FS_GROUPS="ext4 ext4-dj40 zfs-8k" FS_FPWON="ext4" \
        FS_FPWOFF="ext4 ext4-dj40 zfs-8k" $R postgres oltp_write_only
      run mysql env PROFILE=diag FS_GROUPS="ext4 zfs-16k" FS_FPWON="ext4" \
        FS_FPWOFF="ext4 zfs-16k" $R mysql oltp_write_only
      ;;
    profile_seq)
      # PG EXT4_Data and ZFS measured right after the warm-up (profile) ran
      # 18-21% faster than at 64 threads in the throughput runs, which drift
      # down over a block: the same profiling at the end of the throughput
      # sweep (1, 8, 16, 32 threads first), with EXT4_Raw as the base
      run postgres env PROFILE=diag PROFILE_THREADS="1 8 16 32 64" \
        FS_GROUPS="ext4 ext4-dj40 zfs-8k" FS_FPWON="" FS_FPWOFF="ext4 ext4-dj40 zfs-8k" \
        $R postgres oltp_write_only
      ;;
    workloads)
      # §6.4 DB1: the other sysbench workloads with the Figure 2 protocol on the
      # six baseline configurations; per workload PG, then MySQL
      for wl in ${EVAL_WORKLOADS:-oltp_update_index oltp_update_non_index oltp_delete oltp_insert}; do
        run postgres env IOSTAT=0 PG_PRE_CHECKPOINT=0 FS_GROUPS="ext4 xfs ext4-dj40 zfs-8k" \
          FS_FPWON="ext4 xfs" FS_FPWOFF="ext4 xfs ext4-dj40 zfs-8k" $R postgres $wl
        run mysql env IOSTAT=0 FS_GROUPS="ext4 xfs ext4-dj40 zfs-16k" FS_FPWON="ext4 xfs" \
          FS_FPWOFF="ext4 xfs ext4-dj40 zfs-16k" $R mysql $wl
      done
      ;;
    offcpu)
      # MySQL's mean latency rises 0.50 ms with doublewrite, 0.07 ms of it in
      # free-page waits: where the user threads' time goes on EXT4 Raw and App
      # (schedstat and offcpu.bt in the diagnosis window, DIAG_TOOLS=offcpu)
      run mysql env PROFILE=diag DIAG_TOOLS=offcpu FS_GROUPS="ext4" FS_FPWON="ext4" \
        FS_FPWOFF="ext4" $R mysql oltp_write_only
      ;;
  esac
  touch "$LOG.$1.done"
}

{
  source set_env.sh || { echo "===== set_env.sh failed"; exit 1; }
  echo "===== steps: ${RUN[*]}"
  for s in "${RUN[@]}"; do step $s; done
  echo "===== done $(date -u --rfc-3339=seconds)"
} 2>&1 | tee -a "$LOG"
echo "${PIPESTATUS[0]}" > "$LOG.done"
