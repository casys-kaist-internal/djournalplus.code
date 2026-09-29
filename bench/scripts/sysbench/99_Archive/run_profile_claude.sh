#!/bin/bash
set -o pipefail
die() { echo "[FATAL] $*" >&2; exit 1; }

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
if [ "$MEM_TOTAL_GB" -gt 64 ]; then
    echo "❌ Error: System memory exceeds 64GB limitation."
    echo "   - Current Memory: ~${MEM_TOTAL_GB}GB"
    echo "   Please restrict memory using 'mem=64G' in GRUB settings."
    exit 1
fi
echo "✅ Memory size check passed: ~${MEM_TOTAL_GB}GB"

echo "=================================================="
echo "  Environment check complete. Ready to proceed."
echo "=================================================="

# Or you can just hardcode like below:
FS_GROUPS="ext4"
FS_FPWON="ext4"
FS_FPWOFF="ext4 ext4-tau xfs xfs-tau zfs-16k ext4-dj20"

TRIES=1
SB_TABLES=(16)
THREADS_LIST=(16 32 64)
#THREADS_LIST=(32)
RUNNING_TIME=600
WARMUP_TIME=300
#WORKLOADS=(oltp_write_only)
WORKLOADS=(oltp_update_index oltp_write_only oltp_update_non_index oltp_delete oltp_insert)
# oltp_update_index oltp_update_non_index 
echo "=== Starting sysbench benchamrk: DBMS=$DBMS, TEST=$TEST ==="
echo "=== WORKLOADS=${WORKLOADS[*]}, TABLE_LIST=${SB_TABLES[*]}, THREADS_LIST=${THREADS_LIST[*]} ==="

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/sysbench/$DBMS/$DATE"
mkdir -p "$RESULT_DIR"



collect_ssd_writes() {
    local tag=$1
    # NVMe
    if command -v nvme &>/dev/null; then
        sudo nvme smart-log $TAU_DEVICE 2>/dev/null \
            > "$RESULT_DIR/${LABEL}_smart_${tag}.log" || true
    fi
}

iostat_start() {
    DEVICE_NAME=$(basename "$TAU_DEVICE")
    LOG_FILE=$1
    SEARCH_PATTERN=$(echo "$DEVICE_NAME" | sed -E 's/(nvme[0-9]+)(n[0-9]+)/\1(c[0-9]+)?\2/')

    echo "=== $DEVICE_NAME I/O 상태 ==="
    iostat -dmx 1 | grep -E "Device|$SEARCH_PATTERN"  > "$LOG_FILE" &
    # iostat -dmx 1 "$DEVICE_NAME" > "$LOG_FILE" &
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
  DBNAME="main_t${TABLE}"
  ROWS=$(main_rows_per_table "$TABLE")
  pg_fpw $PG_DATA $FPW
  if [[ "$FPW" == "on" ]]; then
    WALSIZE="16GB"
    pg_wal_max_set $PG_DATA $WALSIZE
  fi

  $PG_BIN/pg_ctl -D $PG_DATA start

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
      --innodb_dedicated_server=1 \
      --innodb_doublewrite=$DBW \
      --performance_schema=ON \
      --performance_schema_instrument='wait/synch/%=ON' &
  wait_for_sock "$MY_SOCK" 60

  # --innodb_buffer_pool_size=4G \
      
  log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

  echo "--> Benchmarking $LABEL warming up"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS \
    --threads=$THREADS --time=$WARMUP_TIME --report-interval=60 run

  # ===== 측정 시작 =====
  collect_ssd_writes "before"

  $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "
    SELECT * FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN (
      'Innodb_dblwr_pages_written','Innodb_dblwr_writes',
      'Innodb_data_written','Innodb_data_read',
      'Innodb_pages_written','Innodb_pages_read',
      'Innodb_buffer_pool_pages_flushed',
      'Innodb_log_writes','Innodb_log_waits',
      'Innodb_os_log_written',
      'Innodb_buffer_pool_wait_free');
  " > "$RESULT_DIR/${LABEL}_innodb_before.log"

  $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "
    TRUNCATE performance_schema.events_waits_summary_global_by_event_name;
  "

  MYSQLD_PID=$(cat "$MY_DATA/mysqld.pid")

  iostat_start $OUT_IOSTAT
  vmstat 1           > "$RESULT_DIR/${LABEL}_vmstat.log" &
  PID_VMSTAT=$!
  pidstat -p $MYSQLD_PID -dru 1 > "$RESULT_DIR/${LABEL}_pidstat.log" &
  PID_PIDSTAT=$!

  # ===== 벤치마크 본 실행 =====
  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS --percentile=99 --histogram="on" \
    --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"

  # ===== 측정 종료 =====
  kill $PID_VMSTAT $PID_PIDSTAT 2>/dev/null || true
  wait $PID_VMSTAT $PID_PIDSTAT 2>/dev/null || true

  $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "
    SELECT * FROM performance_schema.global_status
    WHERE VARIABLE_NAME IN (
      'Innodb_dblwr_pages_written','Innodb_dblwr_writes',
      'Innodb_data_written','Innodb_data_read',
      'Innodb_pages_written','Innodb_pages_read',
      'Innodb_buffer_pool_pages_flushed',
      'Innodb_log_writes','Innodb_log_waits',
      'Innodb_os_log_written',
      'Innodb_buffer_pool_wait_free');
  " > "$RESULT_DIR/${LABEL}_innodb_after.log"

  $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "
    SELECT event_name, count_star,
           ROUND(sum_timer_wait/1e12,3) AS total_sec,
           ROUND(avg_timer_wait/1e9,3) AS avg_ms
    FROM performance_schema.events_waits_summary_global_by_event_name
    WHERE count_star > 0
    ORDER BY sum_timer_wait DESC LIMIT 30;
  " > "$RESULT_DIR/${LABEL}_waits.log"

  collect_ssd_writes "after"

  $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
  sleep 5
  echo "--> Volume Benchmarking $LABEL Done"
  umount_fs $MOUNT_DIR
  iostat_end
  echo "--> All Done: $LABEL"
}

## Start here
# MAIN LOOP
for FS in ${FS_GROUPS[@]}; do
  for TABLE in "${SB_TABLES[@]}"; do
    for WORKLOAD in "${WORKLOADS[@]}"; do
      for THREADS in "${THREADS_LIST[@]}"; do
      echo "=== Setting up FS: $FS in device($DEVICE) with TABLE: $TABLE ==="
      restore_filesystem $FS "s$TABLE" $BACKUP_DIR

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
            OUT_IOSTAT="$RESULT_DIR/${LABEL}.iostat"
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
        clear_fs $FS $DEVICE
      done # THREADS
    done # WORKLOADS
  done # TABLES
  echo "=== FS: $FS Done ==="
done # FS_GROUPS
echo "=== All benchmarks completed ==="
