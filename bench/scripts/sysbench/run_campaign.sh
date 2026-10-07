#!/bin/bash
# The revision's sysbench campaign on a freshly booted host: host setup and
# snapshot, MySQL images (with the full redo log), then every configuration
# (EVAL_PLAN DB1 stage 1 on ext4/xfs with protection on/off, and EXT4_Data).
# oltp_delete is on hold. Give a later step to resume after a failure.
# Usage: run_campaign.sh <log file> [host|images|mysql|pg|mysql_dj40|pg_dj40]
LOG="$1"
FROM="${2:-host}"
STEPS=(host images mysql pg mysql_dj40 pg_dj40)
W="oltp_write_only oltp_update_index oltp_update_non_index oltp_insert"
[ -n "$LOG" ] || { echo "Usage: $0 <log file> [${STEPS[*]}]"; exit 1; }
[[ " ${STEPS[*]} " == *" $FROM "* ]] || { echo "Unknown step: $FROM"; exit 1; }
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
  local R=bench/scripts/sysbench/run_main.sh
  local DATA="FS_GROUPS=ext4-dj40 FS_FPWON= FS_FPWOFF=ext4-dj40"
  echo "===== step $1 $(date -u --rfc-3339=seconds)"
  case $1 in
    host)
      bench/scripts/host_setup.sh apply || exit 1
      bash bench/scripts/machine_info.sh "$TAU_DEVICE_NAME" > "bench/machines/$TAU_HOST.txt"
      ;;
    images)
      env TARGET_FILESYSTEM="ext4 xfs ext4-dj40" bench/scripts/sysbench/create_image.sh mysql || exit 1
      ;;
    mysql)      run mysql $R mysql $W ;;
    pg)         run postgres $R postgres $W ;;
    mysql_dj40) run mysql env $DATA $R mysql $W ;;
    pg_dj40)    run postgres env $DATA $R postgres $W ;;
  esac
  touch "$LOG.$1.done"
}

{
  source set_env.sh || { echo "===== set_env.sh failed"; exit 1; }
  started=0
  for s in "${STEPS[@]}"; do
    [ "$s" = "$FROM" ] && started=1
    if [ $started = 1 ]; then step $s; fi
  done
  echo "===== done $(date -u --rfc-3339=seconds)"
} 2>&1 | tee -a "$LOG"
echo "${PIPESTATUS[0]}" > "$LOG.done"
