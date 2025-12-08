#!/bin/bash
set -e

usage() {
    echo "Usage: $0 {mysql|postgres} {main|motiv|io|scale} [FS] [APP_PROTECT]"
    echo ""
    echo "Arguments:"
    echo "  DBMS         : mysql | postgres"
    echo "  TEST         : main | motiv | io | scale"
    echo "  FS           : ext4 | xfs | zfs | ext4-dj | xfs-cow | tau | all"
    echo "  APP_PROTECT  : on | off"
    echo ""
    echo "Rules:"
    echo "  - FS 'xfs-cow' only works with mysql."
    echo "  - APP_PROTECT=on only valid when FS is ext4 or xfs."
    echo "  - Kernel-to-FS mappings are exact:"
    echo "        6.8.0+           → ext4, xfs, zfs, ext4-dj"
    echo "        6.16.0+          → xfs-cow only"
    echo "        6.8.0tjournal+   → tau only"
    exit 1
}

DBMS="$1"
TEST="scale"

declare -A FS_GROUPS
# Or you can just hardcode like below:
FS_GROUPS[on]=""
FS_GROUPS[off]="zfs-8k ext4-dj" #xfs-cow

SB_TABLES=32 # fixed
TRIES=1
SCALE_LIST=(5000)
THREADS_LIST=(1 4 8 16 32 64)
RUNNING_TIME=300
WARMUP_TIME=1800
WORKLOADS=(oltp_update_non_index)
# bulk_insert << error in postgres

echo "=== Starting sysbench benchamrk: DBMS=$DBMS, TEST=$TEST ==="
echo "=== WORKLOADS=${WORKLOADS[*]}, SCALE_LIST=${SCALE_LIST[*]}, THREADS_LIST=${THREADS_LIST[*]} ==="

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/sysbench/$DBMS/$DATE"
mkdir -p "$RESULT_DIR"

postgres_warmup() {
  PG_DATA="$MOUNT_DIR/postgres"
  DBNAME="sbtest_s${SCALE}"
  ROWS=$(sysbench_rows_per_table "$SCALE")
  pg_fpw $PG_DATA $FPW
  if [[ "$FPW" == "on" ]]; then
    WALSIZE="16GB"
  else
    WALSIZE="2GB"
  fi
  pg_wal_max_set $PG_DATA $WALSIZE
  $PG_BIN/pg_ctl -D $PG_DATA start

  echo "--> Benchmarking $LABEL warming up"
  sysbench $WORKLOAD \
    --db-driver=pgsql --auto_inc=on \
    --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
    --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
    --tables=$SB_TABLES --table-size=$ROWS \
    --threads=32 --time=$WARMUP_TIME run
  echo "--> Benchmarking $LABEL"
}

stop_postgres() {
  PG_DATA="$MOUNT_DIR/postgres"
  $PG_BIN/pg_ctl -D $PG_DATA stop
  sleep 5
  echo "--> Volume Benchmarking $LABEL Done"
  umount_fs $MOUNT_DIR
}

run_postgres_benchmark() {
  PG_DATA="$MOUNT_DIR/postgres"
  DBNAME="sbtest_s${SCALE}"
  ROWS=$(sysbench_rows_per_table "$SCALE")

  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
    --db-driver=pgsql --auto_inc=on \
    --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
    --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
    --tables=$SB_TABLES --table-size=$ROWS \
    --threads=$THREADS --time=$RUNNING_TIME --report-interval=10 \
    --percentile=99 --histogram="on" run > "$OUT_LOG"
}


mysql_warmup() {
  MY_DATA="$MOUNT_DIR/mysql"
  MY_SOCK="$MY_DATA/mysql.sock"
  DBNAME="sbtest_s${SCALE}"
  ROWS=$(sysbench_rows_per_table "$SCALE")
  if [[ "$FPW" == "on" ]]; then
    DBW=1
  else
    DBW=0
  fi

  INNODB_BP_SIZE="16G"  

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

  log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

  echo "--> Benchmarking $LABEL warming up"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$SB_TABLES --table-size=$ROWS \
    --threads=32 --time=$WARMUP_TIME --report-interval=60 run
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

  echo "--> Benchmarking $LABEL"
  sysbench $WORKLOAD \
    --db-driver=mysql \
    --mysql-user=root --mysql-socket=$MY_SOCK --mysql-db=$DBNAME \
    --tables=$SB_TABLES --table-size=$ROWS --percentile=99 --histogram="on" \
    --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"
}

stop_mysql() {
  MY_DATA="$MOUNT_DIR/mysql"
  MY_SOCK="$MY_DATA/mysql.sock"
 
  $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
  sleep 5
  echo "--> Volume Benchmarking $LABEL Done"
  umount_fs $MOUNT_DIR
}

## Start here
# MAIN LOOP
for FPW in on off; do
  for FS in ${FS_GROUPS[$FPW]}; do
    for SCALE in "${SCALE_LIST[@]}"; do
      for WORKLOAD in "${WORKLOADS[@]}"; do
        for (( R=1; R<=$TRIES; R++ )); do
          restore_filesystem $FS "s$SCALE" $BACKUP_DIR
          mount_fs $FS $MOUNT_DIR
          case "$DBMS" in
            postgres)
              postgres_warmup
            ;;
            mysql)
              mysql_warmup
            ;;
          esac
          for THREADS in "${THREADS_LIST[@]}"; do
            LABEL="${DBMS}_${WORKLOAD}_${FS}_fpw_${FPW}_s${SCALE}_c${THREADS}_r${R}"
            OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
            OUT_LOG="$RESULT_DIR/${LABEL}.log"
            OUT_IOSTAT="$RESULT_DIR/${LABEL}.iostat"
            EVENTS=$((EVENTS_BASE * THREADS))

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
          case "$DBMS" in
            postgres)
              stop_postgres
            ;;
            mysql)
              stop_mysql
            ;;
          esac
          clear_fs $FS $DEVICE
        done
      done
    done
    echo "=== FS: $FS Done ==="
  done
done
echo "=== All benchmarks completed ==="