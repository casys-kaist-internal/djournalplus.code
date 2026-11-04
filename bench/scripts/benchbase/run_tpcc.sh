#!/bin/bash
# BenchBase TPC-C measurements on the images of create_image.sh, with the
# sysbench protocol (run_main.sh): per configuration, trim and restore, the
# benchmark server settings with FPW/DWB on or off, a warm-up run (WARMUP_TIME,
# 10 min, 64 terminals), then the terminal counts of THREADS_LIST on the same
# database, each with a 60-s warm-up when the count changes and one measured
# run (RUNNING_TIME, 5 min; the last count LAST_POINT_RUNS times) with the
# counters around it (tpcc_lib.sh tpcc_run), and a shutdown. randomWarehouse,
# rate unlimited. FS_GROUPS, FS_FPWON and FS_FPWOFF pick the configurations as
# in run_main.sh. Results: $TAU_RESULTS/benchbase/<db>/<ts>/, one
# <db>_tpcc_<fs>_fpw_<on|off>_w<WH>_c<terminals>_r<n> per measurement, and
# summary.md (pilot_report.py).
# VARIANT=ssd990: the test device is the Samsung 990 PRO 4TB (TAU_TARGET_DISK
# when set_env.sh ran), kept in its steady state (no trim before the restore, no
# online discard; MySQL's spare redo files pre-written after the start); results
# <ts>_ssd990, configurations <fs>-ssd990 (as run_main.sh).
# PROFILE=files (EVAL_PLAN DB2, as run_main.sh's): after the warm-up one
# measurement at 64 terminals (PROFILE_THREADS) under file_writes.bt (writes
# and syncs per file, sync latency per file type), the files of the mount with
# their inode numbers at the end; results <ts>_prof-files, left out of
# SUMMARY.md.
# Usage: [THREADS_LIST="1 8 16 32 64"] [FS_GROUPS=ext4 FS_FPWON=ext4 FS_FPWOFF=ext4]
#        [VARIANT=ssd990] [POINT_WARMUP_TIME=60] [PROFILE=files] run_tpcc.sh <postgres|mysql> [warehouses (1100)]
set -e
MODE="$1"
WH="${2:-1100}"
THREADS_LIST=(${THREADS_LIST:-1 8 16 32 64})
LAST_POINT_RUNS=${LAST_POINT_RUNS:-1}
WARMUP_TIME=${WARMUP_TIME:-600}
WARMUP_TERMINALS=64
POINT_WARMUP_TIME=${POINT_WARMUP_TIME:-60}
RUNNING_TIME=${RUNNING_TIME:-300}
TERMINALS=$WARMUP_TERMINALS
FS_GROUPS="${FS_GROUPS-ext4}"
FS_FPWON="${FS_FPWON-ext4}"
FS_FPWOFF="${FS_FPWOFF-ext4}"
[[ "$MODE" == "postgres" || "$MODE" == "mysql" ]] || { echo "Usage: $0 <postgres|mysql> [warehouses]"; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
VARIANT="${VARIANT:-}"
case "$VARIANT" in
  "") ;;
  ssd990)
    [[ "$(cat /sys/block/$TAU_DEVICE_NAME/device/model 2>/dev/null | xargs)" == "Samsung SSD 990 PRO 4TB" ]] \
      || { echo "❌ VARIANT=ssd990: source set_env.sh with TAU_TARGET_DISK=\"Samsung SSD 990 PRO 4TB\""; exit 1; }
    TAU_TRIM_BEFORE_RESTORE=0; TAU_NO_DISCARD=1; MY_PREWRITE_REDO=1 ;;
  odirect)  # as run_main.sh: MySQL O_DIRECT, buffer pool 75% of TAU_MEM_GB
    [[ "$MODE" == "mysql" ]] || { echo "❌ VARIANT=odirect is for mysql"; exit 1; }
    MY_FLUSH_METHOD=O_DIRECT; MY_BUFFER_POOL_SIZE=$(( TAU_MEM_GB * 3 / 4 ))G ;;
  walcomp)  # as run_main.sh: PG wal_compression=lz4 with pg_install_lz4
    [[ "$MODE" == "postgres" ]] || { echo "❌ VARIANT=walcomp is for postgres"; exit 1; }
    PG_BIN="$TAUFS_BENCH_WS/pg_install_lz4/bin"; PG_WAL_COMPRESSION=lz4
    [[ -x "$PG_BIN/postgres" ]] || { echo "❌ VARIANT=walcomp: no $PG_BIN (PG_LZ4=1 install_postgres.sh)"; exit 1; } ;;
  quick) ;;  # as run_main.sh: settings unchanged, a label for short checks
  *) echo "❌ Unknown VARIANT: $VARIANT"; exit 1 ;;
