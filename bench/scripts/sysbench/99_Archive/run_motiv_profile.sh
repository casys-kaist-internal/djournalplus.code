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

# Motivation test use only 32GB memory
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
if [ "$MEM_TOTAL_GB" -gt 32 ]; then
    echo "❌ Error: System memory exceeds 32GB limitation."
    echo "   - Current Memory: ~${MEM_TOTAL_GB}GB"
    echo "   Please restrict memory using 'mem=32G' in GRUB settings."
    exit 1
fi
echo "✅ Memory size check passed: ~${MEM_TOTAL_GB}GB"

echo "=================================================="
echo "  Environment check complete. Ready to proceed."
echo "=================================================="

# Or you can just hardcode like below:
#FS_GROUPS="ext4 zfs xfs ext4-dj"
FS_GROUPS="ext4"
FS_FPWON="ext4 xfs"
FS_FPWOFF="zfs-16k"
# FS_FPWOFF="ext4 xfs zfs-16k ext4-dj"

TRIES=1
SB_TABLES=(8)
# THREADS_LIST=(1 8 16 32 64)
THREADS_LIST=(32)
RUNNING_TIME=300
WARMUP_TIME=600
WORKLOADS=(oltp_insert)

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
  DBNAME="motiv_t${TABLE}"
  ROWS=$(motivation_rows_per_table "$TABLE")
  pg_fpw $PG_DATA $FPW
  if [[ "$FPW" == "on" ]]; then
    WALSIZE="8GB"
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
  DBNAME="motiv_t${TABLE}"
  ROWS=$(motivation_rows_per_table "$TABLE")
  if [[ "$FPW" == "on" ]]; then
    DBW=1
  else
    DBW=0
  fi

  # if [[ "$FS" == "zfs-16k" ]]; then
  #   MY_LOGS="$MOUNT_DIR/mysql_logs"
  #   MY_BINLOGS="$MOUNT_DIR/mysql_binlogs"
  #   sudo chown -R $MYUSER:$MYUSER $MY_LOGS
  #   sudo chown -R $MYUSER:$MYUSER $MY_BINLOGS
  # else
  #   MY_LOGS="$MY_DATA/logs"
  #   MY_BINLOGS="$MY_DATA/binlogs"
  # fi

  echo "[*] Start mysqld"
  $MYSQL_BIN/mysqld \
      --datadir="$MY_DATA" \
      --socket="$MY_SOCK" \
      --port="$MYSQL_PORT" \
      --pid-file="$MY_DATA/mysqld.pid" \
      --bind-address=127.0.0.1 \
      --skip-networking=0 \
      --innodb-doublewrite=$DBW &
  wait_for_sock "$MY_SOCK" 60

  log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

  echo "--> Benchmarking $LABEL warming up"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS \
    --threads=$THREADS --time=$WARMUP_TIME --report-interval=60 run

  # ==========================================
  # 🔍 프로파일링 시작 (본 테스트 동안 백그라운드 실행)
  # ==========================================
  echo "--> Starting Profilers in the background..."
  
  # 1. OS I/O 프로파일링 (1초 단위로 디스크 상태 기록)
  # 결과 파일명은 환경에 맞게 수정하세요.
  # iostat -dx 1 $RUNNING_TIME > "$RESULT_DIR/iostat_profile_${THREADS}thr.log" &
  # IOSTAT_PID=$!

  # 2. MySQL 내부 경합 및 상태 프로파일링 (10초 단위로 기록)
  (
    while true; do
      echo "========================================"
      date
      echo "[InnoDB Doublewrite & Fsync Status]"
      mysql -u root --socket="$MY_SOCK" -e "SHOW GLOBAL STATUS LIKE 'Innodb_dblwr%';"
      mysql -u root --socket="$MY_SOCK" -e "SHOW GLOBAL STATUS LIKE 'Innodb_data_fsyncs';"
      
      echo "[Performance Schema Wait Events (Top 10)]"
      mysql -u root --socket="$MY_SOCK" -e "
        SELECT EVENT_NAME, COUNT_STAR, 
               ROUND(SUM_TIMER_WAIT/1000000000000, 4) AS SUM_WAIT_SEC, 
               ROUND(AVG_TIMER_WAIT/1000000000, 4) AS AVG_WAIT_MS
        FROM performance_schema.events_waits_summary_global_by_event_name
        WHERE EVENT_NAME LIKE '%dblwr%' 
           OR EVENT_NAME LIKE '%fsync%' 
           OR EVENT_NAME LIKE '%flush%'
        ORDER BY SUM_TIMER_WAIT DESC 
        LIMIT 10;"
      sleep 10
    done
  ) > "$RESULT_DIR/mysql_profile_${FS}_${THREADS}thr.log" &


