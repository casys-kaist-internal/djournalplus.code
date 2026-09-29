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

if [[ "$DBMS" == "postgres" ]]; then
  FS_GROUPS="ext4 xfs ext4-dj10"
else
  FS_GROUPS="ext4 zfs-16k xfs ext4-dj10"
fi

FS_GROUPS="ext4"

FS_FPWON="ext4 xfs"
FS_FPWOFF="ext4 xfs zfs-8k zfs-16k ext4-dj10"

TRIES=1
SB_TABLES=(8)
THREADS_LIST=(64)
RUNNING_TIME=300
WARMUP_TIME=300
WORKLOADS=(oltp_write_only)

echo "=== Starting sysbench benchamrk: DBMS=$DBMS, TEST=$TEST ==="
echo "=== WORKLOADS=${WORKLOADS[*]}, TABLE_LIST=${SB_TABLES[*]}, THREADS_LIST=${THREADS_LIST[*]} ==="

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/sysbench/$DBMS/$DATE"
mkdir -p "$RESULT_DIR"

###############################################################################
# Profiling helpers
###############################################################################

# Get the PID of the running DB process
get_db_pid() {
  if [[ "$DBMS" == "postgres" ]]; then
    pgrep -x postgres | head -1
  else
    pgrep -x mysqld | head -1
  fi
}

# Start background profiling collectors
start_profiling() {
  local label=$1
  local out_dir=$2
  local db_pid
  db_pid=$(get_db_pid)

  # --- iostat: device-level I/O throughput & utilization ---
  iostat -xz 1 > "${out_dir}/${label}.iostat" 2>&1 &
  IOSTAT_PID=$!

  # --- blktrace: block-layer I/O trace (optional, needs root) ---
  # Uncomment if you want per-request block traces:
  # sudo blktrace -d $DEVICE -o "${out_dir}/${label}.blktrace" &
  # BLKTRACE_PID=$!

  # --- perf trace: fsync/fdatasync call frequency & latency ---
  if [[ -n "$db_pid" ]]; then
    sudo perf trace -e fsync,fdatasync -p "$db_pid" \
      -o "${out_dir}/${label}.fsynctrace" 2>&1 &
    PERFTRACE_PID=$!
  fi

  echo "[profiling] started: iostat=$IOSTAT_PID perf=$PERFTRACE_PID"
}

# Stop background profiling collectors
stop_profiling() {
  [[ -n "${IOSTAT_PID:-}" ]]    && kill $IOSTAT_PID 2>/dev/null && wait $IOSTAT_PID 2>/dev/null || true
  [[ -n "${PERFTRACE_PID:-}" ]] && sudo kill $PERFTRACE_PID 2>/dev/null && wait $PERFTRACE_PID 2>/dev/null || true
  # [[ -n "${BLKTRACE_PID:-}" ]] && sudo kill $BLKTRACE_PID 2>/dev/null && wait $BLKTRACE_PID 2>/dev/null || true
  IOSTAT_PID=""
  PERFTRACE_PID=""
  echo "[profiling] stopped"
}

# Snapshot PostgreSQL internal stats (call before & after benchmark)
snapshot_pg_stats() {
  local phase=$1  # "before" or "after"
  local out_file=$2
  local dbname=$3

  $PG_BIN/psql -d "$dbname" -p "$PG_PORT" -U "$PGUSER" -t -A <<SQL > "${out_file}.pg_stats_${phase}"
-- WAL stats
SELECT 'pg_stat_wal' AS src, * FROM pg_stat_wal;
-- Background writer stats (checkpoint write volume)
SELECT 'pg_stat_bgwriter' AS src, * FROM pg_stat_bgwriter;
-- I/O stats (PG16+)
SELECT 'pg_stat_io' AS src, backend_type, context, reads, writes, fsyncs
  FROM pg_stat_io
  WHERE writes > 0 OR fsyncs > 0
  ORDER BY fsyncs DESC;
SQL

  # WAL directory size
  echo "wal_dir_bytes=$(du -sb "$PG_DATA/pg_wal" 2>/dev/null | awk '{print $1}')" \
    >> "${out_file}.pg_stats_${phase}"
}

