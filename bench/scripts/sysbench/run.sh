#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

# DB_TUNING="no" # Default
# DB_TUNING="min"
# SCALE_LIST=(500)
# THREADS_LIST=(8)
# SB_TABLES=32 # fixed
# RUNNING_TIME=10
# WARMUP_TIME=10
# EVENTS=1000 # for check IO Volume

## Motivation test settings
SCALE_LIST=(2500)
THREADS_LIST=(32)
SB_TABLES=32 # fixed
RUNNING_TIME=300
WARMUP_TIME=600
EVENTS_BASE=1000000 # 1M --> 32M for total
WORKLOADS=(oltp_update_index)

# SCALE_LIST=(5000)
# THREADS_LIST=(16 32 64)
# SB_TABLES=32 # fixed
# RUNNING_TIME=1800
# WARMUP_TIME=600
# EVENTS_BASE=1000000 # for check IO Volume


# Filesystem groups
declare -A FS_GROUPS

# FS_GROUPS[on]=""
# FS_GROUPS[off]="taujournal"

FS_GROUPS[on]=""
FS_GROUPS[off]="xfs-cow"

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

## Start here
# MAIN LOOP
for FPW in on off; do
  for FS in ${FS_GROUPS[$FPW]}; do
    for SCALE in "${SCALE_LIST[@]}"; do
      for WORKLOAD in "${WORKLOADS[@]}"; do
        for THREADS in "${THREADS_LIST[@]}"; do
          LABEL="${MODE}_${WORKLOAD}_${FS}_fpw_${FPW}_s${SCALE}_c${THREADS}"
          OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
          OUT_ERR="$RESULT_DIR/${LABEL}.error"
          OUT_LOG="$RESULT_DIR/${LABEL}.log"
          OUT_IOLOG="$RESULT_DIR/${LABEL}_iostat.result"
          IOLOG="$RESULT_DIR/${LABEL}_iostat.log"
          EVENTS=$((EVENTS_BASE * THREADS))

          echo "=== Setting up FS: $FS (FPW=$FPW) in device($DEVICE) ==="
          restore_filesystem $FS "s$SCALE" $BACKUP_DIR
          mount_fs $FS $MOUNT_DIR
          case "$MODE" in
            postgres)
              PG_DATA="$MOUNT_DIR/postgres"
              DBNAME="sbtest_s${SCALE}"
              ROWS=$(sysbench_rows_per_table "$SCALE")
              pg_fpw $PG_DATA $FPW
              $PG_BIN/pg_ctl -D $PG_DATA start

              log_pg_specs "$OUT_DBSPEC" "$DBNAME"

              echo "--> Benchmarking $LABEL warming up"
              sysbench $WORKLOAD \
                --db-driver=pgsql --auto_inc=on \
                --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
                --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
                --tables=$SB_TABLES --table-size=$ROWS \
                --threads=$THREADS --time=$WARMUP_TIME run

              echo "--> Benchmarking $LABEL"
              sysbench $WORKLOAD \
                --db-driver=pgsql --auto_inc=on \
                --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
                --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
                --tables=$SB_TABLES --table-size=$ROWS \
                --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 run > "$OUT_LOG" 2> "$OUT_ERR"

              echo "--> Volume Benchmarking $LABEL"
              iostat_start $IOLOG
              sysbench $WORKLOAD \
                --db-driver=pgsql --auto_inc=on \
                --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
                --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
                --tables=$SB_TABLES --table-size=$ROWS  --time=0 \
                --threads=$THREADS --events=$EVENTS run > "$OUT_IOLOG"

              $PG_BIN/psql -d postgres -c "CHECKPOINT;"
              $PG_BIN/pg_ctl -D $PG_DATA stop
              umount_fs $MOUNT_DIR
              iostat_end

            ;;
            mysql)
              MY_DATA="$MOUNT_DIR/mysql"
              MY_SOCK="$MY_DATA/mysql.sock"
              DBNAME="sbtest_s${SCALE}"
              ROWS=$(sysbench_rows_per_table "$SCALE")
              if [[ "$FPW" == "on" ]]; then
                DBW=1
              else
                DBW=0
              fi

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

              log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

              echo "--> Benchmarking $LABEL warming up"
              sysbench $WORKLOAD \
                --db-driver=mysql \
                --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
                --tables=$SB_TABLES --table-size=$ROWS \
                --threads=$THREADS --time=$WARMUP_TIME --report-interval=60 run

              echo "--> Benchmarking $LABEL"
              sysbench $WORKLOAD \
                --db-driver=mysql \
                --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
                --tables=$SB_TABLES --table-size=$ROWS \
                --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 run > "$OUT_LOG" 2> "$OUT_ERR"

              echo "--> Volume Benchmarking $LABEL"
              iostat_start $IOLOG
              sysbench $WORKLOAD \
                --db-driver=mysql \
                --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
                --tables=$SB_TABLES --table-size=$ROWS --time=0 \
                --threads=$THREADS --events=$EVENTS run

              $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=1; FLUSH LOGS;"
              $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown

              echo "--> Volume Benchmarking $LABEL Done"
              umount_fs $MOUNT_DIR
              iostat_end

              echo "--> All Done: $LABEL"
            ;;
          esac
          done
          sleep 10  # Cooling down
        done
    done
    echo "=== FS: $FS Done ==="
    # clear_fs $FS $DEVICE
  done
done

echo "=== All benchmarks completed ==="