esac
PROFILE="${PROFILE:-}"
case "$PROFILE" in
  "") ;;
  files)
    for FS in $FS_GROUPS; do
      case $FS in zfs*|btrfs) echo "❌ PROFILE=files is for ext4 and xfs, not $FS"; exit 1 ;; esac
    done
    [[ -e /sys/kernel/btf/vmlinux ]] || { echo "❌ PROFILE needs kernel BTF"; exit 1; }
    THREADS_LIST=(${PROFILE_THREADS:-64}); LAST_POINT_RUNS=1 ;;
  *) echo "❌ run_tpcc.sh: PROFILE=files only"; exit 1 ;;
esac
KEY="tpcc_w$WH"
BACKUP_DIR="$TAU_BACKUP_ROOT/benchbase/$MODE"
for FS in $FS_GROUPS; do
  [[ -e "$BACKUP_DIR/${FS}_${KEY}.img" ]] || { echo "❌ no image $BACKUP_DIR/${FS}_${KEY}.img (create_image.sh)"; exit 1; }
done
OUT="$TAU_RESULTS/benchbase/$MODE/$(date +%Y%m%d_%H%M%S)${VARIANT:+_$VARIANT}${PROFILE:+_prof-$PROFILE}"
mkdir -p "$OUT"
source "$TAUFS_BENCH/scripts/benchbase/tpcc_lib.sh"
exec > >(tee -a "$OUT/run.log") 2>&1
echo "=== BenchBase TPC-C: $MODE, $WH warehouses, terminals ${THREADS_LIST[*]} (last x$LAST_POINT_RUNS), ${WARMUP_TIME} s warm-up, ${RUNNING_TIME} s per point; FS $FS_GROUPS (FPW/DWB on: $FS_FPWON; off: $FS_FPWOFF) $(date -u --rfc-3339=seconds)"
git -C "$TAUFS_BENCH/benchbase" log -1 --format='benchbase %h %cs' > "$OUT/versions"
java -version 2>&1 | head -1 >> "$OUT/versions"
log_env "$OUT/env.txt"

# PROFILE=files around the measurement: files_begin <label>, files_end <label>
files_begin() {
  local filt=0 devnum i
  [[ "$MODE" == mysql ]] && filt=$MYSQLD_PID
  devnum=$(( (0x$(stat -c %t "$DEVICE") << 20) | 0x$(stat -c %T "$DEVICE") ))
  sudo modprobe xfs   # file_writes.bt probes kfunc:xfs (built in on the tau kernel)
  sudo env BPFTRACE_MAX_MAP_KEYS=200000 \
    bpftrace "$(bt_for_kernel "$TAUFS_BENCH/scripts/sysbench/file_writes.bt" "$OUT/$1.files.bt")" \
    "$filt" "$devnum" > "$OUT/$1.bpftrace" 2>&1 &
  FILES_BT_PID=$!
  for (( i = 0; i < 60; i++ )); do   # the measurement starts once every probe is attached
    grep -q "^Attaching" "$OUT/$1.bpftrace" 2>/dev/null && break
    sleep 1
  done
  sleep 2
}
files_end() {
  sudo kill -INT "$FILES_BT_PID" 2>/dev/null || true
  wait "$FILES_BT_PID" 2>/dev/null || true
  sudo find "$MOUNT_DIR" -xdev -type f -printf '%i %s %p\n' > "$OUT/$1.inodes" 2>/dev/null || true
}

