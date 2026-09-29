#!/bin/bash
set -e

DBMS="${1:-}"  # postgres | mysql
if [[ "$DBMS" != "postgres" && "$DBMS" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

echo "=================================================="
echo "  TauJournal Motivation Test Environment Check"
echo "=================================================="

KERNEL_VERSION=$(uname -r)

if [[ ! "$KERNEL_VERSION" == *"6.8.0"* ]]; then
    echo "❌ Error: Invalid Kernel Version."
    echo "   - Expected: *6.8.0*"
    echo "   - Current : $KERNEL_VERSION"
    echo "   Please boot with the correct kernel for TauJournal."
    exit 1
fi
echo "✅ Kernel version check passed: $KERNEL_VERSION"

# Main test use only 64GB memory
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
# if [ "$MEM_TOTAL_GB" -gt 64 ]; then
#     echo "❌ Error: System memory exceeds 64GB limitation."
#     echo "   - Current Memory: ~${MEM_TOTAL_GB}GB"
#     echo "   Please restrict memory using 'mem=64G' in GRUB settings."
#     exit 1
# fi
echo "✅ Memory size check passed: ~${MEM_TOTAL_GB}GB"

echo "=================================================="
echo "  Environment check complete. Ready to proceed."
echo "=================================================="

# Or you can just hardcode like below:
FS_GROUPS="ext4"
FS_FPWON="ext4 xfs"
FS_FPWOFF="ext4-tau xfs xfs-tau zfs-16k ext4-dj20"

TRIES=1
SB_TABLES=(16)
#THREADS_LIST=(1 8 16 32 64)
THREADS_LIST=(64)
RUNNING_TIME=300
WARMUP_TIME=300
WORKLOADS=(oltp_write_only)
# WORKLOADS=(oltp_update_non_index  oltp_insert oltp_write_only)
#WORKLOADS=(oltp_update_index oltp_update_non_index oltp_write_only oltp_delete oltp_insert)

echo "=== Starting sysbench benchamrk: DBMS=$DBMS, TEST=$TEST ==="
echo "=== WORKLOADS=${WORKLOADS[*]}, TABLE_LIST=${SB_TABLES[*]}, THREADS_LIST=${THREADS_LIST[*]} ==="

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/sysbench/$DBMS/$DATE"
mkdir -p "$RESULT_DIR"

run_postgres_benchmark() {
  PG_DATA="$MOUNT_DIR/postgres"
  DBNAME="main_t${TABLE}"
  ROWS=$(main_rows_per_table "$TABLE")
  pg_fpw $PG_DATA $FPW
  if [[ "$FPW" == "on" ]]; then
    WALSIZE="16GB"
    pg_wal_max_set $PG_DATA $WALSIZE
  fi

  # pg_wal_level $PG_DATA $WALLEVEL # not used
  $PG_BIN/pg_ctl -D $PG_DATA start
  # pg_reset_wal_stats "$PGUSER" "$PG_PORT" "$PG_BIN" # not used
  # pg_reset_io_stats "$PGUSER" "$PG_PORT" "$PG_BIN" # not used

  log_pg_specs "$OUT_DBSPEC" "$DBNAME" "$TEST"
  echo "--> Benchmarking $LABEL warming up"
  sysbench $WORKLOAD \
      --db-driver=pgsql --auto_inc=on \
      --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
      --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
      --tables=$TABLE --table-size=$ROWS \
      --threads=$THREADS --time=$WARMUP_TIME run

  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
      --db-driver=pgsql --auto_inc=on \
      --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
      --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
      --tables=$TABLE --table-size=$ROWS \
      --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 \
      --percentile=99 --histogram="on" run > "$OUT_LOG"

  $PG_BIN/pg_ctl -D $PG_DATA stop
  umount_fs $MOUNT_DIR
}

run_mysql_benchmark() {
  MY_DATA="$MOUNT_DIR/mysql_data"
  MY_SOCK="$MY_DATA/mysql.sock"
  DBNAME="main_t${TABLE}"
  ROWS=$(main_rows_per_table "$TABLE")
  if [[ "$FPW" == "on" ]]; then
    DBW=1
  else
    DBW=0
  fi

  if [[ "$FS" == "zfs-16k" ]]; then
    MY_LOGS="$MOUNT_DIR/mysql_logs"
    MY_BINLOGS="$MOUNT_DIR/mysql_binlogs"
    sudo chown -R $MYUSER:$MYUSER $MY_LOGS
    sudo chown -R $MYUSER:$MYUSER $MY_BINLOGS
  else
    MY_LOGS=$MY_DATA
    MY_BINLOGS=$MY_DATA
  fi

  echo "[*] Start mysqld"
  $MYSQL_BIN/mysqld \
      --datadir="$MY_DATA" \
      --socket="$MY_SOCK" \
      --port="$MYSQL_PORT" \
      --pid-file="$MY_DATA/mysqld.pid" \
      --bind-address=127.0.0.1 \
      --skip-networking=0 \
      --innodb_doublewrite=$DBW &
  wait_for_sock "$MY_SOCK" 60


      # --innodb_buffer_pool_size=4G \
    # --innodb_flush_method=fsync \
    # --log-error="$MY_DATA/mysqld.err" \
    # --innodb_dedicated_server=1 \
    # --disable-log-bin \
    # --innodb_redo_log_capacity=$INNODB_LOG_SIZE \

  log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

  echo "--> Benchmarking $LABEL warming up"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS \
    --threads=$THREADS --time=$WARMUP_TIME --report-interval=10 run

  sudo sh -c 'echo "Benchmarking start" > /dev/kmsg'
  # sudo sh -c "echo 1 > /sys/kernel/debug/tauperf/enable"

  # echo "--> Benchmarking $LABEL"
  # sysbench $WORKLOAD \
  #   --db-driver=mysql \
  #   --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
  #   --tables=$TABLE --table-size=$ROWS --percentile=99 --histogram="on" \
  #   --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"

  # sudo sh -c "echo 0 > /sys/kernel/debug/tauperf/enable"
  # $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown

echo "--> Benchmarking $LABEL"

  # 1. 백그라운드에서 10초마다 INNODB STATUS 수집 (체크포인트 및 락 상태 모니터링)
  while true; do
      date +"%Y-%m-%d %H:%M:%S" >> "$RESULT_DIR/innodb_status_$LABEL.log"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SHOW ENGINE INNODB STATUS\G" >> "$RESULT_DIR/innodb_status_$LABEL.log"
      sleep 10
  done &
  MONITOR_PID=$!

  # sysbench 실행
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS --percentile=99 --histogram="on" \
    --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"

  # 백그라운드 모니터링 프로세스 종료
  kill $MONITOR_PID
  # sudo sh -c "echo 0 > /sys/kernel/debug/tauperf/enable"

  # 2. 셧다운 전 Performance Schema 덤프 (WAL 커밋 지연 및 누적 락 대기 시간 확인)
  # 참고: MySQL 설정(my.cnf)에서 performance_schema=ON 이어야 함
  $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "
    SELECT EVENT_NAME, 
           COUNT_STAR, 
           SUM_TIMER_WAIT/1000000000000 AS SUM_SEC, 
           AVG_TIMER_WAIT/1000000000 AS AVG_MS 
    FROM performance_schema.events_waits_summary_global_by_event_name 
    WHERE EVENT_NAME LIKE 'wait/io/file/innodb/innodb_log_file%' 
       OR EVENT_NAME LIKE 'wait/synch/%/innodb/%' 
    ORDER BY SUM_TIMER_WAIT DESC 
    LIMIT 20;" > "$RESULT_DIR/perf_schema_$LABEL.log"

  $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown

  sleep 5
  echo "--> Volume Benchmarking $LABEL Done"
  umount_fs $MOUNT_DIR
  echo "--> All Done: $LABEL"
}


## Start here
# MAIN LOOP
for FS in ${FS_GROUPS[@]}; do
  for TABLE in "${SB_TABLES[@]}"; do
    for WORKLOAD in "${WORKLOADS[@]}"; do
      for THREADS in "${THREADS_LIST[@]}"; do
      echo "=== Setting up FS: $FS in device($DEVICE) with TABLE: $TABLE ==="
      #restore_filesystem $FS "s$TABLE" $BACKUP_DIR

      for FPW in on off; do
        if [[ "$FPW" == "on" ]]; then
          [[ ! " $FS_FPWON " =~ " $FS " ]] && continue
        elif [[ "$FPW" == "off" ]]; then
          [[ ! " $FS_FPWOFF " =~ " $FS " ]] && continue
        fi
        echo "Executing: FS=$FS, FPW=$FPW"
          for (( R=1; R<=$TRIES; R++ )); do
            LABEL="${DBMS}_${WORKLOAD}_${FS}_fpw_${FPW}_t${TABLE}_c${THREADS}_r${R}"
            OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
            OUT_LOG="$RESULT_DIR/${LABEL}.log"
            # OUT_IOSTAT="$RESULT_DIR/${LABEL}.iostat"
            # EVENTS=$((EVENTS_BASE * THREADS))

            mount_fs $FS $MOUNT_DIR
            case "$DBMS" in
              postgres)
                run_postgres_benchmark
              ;;
              mysql)
                run_mysql_benchmark
              ;;
            esac
            log_ssd_state $OUT_DBSPEC
          done
        done # FPW
        # clear_fs $FS $DEVICE
      done # THREADS
    done # WORKLOADS
  done # TABLES
  echo "=== FS: $FS Done ==="
done # FS_GROUPS
echo "=== All benchmarks completed ==="
