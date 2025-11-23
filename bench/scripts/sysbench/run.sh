#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql} {1(motivation)|0(evaluation)}"
  exit 1
fi

MOTIV="${2:-0}"  # 1: motivation test, 0: normal test
if [[ "$MOTIV" == "1" ]]; then
  echo "Running motivation test"
else
  echo "Running evaluation test"
fi

# Filesystem groups
declare -A FS_GROUPS

# FS_GROUPS[on]=""
# FS_GROUPS[off]="taujournal"

FS_GROUPS[on]="ext4 xfs"
if [[ "$MODE" == "mysql" ]]; then
  FS_GROUPS[off]="ext4 xfs zfs-16k ext4-dj"
else
  FS_GROUPS[off]="ext4 xfs zfs-8k ext4-dj"
fi

## Motivation test settings
if [[ "$MOTIV" == "1" ]]; then
  TRIES=1
  SCALE_LIST=(2500)
  THREADS_LIST=(32)
  SB_TABLES=32
  RUNNING_TIME=300
  WARMUP_TIME=600
  EVENTS_BASE=1000000 # 1M per clients
  WORKLOADS=(oltp_update_index)
else
  ## Normal test settings
  TRIES=5
  SCALE_LIST=(5000)
  THREADS_LIST=(4 8 16 32 64 128)
  SB_TABLES=32 # fixed
  RUNNING_TIME=600
  WARMUP_TIME=600
  EVENTS_BASE=1000000 # for check IO Volume
  WORKLOADS=(oltp_update_index oltp_insert)
  #WORKLOADS=(oltp_insert oltp_update_index oltp_update_non_index oltp_delete oltp_write_only oltp_read_write)
fi
# bulk_insert << error in postgres

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

run_postgres_benchmark() {
  PG_DATA="$MOUNT_DIR/postgres"
  DBNAME="sbtest_s${SCALE}"
  ROWS=$(sysbench_rows_per_table "$SCALE")
  pg_fpw $PG_DATA $FPW
  if [[ "$FPW" == "on" ]]; then
    if [[ "$MOTIV" == "1" ]]; then  # 10% of database
      WALSIZE="8GB"
    else
      WALSIZE="16GB"
    fi
  else
    if [[ "$MOTIV" == "1" ]]; then
      WALSIZE="1GB"
    else
      WALSIZE="2GB"
    fi
  fi
  pg_wal_max_set $PG_DATA $WALSIZE
  # pg_wal_level $PG_DATA $WALLEVEL
  $PG_BIN/pg_ctl -D $PG_DATA start
  # pg_reset_wal_stats "$PGUSER" "$PG_PORT" "$PG_BIN"
  # pg_reset_io_stats "$PGUSER" "$PG_PORT" "$PG_BIN"

  if [[ "$TEST" == "performance" ]]; then
    log_pg_specs "$OUT_DBSPEC" "$DBNAME" "$TEST"
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
      --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 \
      --percentile=99 --histogram="on" run > "$OUT_LOG"

    $PG_BIN/pg_ctl -D $PG_DATA stop
    umount_fs $MOUNT_DIR
  else
    log_pg_specs "$OUT_DBSPEC" "$DBNAME" "$TEST"
    echo "--> Volume Benchmarking $LABEL"
    iostat_start $OUT_IOSTAT
    sysbench $WORKLOAD \
      --db-driver=pgsql --auto_inc=on \
      --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
      --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
      --tables=$SB_TABLES --table-size=$ROWS  --time=0 \
      --threads=$THREADS --events=$EVENTS run >> "$OUT_LOG"

    $PG_BIN/psql -d postgres -c "CHECKPOINT;"
    $PG_BIN/pg_ctl -D $PG_DATA stop
    umount_fs $MOUNT_DIR
    iostat_end
  fi
  sleep 30 # Cooling down
}

run_mysql_benchmark() {
  MY_DATA="$MOUNT_DIR/mysql"
  MY_SOCK="$MY_DATA/mysql.sock"
  DBNAME="sbtest_s${SCALE}"
  ROWS=$(sysbench_rows_per_table "$SCALE")
  if [[ "$FPW" == "on" ]]; then
    DBW=1
  else
    DBW=0
  fi

  if [[ "$MOTIV" == "1" ]]; then
    INNODB_BP_SIZE="70G"
    INNODB_LOG_SIZE="2G"
  else
    INNODB_BP_SIZE="140G"
    INNODB_LOG_SIZE="4G"
  fi

  echo "[*] Start mysqld"
  $MYSQL_BIN/mysqld \
      --datadir="$MY_DATA" \
      --socket="$MY_SOCK" \
      --port="$MYSQL_PORT" \
      --pid-file="$MY_DATA/mysqld.pid" \
      --bind-address=127.0.0.1 \
      --skip-networking=0 \
      --innodb_buffer_pool_size=$INNODB_BP_SIZE \
      --innodb_redo_log_capacity=$INNODB_LOG_SIZE \
      --disable-log-bin \
      --log-error="$MY_DATA/mysqld.err" \
      --innodb-doublewrite=$DBW &
  wait_for_sock "$MY_SOCK" 60

  log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

  if [[ "$TEST" == "performance" ]]; then
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
      --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 run > "$OUT_LOG"

    $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
    sleep 5
    echo "--> Volume Benchmarking $LABEL Done"
    umount_fs $MOUNT_DIR
  else
    echo "--> Volume Benchmarking $LABEL"
    iostat_start $OUT_IOSTAT
    sysbench $WORKLOAD \
      --db-driver=mysql \
      --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
      --tables=$SB_TABLES --table-size=$ROWS --time=0 \
      --threads=$THREADS --events=$EVENTS run >> "$OUT_LOG"

    $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=1; FLUSH LOGS;"
    $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
    sleep 5
    echo "--> Volume Benchmarking $LABEL Done"
    umount_fs $MOUNT_DIR
    iostat_end

  fi

  echo "--> All Done: $LABEL"
}

## Start here
# MAIN LOOP
for TEST in performance volume; do
  for FPW in on off; do
    for FS in ${FS_GROUPS[$FPW]}; do
      for SCALE in "${SCALE_LIST[@]}"; do
        for WORKLOAD in "${WORKLOADS[@]}"; do
          for THREADS in "${THREADS_LIST[@]}"; do
            for (( R=1; R<=$TRIES; R++ )); do
              LABEL="${MODE}_${WORKLOAD}_${FS}_fpw_${FPW}_s${SCALE}_c${THREADS}_r${R}"
              OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
              OUT_LOG="$RESULT_DIR/${LABEL}.log"
              OUT_IOSTAT="$RESULT_DIR/${LABEL}.iostat"
              EVENTS=$((EVENTS_BASE * THREADS))

              #warming_up_ssd
              echo "=== Setting up FS: $FS (FPW=$FPW) in device($DEVICE) ==="
              restore_filesystem $FS "s$SCALE" $BACKUP_DIR
              mount_fs $FS $MOUNT_DIR
              case "$MODE" in
                postgres)
                  run_postgres_benchmark
                ;;
                mysql)
                  run_mysql_benchmark
                ;;
              esac
              log_ssd_state $OUT_DBSPEC
            done
          done
        done
      done
      echo "=== FS: $FS Done ==="
      if [ "$FS" == "zfs" ] || [[ "$FS" == zfs-* ]]; then
        clear_fs $FS $DEVICE
      fi
    done
  done
done
echo "=== All benchmarks completed ==="