# 2. MySQL 내부 경합 및 상태 프로파일링 (10초 단위로 기록)
  (
    while true; do
      echo "========================================"
      date
      echo "[InnoDB Doublewrite & Fsync Status]"
      mysql -u root --socket="$MY_SOCK" -e "SHOW GLOBAL STATUS LIKE 'Innodb_dblwr%';"
      mysql -u root --socket="$MY_SOCK" -e "SHOW GLOBAL STATUS LIKE 'Innodb_data_fsyncs';"
      
      # 💡 수정됨: 특정 이름으로 필터링하지 않고, 전체 이벤트 중 진짜 병목인 Top 10 추출
      echo "[Performance Schema Wait Events (Top 10 - All Active Waits)]"
      mysql -u root --socket="$MY_SOCK" -e "
        SELECT EVENT_NAME, COUNT_STAR, 
               ROUND(SUM_TIMER_WAIT/1000000000000, 4) AS SUM_WAIT_SEC, 
               ROUND(AVG_TIMER_WAIT/1000000000, 4) AS AVG_WAIT_MS
        FROM performance_schema.events_waits_summary_global_by_event_name
        WHERE SUM_TIMER_WAIT > 0 
          AND EVENT_NAME NOT LIKE '%idle%' 
          AND EVENT_NAME NOT LIKE '%/socket/%' 
          AND EVENT_NAME NOT LIKE '%/sleep/%'
        ORDER BY SUM_TIMER_WAIT DESC 
        LIMIT 10;"
        
      # 💡 추가됨: InnoDB 내부 락(Mutex, RWLock, Cond) 경합만 따로 모아서 Top 5 추출
      echo "[InnoDB Mutex & RWLock Contention (Top 5)]"
      mysql -u root --socket="$MY_SOCK" -e "
        SELECT EVENT_NAME, COUNT_STAR, 
               ROUND(SUM_TIMER_WAIT/1000000000000, 4) AS SUM_WAIT_SEC
        FROM performance_schema.events_waits_summary_global_by_event_name
        WHERE EVENT_NAME LIKE 'wait/synch/%/innodb/%'
        ORDER BY SUM_TIMER_WAIT DESC 
        LIMIT 5;"
      sleep 10
    done
  ) > "$RESULT_DIR/mysql_profile_${FS}_${THREADS}thr.log" &

  MYSQL_PROF_PID=$!

  # # ZFS TXG 프로파일링 (백그라운드)
  # (
  #   echo "time, txg, state, ndirty, nwritten, stime(sync_time_ns)"
  #   while true; do
  #     # 시간 출력 (개행 없이)
  #     echo -n "$(date +"%T")  "
      
  #     # 상태가 ' C ' (Committed)인 줄만 필터링한 후 가장 마지막 줄 가져오기
  #     cat /proc/spl/kstat/zfs/zfspool/txgs | grep ' C ' | tail -n 1
      
  #     sleep 1
  #   done
  # ) > "zfs_txg_profile_${THREADS}thr.log" &
  # ZFS_TXG_PID=$!

  # zpool iostat -l zfspool 1 > "zpool_latency_${THREADS}thr.log" &
  # ZPOOL_PID=$!
  # # ==========================================

  MYSQL_PID=$(pgrep -x mysqld | head -n 1)
  if [ -z "$MYSQL_PID" ]; then
    echo "⚠️ Warning: mysqld PID를 찾을 수 없어 eBPF 프로파일링을 건너뜁니다."
  else
    echo "--> Found mysqld PID: $MYSQL_PID. Starting eBPF tools..."

    # 3. bpftrace: fsync 지연 시간 히스토그램 (백그라운드 유지)
    # 스크립트 종료 시 kill $BPFTRACE_PID 로 종료해 주어야 히스토그램이 로그에 출력됩니다.
    sudo bpftrace -e "
    tracepoint:syscalls:sys_enter_fsync /pid == $MYSQL_PID/ { 
        @start[tid] = nsecs; 
    } 
    tracepoint:syscalls:sys_exit_fsync /@start[tid]/ { 
        @fsync_latency_ns = hist(nsecs - @start[tid]); 
        delete(@start[tid]); 
    }" > "$RESULT_DIR/bpftrace_fsync_${THREADS}thr.log" &
    BPFTRACE_PID=$!

    # 4. offcputime: 컨텍스트 스위칭 및 블로킹 원인 콜스택 추적
    # RUNNING_TIME 동안 수집 후 자동 종료됩니다.
    sudo offcputime-bpfcc -p $MYSQL_PID -K $RUNNING_TIME > "$RESULT_DIR/offcputime_${THREADS}thr.log" &
    OFFCPU_PID=$!
  fi

  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS --percentile=99 --histogram="on" \
    --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"

  # ==========================================
  # 🛑 프로파일링 종료
  # ==========================================
  echo "--> Stopping Profilers..."
  kill $MYSQL_PROF_PID 2>/dev/null

  # 1. bpftrace 종료: 반드시 SIGINT(-2)를 보내야 히스토그램 결과가 파일에 기록됩니다.
  # sudo로 실행했으므로 끌 때도 sudo가 필요할 수 있습니다.
  if [ -n "$BPFTRACE_PID" ]; then
    echo "Stopping bpftrace (PID: $BPFTRACE_PID)..."
    sudo kill -2 $BPFTRACE_PID 2>/dev/null
  fi

  # 2. offcputime 종료: -K 옵션으로 시간을 주었다면 자동 종료되지만, 
  # 혹시 살아있을 경우를 대비해 안전하게 종료 신호를 보냅니다.
  if [ -n "$OFFCPU_PID" ]; then
    echo "Stopping offcputime (PID: $OFFCPU_PID)..."
    sudo kill -2 $OFFCPU_PID 2>/dev/null
  fi

  # kill $ZFS_TXG_PID 2>/dev/null
  # kill $ZPOOL_PID
  # wait $IOSTAT_PID 2>/dev/null

  sleep 1


  $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
  sleep 5
  echo "--> Volume Benchmarking $LABEL Done"
  umount_fs $MOUNT_DIR
  # fi
  echo "--> All Done: $LABEL"
}

