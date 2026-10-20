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
# Usage: [THREADS_LIST="1 8 16 32 64"] [FS_GROUPS=ext4 FS_FPWON=ext4 FS_FPWOFF=ext4]
#        run_tpcc.sh <postgres|mysql> [warehouses (1100)]
set -e
MODE="$1"
WH="${2:-1100}"
THREADS_LIST=(${THREADS_LIST:-1 8 16 32 64})
LAST_POINT_RUNS=${LAST_POINT_RUNS:-1}
WARMUP_TIME=${WARMUP_TIME:-600}
WARMUP_TERMINALS=64
POINT_WARMUP_TIME=60
RUNNING_TIME=${RUNNING_TIME:-300}
TERMINALS=$WARMUP_TERMINALS
FS_GROUPS="${FS_GROUPS-ext4}"
FS_FPWON="${FS_FPWON-ext4}"
FS_FPWOFF="${FS_FPWOFF-ext4}"
[[ "$MODE" == "postgres" || "$MODE" == "mysql" ]] || { echo "Usage: $0 <postgres|mysql> [warehouses]"; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
KEY="tpcc_w$WH"
BACKUP_DIR="$TAU_BACKUP_ROOT/benchbase/$MODE"
for FS in $FS_GROUPS; do
  [[ -e "$BACKUP_DIR/${FS}_${KEY}.img" ]] || { echo "❌ no image $BACKUP_DIR/${FS}_${KEY}.img (create_image.sh)"; exit 1; }
done
OUT="$TAU_RESULTS/benchbase/$MODE/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
source "$TAUFS_BENCH/scripts/benchbase/tpcc_lib.sh"
exec > >(tee -a "$OUT/run.log") 2>&1
echo "=== BenchBase TPC-C: $MODE, $WH warehouses, terminals ${THREADS_LIST[*]} (last x$LAST_POINT_RUNS), ${WARMUP_TIME} s warm-up, ${RUNNING_TIME} s per point; FS $FS_GROUPS (FPW/DWB on: $FS_FPWON; off: $FS_FPWOFF) $(date -u --rfc-3339=seconds)"
git -C "$TAUFS_BENCH/benchbase" log -1 --format='benchbase %h %cs' > "$OUT/versions"
java -version 2>&1 | head -1 >> "$OUT/versions"
log_env "$OUT/env.txt"

for FS in $FS_GROUPS; do
  for FPW in off on; do
    if [[ "$FPW" == off && " $FS_FPWOFF " != *" $FS "* ]] || [[ "$FPW" == on && " $FS_FPWON " != *" $FS "* ]]; then
      continue
    fi
    BLOCK="${MODE}_tpcc_${FS}_fpw_${FPW}_w${WH}"
    echo "=== $BLOCK: restoring ${FS}_${KEY} on $DEVICE $(date -u +%T)"
    restore_filesystem $FS "$KEY" "$BACKUP_DIR"
    mount_fs $FS "$MOUNT_DIR"
    set_fpw "$FPW"
    db_fs_settings "$FS"
    SERVER_LOG="$OUT/${BLOCK}_server.log"
    db_start
    echo "--> warm-up ${WARMUP_TIME} s, $WARMUP_TERMINALS terminals $(date -u +%T)"
    TERMINALS=$WARMUP_TERMINALS
    bb_config "$OUT/${BLOCK}_warmup.xml" true "$WARMUP_TIME" 0
    bb "${BLOCK}_warmup" --execute=true -d "$OUT/${BLOCK}_warmup" -s 10
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
      tpcc_run "$LABEL" true "$RUNNING_TIME" 0 "$FPW"
    done
    unset runs
    case "$MODE" in
      postgres) echo "db_bytes_after $(q "SELECT pg_database_size('tpcc')")" > "$OUT/$BLOCK.size" ;;
      mysql)    echo "db_bytes_after $(du -sb "$MY_DATA/tpcc" | cut -f1)" > "$OUT/$BLOCK.size" ;;
    esac
    db_stop
    umount_fs "$MOUNT_DIR"
  done
done
python3 "$TAUFS_BENCH/scripts/benchbase/pilot_report.py" "$OUT" > "$OUT/summary.md" || true
python3 "$TAUFS_BENCH/scripts/export_results.py" "$TAU_RESULTS" || true   # SUMMARY.md into git
echo "=== done $(date -u --rfc-3339=seconds) -> $OUT"