# Snapshot MySQL/InnoDB internal stats (call before & after benchmark)
snapshot_mysql_stats() {
  local phase=$1  # "before" or "after"
  local out_file=$2
  local sock=$3

  $MYSQL_BIN/mysql -uroot --socket="$sock" -N -B -e "
    -- InnoDB doublewrite stats
    SHOW GLOBAL STATUS LIKE 'Innodb_dblwr%';
    -- InnoDB redo log / fsync stats
    SHOW GLOBAL STATUS LIKE 'Innodb_os_log%';
    -- InnoDB data fsyncs
    SHOW GLOBAL STATUS LIKE 'Innodb_data_fsyncs';
    SHOW GLOBAL STATUS LIKE 'Innodb_data_pending_fsyncs';
    -- InnoDB data written
    SHOW GLOBAL STATUS LIKE 'Innodb_data_written';
    -- InnoDB log waits (stalls due to log buffer)
    SHOW GLOBAL STATUS LIKE 'Innodb_log_waits';
    SHOW GLOBAL STATUS LIKE 'Innodb_log_write_requests';
    SHOW GLOBAL STATUS LIKE 'Innodb_log_writes';
    -- InnoDB pages written (for write amplification)
    SHOW GLOBAL STATUS LIKE 'Innodb_pages_written';
    SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_flushed';
  " > "${out_file}.mysql_stats_${phase}"

  # Redo log file sizes
  local redo_dir
  redo_dir=$(dirname "$sock")
  echo "redo_log_bytes=$(du -scb "$redo_dir"/#innodb_redo/ 2>/dev/null | tail -1 | awk '{print $1}')" \
    >> "${out_file}.mysql_stats_${phase}"
}

###############################################################################

run_postgres_benchmark() {
  PG_DATA="$MOUNT_DIR/pgsql_data"
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

  # --- Profiling: snapshot before & start collectors ---
  snapshot_pg_stats "before" "$OUT_PROFILE" "$DBNAME"
  start_profiling "$LABEL" "$RESULT_DIR"

  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
      --db-driver=pgsql --auto_inc=on \
      --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
      --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
      --tables=$TABLE --table-size=$ROWS \
      --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 \
      --percentile=99 --histogram="on" run > "$OUT_LOG"

  # --- Profiling: snapshot after & stop collectors ---
  snapshot_pg_stats "after" "$OUT_PROFILE" "$DBNAME"
  stop_profiling

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
      --innodb_buffer_pool_size=2G \
      --log-error="$MY_LOGS/error.log" \
      --log-bin="$MY_BINLOGS/mysql-bin" \
      --innodb-doublewrite=$DBW &
  wait_for_sock "$MY_SOCK" 60

    # --innodb_buffer_pool_size=$INNODB_BP_SIZE \
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
    --threads=$THREADS --time=$WARMUP_TIME --report-interval=60 run

  # --- Profiling: snapshot before & start collectors ---
  snapshot_mysql_stats "before" "$OUT_PROFILE" "$MY_SOCK"
  start_profiling "$LABEL" "$RESULT_DIR"

  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS --percentile=99 --histogram="on" \
    --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"

  # --- Profiling: snapshot after & stop collectors ---
  snapshot_mysql_stats "after" "$OUT_PROFILE" "$MY_SOCK"
  stop_profiling

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

      PG_DATA="$MOUNT_DIR/pgsql_data"
      # sudo mkdir -p $PG_DATA
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

      if [[ "$FS" == "zfs-8k" ]]; then
        sleep 1
        sudo mv $PG_DATA/base $PG_DATA/base_old
        sudo mv $PG_DATA/pg_wal $PG_DATA/pg_wal_old
        sudo zfs create -o recordsize=8k -o redundant_metadata=most -o logbias=throughput zfspool/pgsql_data/base
        sudo zfs create -o recordsize=8k -o redundant_metadata=most -o logbias=throughput zfspool/pgsql_data/pg_wal
        sudo chown -R $PGUSER:$PGUSER $PG_DATA
        sudo cp -Rp $PG_DATA/base_old/* $PG_DATA/base
        sudo cp -Rp $PG_DATA/pg_wal_old/* $PG_DATA/pg_wal
      fi
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
for FS in ${FS_GROUPS[@]}; do
  for TABLE in "${SB_TABLES[@]}"; do
    for WORKLOAD in "${WORKLOADS[@]}"; do
      for THREADS in "${THREADS_LIST[@]}"; do
      echo "=== Setting up FS: $FS in device($DEVICE) with TABLE: $TABLE ==="
      # create_database $FS $DBMS $TABLE
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
            OUT_PROFILE="$RESULT_DIR/${LABEL}"
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