create_database() {
    FS=$1
    DBMS=$2
    TABLE=$3
    echo "=== Setting up FS: $FS in device($DEVICE) ==="
    do_mkfs $FS $DEVICE
    mount_fs $FS $MOUNT_DIR

    case "$DBMS" in
      postgres)
      DBNAME="motiv_t${TABLE}"
      ROWS=$(motivation_rows_per_table "$TABLE")

      PG_DATA="$MOUNT_DIR/postgres"
      sudo mkdir -p $PG_DATA
      sudo chown -R $PGUSER:$PGUSER $PG_DATA
      $PG_BIN/initdb -D $PG_DATA
      pg_fpw $PG_DATA "off"
      $PG_BIN/pg_ctl -D $PG_DATA start

      echo "[*] Create DB & sysbench prepare"
      $PG_BIN/createdb $DBNAME

      sysbench --db-driver=pgsql \
          --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
          --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" --threads=32  \
          oltp_read_write --tables="$TABLE" --table-size="$ROWS" prepare

      $PG_BIN/psql -d "$DBNAME"  -c "ANALYZE;"
      $PG_BIN/psql -d postgres -c "CHECKPOINT;"

      echo "[*] Stop PostgreSQL"
      $PG_BIN/pg_ctl -D $PG_DATA stop
      ;;
      mysql)
      MY_DATA="$MOUNT_DIR/mysql_data"
      MY_SOCK="$MY_DATA/mysql.sock"
      DBNAME="motiv_t${TABLE}"
      ROWS=$(motivation_rows_per_table "$TABLE")

      echo "TABLES: $TABLE, ROWS per table: $ROWS"

      echo "[*] Initialize MySQL datadir"
      sudo mkdir -p $MY_DATA
      sudo chown -R $MYUSER:$MYUSER $MY_DATA
      echo "[*] Initialize MySQL"
      $MYSQL_BIN/mysqld --initialize-insecure --datadir="$MY_DATA"

      echo "[*] Start mysqld"
      $MYSQL_BIN/mysqld \
          --datadir="$MY_DATA" \
          --socket="$MY_SOCK" \
          --port="$MYSQL_PORT" \
          --pid-file="$MY_DATA/mysqld.pid" \
          --bind-address=127.0.0.1 \
          --skip-networking=0 \
          --innodb-doublewrite=0 \
          --innodb_flush_log_at_trx_commit=0 \
          --sync_binlog=0 \
          --log-error="$MY_DATA/mysqld.err" &

      wait_for_sock "$MY_SOCK" 60

      # This option can reduce prepare time, but performance may vary.
      # Not using this option when evaluating performance.
      # --sync_binlog=0 \
      # --innodb_buffer_pool_size=140G \
      # --innodb_redo_log_capacity=10G \
      # --innodb_flush_log_at_trx_commit=0 \
      # Also, use threads=32 for sysbench prepare for faster loading.

      echo "[*] Create DB & sysbench prepare"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
      sysbench --db-driver=mysql \
          --mysql-user=root --mysql-socket="$MY_SOCK" --mysql-db="$DBNAME" \
          oltp_read_write --threads=32 --tables="$TABLE" --table-size="$ROWS" prepare

      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
      $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
      ;;
    esac
    sleep 1
    echo "[*] Unmount before imaging"
    umount_fs "$MOUNT_DIR"
    sleep 1
    drop_caches
    echo "[✓] Done: $OUT_IMG"
}


