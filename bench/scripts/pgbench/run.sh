#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

# DB_TUNING="no" # Default
# DB_TUNING="min"

# scale=1000 ≈ 16 GB
SCALE_LIST=(10000 20000)
CLIENT_LIST=(16 32 64)
THREADS=32 # fixed
RUNNING_TIME=1800
WARMUP_TIME=600
TX_COUNT=100000 # for check IO Volume

# Filesystem groups
declare -A FS_GROUPS

FS_GROUPS[on]=""
FS_GROUPS[off]="zfs"

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/postgres/setup.sh"

DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/pgbench/$DATE"
mkdir -p "$RESULT_DIR"

# IO capture helper
iostat_start() {
    DEVICE_NAME=$(basename "$TAU_DEVICE")
    LOG_FILE=$1
    iostat -dmx 1 "$DEVICE_NAME" > "$LOG_FILE" &
    IOSTAT_PID=$!
}
iostat_end() {
    if [[ -n "$IOSTAT_PID" ]]; then
        kill "$IOSTAT_PID"
        wait "$IOSTAT_PID" 2>/dev/null || true
    fi
}
restore_filesystem() {
  FS=$1
  SCALE=$2
  echo "[+] Restoring filesystem: $FS"
  case $FS in
    ext4)
      sudo partclone.$FS -r -s $BACKUP_DIR/${FS}_s${SCALE}.img -o $TAU_DEVICE
      ;;
    zfs)
      do_mkfs $FS $DEVICE
      mount_fs $FS $MOUNT_DIR
      sudo sh -c "zfs receive -F zfspool < '$BACKUP_DIR/${FS}_s${SCALE}.img'"
      umount_fs $MOUNT_DIR
      ;;
    taujournal)
      sudo partclone.ext4 -r -s $BACKUP_DIR/${FS}_s${SCALE}.img -o $TAU_DEVICE
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
  sleep 1
  drop_caches
}

## Start here
# MAIN LOOP
for FPW in on off; do
  for FS in ${FS_GROUPS[$FPW]}; do
    for SCALE in "${SCALE_LIST[@]}"; do
      for CLIENT in "${CLIENT_LIST[@]}"; do
        LABEL="${FS}_fpw_${FPW}_s${SCALE}_c${CLIENT}"
        OUT_SUMMARY="$RESULT_DIR/${LABEL}.summary"
        OUT_LOG="$RESULT_DIR/${LABEL}.log"
        IOLOG="$RESULT_DIR/${LABEL}_iostat.log"

        echo "=== Setting up FS: $FS (FPW=$FPW) in device($DEVICE) ==="
        restore_filesystem $FS $SCALE
        mount_fs $FS $MOUNT_DIR
        PG_DATA="$MOUNT_DIR/postgre"
        PGDB="pgbench_s${SCALE}"
        pg_fpw $PG_DATA $FPW
        $PG_BIN/pg_ctl -D $PG_DATA start

        echo "--> Benchmarking $LABEL"
        $PG_BIN/pgbench -c $CLIENT -j $THREADS -T $WARMUP_TIME -P 30 -r $PGDB
        $PG_BIN/pgbench -c $CLIENT -j $THREADS -T $RUNNING_TIME -P 10 -r $PGDB > "$OUT_SUMMARY" 2> "$OUT_LOG"
        sleep 1

        echo "--> Volume Benchmarking $LABEL"
        iostat_start $IOLOG
        $PG_BIN/pgbench -c $CLIENT -j $THREADS -t $TX_COUNT -r $PGDB
        $PG_BIN/psql -d postgres -c "CHECKPOINT;"
        $PG_BIN/pg_ctl -D $PG_DATA stop
        umount_fs $MOUNT_DIR
        iostat_end

        echo "--> Done: $LABEL"
        sleep 600 # Cooling down
      done
    done
    echo "=== FS: $FS Done ==="
    clear_fs $FS $DEVICE
  done
done

echo "=== All benchmarks completed ==="

