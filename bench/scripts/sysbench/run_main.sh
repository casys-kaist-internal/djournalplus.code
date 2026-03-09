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
FS_GROUPS="ext4 zfs"
FS_FPWON="ext4 xfs"
FS_FPWOFF="ext4 zfs xfs ext4-dj"

TRIES=1
SB_TABLES=(8 16 32)
THREADS_LIST=(8 32 64)
RUNNING_TIME=300
WARMUP_TIME=600
WORKLOADS=(oltp_update_index oltp_write_only)

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
  MY_DATA="$MOUNT_DIR/mysql"
  MY_SOCK="$MY_DATA/mysql.sock"
  DBNAME="main_t${TABLE}"
  ROWS=$(main_rows_per_table "$TABLE")
  if [[ "$FPW" == "on" ]]; then
    DBW=1
  else
    DBW=0
  fi

  INNODB_BP_SIZE="8G"

  echo "[*] Start mysqld"
  $MYSQL_BIN/mysqld \
      --datadir="$MY_DATA" \
      --socket="$MY_SOCK" \
      --port="$MYSQL_PORT" \
      --pid-file="$MY_DATA/mysqld.pid" \
      --bind-address=127.0.0.1 \
      --skip-networking=0 \
      --innodb_buffer_pool_size=$INNODB_BP_SIZE \
      --innodb-doublewrite=$DBW &
  wait_for_sock "$MY_SOCK" 60

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

  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$TABLE --table-size=$ROWS --percentile=99 --histogram="on" \
    --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"

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
      DBNAME="main_t${TABLE}"
      ROWS=$(main_rows_per_table "$TABLE")

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
      MY_DATA="$MOUNT_DIR/mysql"
      MY_SOCK="$MY_DATA/mysql.sock"
      DBNAME="main_t${TABLE}"
      ROWS=$(main_rows_per_table "$TABLE")

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
    echo "=== Setting up FS: $FS in device($DEVICE) with TABLE: $TABLE ==="
    create_database $FS $DBMS $TABLE
    for FPW in on off; do
      if [[ "$FPW" == "on" ]]; then
        [[ ! " $FS_FPWON " =~ " $FS " ]] && continue
      elif [[ "$FPW" == "off" ]]; then
        [[ ! " $FS_FPWOFF " =~ " $FS " ]] && continue
      fi
      echo "Executing: FS=$FS, FPW=$FPW"
      for WORKLOAD in "${WORKLOADS[@]}"; do
        for THREADS in "${THREADS_LIST[@]}"; do
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
      done
    done
    clear_fs $FS $DEVICE
  done
  echo "=== FS: $FS Done ==="
done
echo "=== All benchmarks completed ==="