## Start here
# MAIN LOOP
# for FS in ${FS_GROUPS[@]}; do
#   for TABLE in "${SB_TABLES[@]}"; do
#     echo "=== Setting up FS: $FS in device($DEVICE) with TABLE: $TABLE ==="
#     create_database $FS $DBMS $TABLE
#     for FPW in on off; do
#       if [[ "$FPW" == "on" ]]; then
#         [[ ! " $FS_FPWON " =~ " $FS " ]] && continue
#       elif [[ "$FPW" == "off" ]]; then
#         [[ ! " $FS_FPWOFF " =~ " $FS " ]] && continue
#       fi
#       echo "Executing: FS=$FS, FPW=$FPW"
#       for WORKLOAD in "${WORKLOADS[@]}"; do
#         for THREADS in "${THREADS_LIST[@]}"; do
#           for (( R=1; R<=$TRIES; R++ )); do
#             LABEL="${DBMS}_${WORKLOAD}_${FS}_fpw_${FPW}_t${TABLE}_c${THREADS}_r${R}"
#             OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
#             OUT_LOG="$RESULT_DIR/${LABEL}.log"
#             # OUT_IOSTAT="$RESULT_DIR/${LABEL}.iostat"
#             # EVENTS=$((EVENTS_BASE * THREADS))

#             mount_fs $FS $MOUNT_DIR
#             case "$DBMS" in
#               postgres)
#                 run_postgres_benchmark
#               ;;
#               mysql)
#                 run_mysql_benchmark
#               ;;
#             esac
#             log_ssd_state $OUT_DBSPEC
            
#           done
#         done
#       done
#     done
#     clear_fs $FS $DEVICE
#   done
#   echo "=== FS: $FS Done ==="
# done
# echo "=== All benchmarks completed ==="

for FS in ${FS_GROUPS[@]}; do
  for TABLE in "${SB_TABLES[@]}"; do
    for WORKLOAD in "${WORKLOADS[@]}"; do
      for THREADS in "${THREADS_LIST[@]}"; do
      echo "=== Setting up FS: $FS in device($DEVICE) with TABLE: $TABLE ==="
      # create_database $FS $DBMS $TABLE
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
        done
        # clear_fs $FS $DEVICE
      done
    done
  done
  echo "=== FS: $FS Done ==="
done
echo "=== All benchmarks completed ==="
