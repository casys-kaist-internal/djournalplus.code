#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

# DB_TUNING="no" # Default
# DB_TUNING="min"

# scale=1000 ≈ 16 GB
SCALE_LIST=(1000)
THREADS_LIST=(8)
SB_TABLES=32 # fixed
RUNNING_TIME=30
WARMUP_TIME=10
EVENTS=1000 # for check IO Volume

# scale=1000 ≈ 16 GB
# SCALE_LIST=(1000)
# CLIENT_LIST=(16 32 64)
# SB_TABLES=32 # fixed
# RUNNING_TIME=1800
# WARMUP_TIME=600
# TX_COUNT=100000 # for check IO Volume


# Filesystem groups
declare -A FS_GROUPS

FS_GROUPS[on]=""
FS_GROUPS[off]="ext4"

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$MODE
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/sysbench/$MODE/$DATE"
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
      for WORKLOAD in oltp_update_index oltp_insert; do
        for THREADS in "${THREADS_LIST[@]}"; do
          LABEL="${MODE}_${WORKLOAD}_${FS}_fpw_${FPW}_s${SCALE}_c${THREADS}"
          OUT_SUMMARY="$RESULT_DIR/${LABEL}.summary"
          OUT_LOG="$RESULT_DIR/${LABEL}.log"
          IOLOG="$RESULT_DIR/${LABEL}_iostat.log"

          echo "=== Setting up FS: $FS (FPW=$FPW) in device($DEVICE) ==="
          # restore_filesystem $FS $SCALE
          mount_fs $FS $MOUNT_DIR
          case "$MODE" in
            postgres)
              # PG_DATA="$MOUNT_DIR/postgre"
              # PGDB="pgbench_s${SCALE}"
              # pg_fpw $PG_DATA $FPW
              # $PG_BIN/pg_ctl -D $PG_DATA start

              # echo "--> Benchmarking $LABEL"
              # $PG_BIN/pgbench -c $CLIENT -j $THREADS -T $WARMUP_TIME -P 30 -r $PGDB
              # $PG_BIN/pgbench -c $CLIENT -j $THREADS -T $RUNNING_TIME -P 10 -r $PGDB > "$OUT_SUMMARY" 2> "$OUT_LOG"
              # sleep 1

              # echo "--> Volume Benchmarking $LABEL"
              # iostat_start $IOLOG
              # $PG_BIN/pgbench -c $CLIENT -j $THREADS -t $TX_COUNT -r $PGDB
              # $PG_BIN/psql -d postgres -c "CHECKPOINT;"
              # $PG_BIN/pg_ctl -D $PG_DATA stop
              # umount_fs $MOUNT_DIR
              # iostat_end

            ;;
            mysql)
              MY_DATA="$MOUNT_DIR/mysql"
              MY_SOCK="$MY_DATA/mysql.sock"
              DBNAME="sbtest_s${SCALE}"
              ROWS=$(rows_per_table "$SCALE")
              DBW=$(FPW="on" && echo "1" || echo "0")

              echo "[*] Start mysqld"
              $MYSQL_BIN/mysqld \
                  --datadir="$MY_DATA" \
                  --socket="$MY_SOCK" \
                  --port="$MYSQL_PORT" \
                  --pid-file="$MY_DATA/mysqld.pid" \
                  --bind-address=127.0.0.1 \
                  --skip-networking=0 \
                  --log-error="$MY_DATA/mysqld.err" \
                  --innodb-doublewrite=$DBW &
              wait_for_sock "$MY_SOCK" 60

              echo "--> Benchmarking $LABEL warming up"
              sysbench $WORKLOAD \
                --db-driver=mysql \
                --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
                --tables=$SB_TABLES --table-size=$ROWS \
                --threads=$THREADS --time=$WARMUP_TIME run

              echo "--> Benchmarking $LABEL"
              sysbench $WORKLOAD \
                --db-driver=mysql \
                --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
                --tables=$SB_TABLES --table-size=$ROWS \
                --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 run > "$OUT_SUMMARY" 2> "$OUT_LOG"

              echo "--> Volume Benchmarking $LABEL"
              iostat_start $IOLOG
              sysbench $WORKLOAD \
                --db-driver=mysql \
                --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
                --tables=$SB_TABLES --table-size=$ROWS \
                --threads=$THREADS --events=$EVENTS run

              $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
              $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown

              umount_fs $MOUNT_DIR
              iostat_end

              echo "--> Done: $LABEL"
            ;;
          esac
          done
          sleep 10 # Cooling down
        done
    done
    echo "=== FS: $FS Done ==="
    # clear_fs $FS $DEVICE
  done
done

echo "=== All benchmarks completed ==="

