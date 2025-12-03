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
TEST="$2"
FS="$3"
APP="$4"

[[ -z "$DBMS" || -z "$TEST" ]] && usage

case "$DBMS" in
    mysql|postgres) ;;
    *) usage ;;
esac

case "$TEST" in
    main|motiv|io|scale) ;;
    *) usage ;;
esac

[[ -z "$FS" ]] && FS="all"
[[ -z "$APP" ]] && APP="all"

case "$FS" in
    ext4|xfs|zfs-8k|zfs-16k|ext4-dj|xfs-cow|tau|all) ;;
    *) usage ;;
esac

case "$APP" in
    on|off|all) ;;
    *) usage ;;
esac

KERNEL_RAW=$(uname -r)

if [[ "$KERNEL_RAW" == *"6.8.0tjournal"* ]]; then
    kernel_type="6.8.0tjournal"
elif [[ "$KERNEL_RAW" == *"6.8.0"* ]]; then
    kernel_type="6.8.0"
elif [[ "$KERNEL_RAW" == *"6.16.0"* ]]; then
    kernel_type="6.16.0"
else
    echo "Unsupported kernel"
    exit 1
fi

declare -A FS_GROUPS

if [[ "$DBMS" == "mysql" ]]; then
    base_off=("ext4" "xfs" "zfs-16k" "ext4-dj" "xfs-cow")
else
    base_off=("ext4" "xfs" "zfs-8k" "ext4-dj")
fi

base_on=("ext4" "xfs")
tau_only=("tau")

filter_kernel() {
    local f="$1"
    case "$kernel_type" in
        "6.8.0")
            [[ "$f" =~ ^(ext4|xfs|zfs-8k|zfs-16k|ext4-dj)$ ]]
            ;;
        "6.16.0")
            [[ "$f" == "xfs-cow" ]]
            ;;
        "6.8.0tjournal")
            [[ "$f" == "tau" ]]
            ;;
    esac
}

FS_GROUPS[on]=""
for f in "${base_on[@]}"; do
    filter_kernel "$f" && FS_GROUPS[on]+="$f "
done
FS_GROUPS[on]=$(echo "${FS_GROUPS[on]}" | xargs)

FS_GROUPS[off]=""
for f in "${base_off[@]}"; do
    filter_kernel "$f" && FS_GROUPS[off]+="$f "
done
FS_GROUPS[off]=$(echo "${FS_GROUPS[off]}" | xargs)

apply_arg_filter() {
    local list="$1"
    local result=""
    if [[ "$FS" == "all" ]]; then
        result="$list"
    else
        for f in $list; do
            [[ "$f" == "$FS" ]] && result="$f"
        done
    fi
    echo "$result"
}

FS_GROUPS[on]=$(apply_arg_filter "${FS_GROUPS[on]}")
FS_GROUPS[off]=$(apply_arg_filter "${FS_GROUPS[off]}")

if [[ "$APP" == "on" ]]; then
    FS_GROUPS[off]=""
elif [[ "$APP" == "off" ]]; then
    FS_GROUPS[on]=""
fi

if [[ -z "${FS_GROUPS[on]}" && -z "${FS_GROUPS[off]}" ]]; then
    echo "No valid FS remain"
    exit 1
fi

echo "FS_GROUPS[on] = ${FS_GROUPS[on]}"
echo "FS_GROUPS[off] = ${FS_GROUPS[off]}"

# Or you can just hardcode like below:
# FS_GROUPS[on]="ext4 xfs zfs-16k ext4-dj xfs-cow"
# FS_GROUPS[off]="ext4 xfs zfs-8k ext4-dj"

SB_TABLES=32 # fixed
if [[ "$TEST" == "motiv" ]]; then
  TRIES=1
  SCALE_LIST=(2500)
  THREADS_LIST=(32)
  RUNNING_TIME=600
  WARMUP_TIME=1800
  WORKLOADS=(oltp_update_index)