for FS in $FS_GROUPS; do
  for FPW in off on; do
    if [[ "$FPW" == off && " $FS_FPWOFF " != *" $FS "* ]] || [[ "$FPW" == on && " $FS_FPWON " != *" $FS "* ]]; then
      continue
    fi
    BLOCK="${MODE}_tpcc_${FS}${VARIANT:+-$VARIANT}_fpw_${FPW}_w${WH}"
    echo "=== $BLOCK: restoring ${FS}_${KEY} on $DEVICE $(date -u +%T)"
    restore_filesystem $FS "$KEY" "$BACKUP_DIR"
    mount_fs $FS "$MOUNT_DIR"
    echo "mount: $(findmnt -no FSTYPE,OPTIONS "$MOUNT_DIR" | head -1)"
    set_fpw "$FPW"
    db_fs_settings "$FS"
    SERVER_LOG="$OUT/${BLOCK}_server.log"
    db_start
    echo "--> warm-up ${WARMUP_TIME} s, $WARMUP_TERMINALS terminals $(date -u +%T)"
    TERMINALS=$WARMUP_TERMINALS
    bb_config "$OUT/${BLOCK}_warmup.xml" true "$WARMUP_TIME" 0
    bb "${BLOCK}_warmup" --execute=true -d "$OUT/${BLOCK}_warmup" -s 10
    log_tau_fds "$OUT/${BLOCK}.tau"
    points=("${THREADS_LIST[@]}")
    for (( i = 1; i < LAST_POINT_RUNS; i++ )); do points+=("${THREADS_LIST[-1]}"); done
    prev=$WARMUP_TERMINALS
    declare -A runs=()
    for TERMINALS in "${points[@]}"; do
      runs[$TERMINALS]=$(( ${runs[$TERMINALS]:-0} + 1 ))
      LABEL="${BLOCK}_c${TERMINALS}_r${runs[$TERMINALS]}"
      if [[ "$TERMINALS" != "$prev" ]]; then
        echo "--> point warm-up ${POINT_WARMUP_TIME} s, $TERMINALS terminals $(date -u +%T)"
        bb_config "$OUT/${LABEL}_warmup.xml" true "$POINT_WARMUP_TIME" 0
        bb "${LABEL}_warmup" --execute=true -d "$OUT/${LABEL}_warmup" -s 10
        prev=$TERMINALS
      fi
      echo "--> $LABEL: ${RUNNING_TIME} s $(date -u +%T)"
      [[ -z "$PROFILE" ]] || files_begin "$LABEL"
      tpcc_run "$LABEL" true "$RUNNING_TIME" 0 "$FPW"
      [[ -z "$PROFILE" ]] || files_end "$LABEL"
    done
    unset runs
    case "$MODE" in
      postgres) echo "db_bytes_after $(q "SELECT pg_database_size('tpcc')")" > "$OUT/$BLOCK.size" ;;
      mysql)    echo "db_bytes_after $(du -sb "$MY_DATA/tpcc" | cut -f1)" > "$OUT/$BLOCK.size" ;;
    esac
    db_stop
    umount_fs "$MOUNT_DIR"
    clear_fs $FS "$DEVICE"   # as run_main.sh: zfs pools exported, signatures wiped
  done
done
python3 "$TAUFS_BENCH/scripts/benchbase/pilot_report.py" "$OUT" > "$OUT/summary.md" || true
[[ -n "$PROFILE" ]] || python3 "$TAUFS_BENCH/scripts/export_results.py" "$TAU_RESULTS" || true   # SUMMARY.md into git
echo "=== done $(date -u --rfc-3339=seconds) -> $OUT"