elif [[ "$TEST" == "main" ]]; then
  TRIES=1
  SCALE_LIST=(5000)
  THREADS_LIST=(32)
  RUNNING_TIME=600
  WARMUP_TIME=1800
  WORKLOADS=(oltp_insert oltp_update_index oltp_delete oltp_write_only oltp_read_write)
elif [[ "$TEST" == "io" ]]; then
  TRIES=1
  SCALE_LIST=(5000)
  THREADS_LIST=(32)
  EVENTS_BASE=1000000 # for check IO Volume
  WORKLOADS=(oltp_write_only)
elif [[ "$TEST" == "scale" ]]; then
  ## Normal test settings
  TRIES=1
  SCALE_LIST=(5000)
  THREADS_LIST=(4 8 16 32 64)
  RUNNING_TIME=600
  WARMUP_TIME=1800
  WORKLOADS=(oltp_write_only)
fi
# bulk_insert << error in postgres

echo "=== Starting sysbench benchamrk: DBMS=$DBMS, TEST=$TEST ==="
echo "=== WORKLOADS=${WORKLOADS[*]}, SCALE_LIST=${SCALE_LIST[*]}, THREADS_LIST=${THREADS_LIST[*]} ==="

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/sysbench/$DBMS/$DATE"
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
    if [[ "$TEST" == "motiv" ]]; then  # 10% of database
      WALSIZE="8GB"
    else
      WALSIZE="16GB"
    fi
  else
    if [[ "$TEST" == "motiv" ]]; then
      WALSIZE="1GB"
    else
      WALSIZE="2GB"
    fi
  fi
  pg_wal_max_set $PG_DATA $WALSIZE
  # pg_wal_level $PG_DATA $WALLEVEL # not used
  $PG_BIN/pg_ctl -D $PG_DATA start
  # pg_reset_wal_stats "$PGUSER" "$PG_PORT" "$PG_BIN" # not used
  # pg_reset_io_stats "$PGUSER" "$PG_PORT" "$PG_BIN" # not used

  if [[ "$TEST" == "io" ]]; then
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
  else
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

  if [[ "$TEST" == "motiv" ]]; then
    INNODB_BP_SIZE="8G"
  else
    INNODB_BP_SIZE="16G"
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
      --innodb-doublewrite=$DBW &
  wait_for_sock "$MY_SOCK" 60

    # --log-error="$MY_DATA/mysqld.err" \
    # --innodb_dedicated_server=1 \
    # --disable-log-bin \
    # --innodb_redo_log_capacity=$INNODB_LOG_SIZE \

  log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

  if [[ "$TEST" == "io" ]]; then
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
  else
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
      --tables=$SB_TABLES --table-size=$ROWS --percentile=99 --histogram="on" \
      --threads=$THREADS --time=$RUNNING_TIME --report-interval=30 run > "$OUT_LOG"

    $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
    sleep 5
    echo "--> Volume Benchmarking $LABEL Done"
    umount_fs $MOUNT_DIR
  fi
  echo "--> All Done: $LABEL"
}

## Start here
# MAIN LOOP
for FPW in on off; do
  for FS in ${FS_GROUPS[$FPW]}; do
    for SCALE in "${SCALE_LIST[@]}"; do
      for WORKLOAD in "${WORKLOADS[@]}"; do
        for THREADS in "${THREADS_LIST[@]}"; do
          for (( R=1; R<=$TRIES; R++ )); do
            LABEL="${DBMS}_${WORKLOAD}_${FS}_fpw_${FPW}_s${SCALE}_c${THREADS}_r${R}"
            OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
            OUT_LOG="$RESULT_DIR/${LABEL}.log"
            OUT_IOSTAT="$RESULT_DIR/${LABEL}.iostat"
            EVENTS=$((EVENTS_BASE * THREADS))

            #warming_up_ssd
            echo "=== Setting up FS: $FS (FPW=$FPW) in device($DEVICE) ==="
            restore_filesystem $FS "s$SCALE" $BACKUP_DIR
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
            clear_fs $FS $DEVICE
          done
        done
      done
    done
    echo "=== FS: $FS Done ==="
  done
done
echo "=== All benchmarks completed ==="

