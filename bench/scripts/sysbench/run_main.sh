#!/bin/bash
set -e

DBMS="${1:-}"  # postgres | mysql
if [[ "$DBMS" != "postgres" && "$DBMS" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql} [workload ...]"
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

# Main test use only TAU_MEM_GB of memory (bench/machines/<host>.env): the rest
# is reserved as unused huge pages
: "${TAU_MEM_GB:?is not set: source set_env.sh, which reads bench/machines/<host>.env}"
MEM_TOTAL_KB=$(awk '/^MemTotal/{t=$2} /^Hugetlb/{h=$2} END{print t-h}' /proc/meminfo)
MEM_TOTAL_GB=$((MEM_TOTAL_KB / 1024 / 1024))
if [ "$MEM_TOTAL_GB" -gt "$TAU_MEM_GB" ]; then
    echo "❌ Error: Usable memory (MemTotal minus huge pages) exceeds ${TAU_MEM_GB}GB limitation."
    echo "   - Current Memory: ~${MEM_TOTAL_GB}GB"
    echo "   Please reserve the rest with '$TAU_BOOT_ARGS' in GRUB settings."
    exit 1
fi
echo "✅ Memory size check passed: ~${MEM_TOTAL_GB}GB"

# Fixed host state: boot memory limit, swap, NUMA balancing, governor,
# C-states (host_setup.sh). HOST_CHECK=0 skips this, e.g. for A/B runs.
if [[ "${HOST_CHECK:-1}" != 0 ]]; then
  if ! bash "$TAUFS_BENCH/scripts/host_setup.sh" check; then
    echo "❌ Error: host is not in the benchmark state. Run: bench/scripts/host_setup.sh apply"
    exit 1
  fi
fi

echo "=================================================="
echo "  Environment check complete. Ready to proceed."
echo "=================================================="

# Stage 1: EXT4/XFS with the DB's own protection on (App: FPW/DWB on) and off (Raw).
# The FS lists and THREADS_LIST can also be given in the environment, e.g.
#   FS_GROUPS=ext4 FS_FPWON=ext4 FS_FPWOFF=ext4 THREADS_LIST=64 run_main.sh mysql
FS_GROUPS="${FS_GROUPS-ext4 xfs}"
FS_FPWON="${FS_FPWON-ext4 xfs}"
FS_FPWOFF="${FS_FPWOFF-ext4 xfs}"
# Stage 2, protection off only: EXT4_Data and ZFS (recordsize = DB page size)
#   mysql:    FS_GROUPS="ext4-dj20 zfs-16k"  FS_FPWON=""  FS_FPWOFF="ext4-dj20 zfs-16k"
#   postgres: FS_GROUPS="ext4-dj20 zfs-8k"   FS_FPWON=""  FS_FPWOFF="ext4-dj20 zfs-8k"
# Stage 3: FS_GROUPS="ext4-tau xfs-tau"  FS_FPWON=""  FS_FPWOFF="ext4-tau xfs-tau"

# Protocol (EVAL_PLAN §1): restore once per FS x FPW x workload, warm up, then
# sweep the thread points on the same running DB without restoring.
THREADS_LIST=(${THREADS_LIST:-1 8 16 32 64})
LAST_POINT_RUNS=3      # the last point (64) is measured 3 times
RUNNING_TIME=300       # 5 min per measurement, one PG checkpoint_timeout
WARMUP_TIME=${WARMUP_TIME:-600}  # once, right after the restore
WARMUP_THREADS=64
POINT_WARMUP_TIME=60   # whenever the thread count changes
# sysbench row-id distribution. The default (special) sends 75% of the accesses to
# the middle 1% of each table and 99% to the middle 34%; uniform is the sensitivity point.
SB_RAND_TYPE=special
WORKLOADS=(oltp_update_index oltp_write_only oltp_update_non_index oltp_delete oltp_insert)
# Workloads given after the DBMS replace the list, e.g. for a quick pilot
if [ $# -gt 1 ]; then
  WORKLOADS=("${@:2}")
fi

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"

# Reference points (EVAL_PLAN §2.2) change one fixed setting. The variant name
# is added to the result directory and after the FS in every label (ext4-odirect).
VARIANT="${VARIANT:-}"
case "$VARIANT" in
  "") ;;
  odirect)  # MySQL 8.4 default flush method instead of fsync
    [[ "$DBMS" == "mysql" ]] || { echo "❌ VARIANT=odirect is for mysql"; exit 1; }
    MY_FLUSH_METHOD=O_DIRECT ;;
  spin)  # MySQL 8.4 default redo spin-waits (heuristic) instead of off
    [[ "$DBMS" == "mysql" ]] || { echo "❌ VARIANT=spin is for mysql"; exit 1; }
    MY_LOG_SPIN_CPU_PCT_HWM=50 ;;
  nologwriter)  # no dedicated redo log writer/flusher threads
    [[ "$DBMS" == "mysql" ]] || { echo "❌ VARIANT=nologwriter is for mysql"; exit 1; }
    MY_EXTRA_ARGS="--innodb_log_writer_threads=OFF" ;;
  uniform)  # row ids uniform over each table instead of sysbench's default (special)
    SB_RAND_TYPE=uniform ;;
  binlog)  # MySQL 8.4 default binary log (on, sync_binlog=1) instead of off
    [[ "$DBMS" == "mysql" ]] || { echo "❌ VARIANT=binlog is for mysql"; exit 1; }
    MY_BINLOG=ON ;;
  *) echo "❌ Unknown VARIANT: $VARIANT"; exit 1 ;;
esac

TABLE=$MAIN_TABLES
ROWS=$MAIN_ROWS_PER_TABLE
IMAGE_KEY=$(main_image_key)
BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS

echo "=== Starting sysbench benchamrk: DBMS=$DBMS, image=$IMAGE_KEY${VARIANT:+, variant=$VARIANT} ==="
echo "=== WORKLOADS=${WORKLOADS[*]}, THREADS_LIST=${THREADS_LIST[*]} (last x$LAST_POINT_RUNS) ==="

for WORKLOAD in "${WORKLOADS[@]}"; do
  if [ ! -f "/usr/share/sysbench/$WORKLOAD.lua" ]; then
    echo "❌ Unknown sysbench workload: $WORKLOAD"
    exit 1
  fi
done
n_blocks=0
for FS in $FS_GROUPS; do
  if [ ! -f "$BACKUP_DIR/${FS}_${IMAGE_KEY}.img" ]; then
    echo "❌ Missing image $BACKUP_DIR/${FS}_${IMAGE_KEY}.img (run create_image.sh $DBMS)"
    exit 1
  fi
  if [[ " $FS_FPWON " =~ " $FS " ]]; then n_blocks=$((n_blocks + ${#WORKLOADS[@]})); fi
  if [[ " $FS_FPWOFF " =~ " $FS " ]]; then n_blocks=$((n_blocks + ${#WORKLOADS[@]})); fi
done
# timers plus ~5 min per block for restore and DB start/stop
block_sec=$(( WARMUP_TIME + ${#THREADS_LIST[@]} * POINT_WARMUP_TIME
              + (${#THREADS_LIST[@]} + LAST_POINT_RUNS - 1) * RUNNING_TIME + 300 ))
echo "=== $n_blocks blocks x ~$((block_sec / 60)) min = ~$((n_blocks * block_sec / 3600)) h ==="

DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAU_RESULTS/sysbench/$DBMS/$DATE${VARIANT:+_$VARIANT}"
mkdir -p "$RESULT_DIR"

# Device and DB-internal write counters around one measurement
log_io_counters() {
  local tag="$1" out="$2"
  log_dev_stat "$tag" "$out"
  case "$DBMS" in
    postgres) log_pg_io_counters "$tag" "$out" ;;
    mysql)    log_mysql_io_counters "$MY_SOCK" "$tag" "$out" ;;
  esac
}

# Warm up, then measure every thread point on the running DB (needs SB_ARGS
# and BLOCK). PG takes a CHECKPOINT right before each measurement so that every
# configuration starts its 5 minutes at the same checkpoint phase.
run_sweep() {
  local points=("${THREADS_LIST[@]}") last=${THREADS_LIST[-1]} prev=$WARMUP_THREADS i
  local -A runs=()
  for (( i=1; i<LAST_POINT_RUNS; i++ )); do points+=("$last"); done

  echo "--> Warming up $BLOCK (${WARMUP_TIME}s, $WARMUP_THREADS threads)"
  iostat_start "$RESULT_DIR/${BLOCK}_warmup.iostat" $((WARMUP_TIME + 10))
  sysbench $WORKLOAD "${SB_ARGS[@]}" --threads=$WARMUP_THREADS --time=$WARMUP_TIME \
    --report-interval=10 run >> "$RESULT_DIR/${BLOCK}_warmup.log"
  iostat_stop

  for THREADS in "${points[@]}"; do
    runs[$THREADS]=$(( ${runs[$THREADS]:-0} + 1 ))
    LABEL="${BLOCK}_c${THREADS}_r${runs[$THREADS]}"
    if [[ "$THREADS" != "$prev" ]]; then
      echo "--> Warming up $LABEL (${POINT_WARMUP_TIME}s)"
      sysbench $WORKLOAD "${SB_ARGS[@]}" --threads=$THREADS --time=$POINT_WARMUP_TIME \
        --report-interval=10 run >> "$RESULT_DIR/${BLOCK}_warmup.log"
      prev=$THREADS
    fi
    if [[ "$DBMS" == "postgres" ]]; then
      sudo -u "$PGUSER" "$PG_BIN/psql" -p "$PG_PORT" -d postgres -qc "CHECKPOINT;"
    fi

    echo "--> Benchmarking $LABEL"
    log_io_counters begin "$RESULT_DIR/${LABEL}.io" || true
    iostat_start "$RESULT_DIR/${LABEL}.iostat" $((RUNNING_TIME + 10))
    sysbench $WORKLOAD "${SB_ARGS[@]}" --threads=$THREADS --time=$RUNNING_TIME \
      --report-interval=10 --percentile=99 --histogram=on run > "$RESULT_DIR/${LABEL}.log"
    iostat_stop
    log_io_counters end "$RESULT_DIR/${LABEL}.io" || true
  done
}

run_postgres_block() {
  PG_DATA="$MOUNT_DIR/pgsql_data"
  DBNAME="main_t${TABLE}"
  # zfs-*: the WAL is in zfspool/log (create_image.sh); refuse an older image
  # that keeps it with the data
  if [[ -n "$(db_log_dir $FS)" && ! -L "$PG_DATA/pg_wal" ]]; then
    echo "❌ ${FS}_${IMAGE_KEY} has pg_wal in the data dataset: recreate the image"
    exit 1
  fi
  pg_fpw $PG_DATA $FPW
  pg_fixed_settings $PG_DATA
  case $FS in btrfs|zfs*) pg_cow_settings $PG_DATA ;; esac

  $PG_BIN/pg_ctl -D $PG_DATA -l "$RESULT_DIR/${BLOCK}_server.log" start
  log_pg_specs "$RESULT_DIR/${BLOCK}.spec" "$DBNAME" "$BLOCK"

  SB_ARGS=(--db-driver=pgsql --auto_inc=on
           --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT"
           --pgsql-user="$PGUSER" --pgsql-db="$DBNAME"
           --tables=$TABLE --table-size=$ROWS --rand-type=$SB_RAND_TYPE)
  run_sweep

  # The shutdown checkpoint can write all of shared_buffers; on ext4 data=journal
  # that took ~65 s, past pg_ctl's default 60 s wait.
  $PG_BIN/pg_ctl -D $PG_DATA -t 600 stop
  umount_fs $MOUNT_DIR
}

run_mysql_block() {
  MY_DATA="$MOUNT_DIR/mysql_data"
  MY_SOCK="$MY_DATA/mysql.sock"
  DBNAME="main_t${TABLE}"
  if [[ "$FPW" == "on" ]]; then
    DBW=ON
  else
    DBW=OFF
  fi

  # The image must hold the full pre-created redo log, or the first ~16 GB of
  # redo run at about half speed while InnoDB creates the files. zfs-*: in
  # zfspool/log (create_image.sh); an older image has none there.
  local redo_bytes want_bytes log_dir
  log_dir=$(db_log_dir $FS)
  redo_bytes=$(du -sb "${log_dir:-$MY_DATA}/#innodb_redo" | cut -f1)
  redo_bytes=${redo_bytes:-0}
  want_bytes=$(numfmt --from=iec "$MY_REDO_LOG_CAPACITY")
  if (( redo_bytes < want_bytes * 9 / 10 )); then
    echo "❌ Redo log in the image is $(numfmt --to=iec $redo_bytes), want $MY_REDO_LOG_CAPACITY: recreate the image"
    exit 1
  fi

  # OpenZFS Workload Tuning (InnoDB): native AIO off on ZFS. With it on, OpenZFS
  # 2.2.2 crashed the kernel in io_submit completion (2026-10-02).
  local my_extra=$MY_EXTRA_ARGS
  case $FS in zfs*) MY_EXTRA_ARGS="$MY_EXTRA_ARGS --innodb_use_native_aio=OFF" ;; esac
  if [[ -n "$log_dir" ]]; then
    MY_EXTRA_ARGS="$MY_EXTRA_ARGS --innodb_log_group_home_dir=$log_dir"
  fi
  echo "[*] Start mysqld"
  start_mysqld "$MY_DATA" "$MY_SOCK" $DBW "$RESULT_DIR/${BLOCK}_server.log"
  MY_EXTRA_ARGS=$my_extra
  log_mysql_specs $MY_SOCK "$RESULT_DIR/${BLOCK}.spec" $DBNAME

  SB_ARGS=(--db-driver=mysql
           --mysql-user=root --mysql-socket="$MY_SOCK" --mysql-db="$DBNAME"
           --tables=$TABLE --table-size=$ROWS --rand-type=$SB_RAND_TYPE)
  run_sweep

  log_numa_maps $MYSQLD_PID "$RESULT_DIR/${BLOCK}.spec"
  $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
  wait $MYSQLD_PID || true
  umount_fs $MOUNT_DIR
}

## Start here
log_env "$RESULT_DIR/env.txt"

# MAIN LOOP: workload outermost, so each workload's on/off pairs finish early
for WORKLOAD in "${WORKLOADS[@]}"; do
  for FS in $FS_GROUPS; do
    for FPW in on off; do
      if [[ "$FPW" == "on" ]]; then
        [[ ! " $FS_FPWON " =~ " $FS " ]] && continue
      else
        [[ ! " $FS_FPWOFF " =~ " $FS " ]] && continue
      fi
      BLOCK="${DBMS}_${WORKLOAD}_${FS}${VARIANT:+-$VARIANT}_fpw_${FPW}_t${TABLE}"
      echo "=== $BLOCK: restoring ${FS}_${IMAGE_KEY} on $DEVICE ==="
      restore_filesystem $FS "$IMAGE_KEY" $BACKUP_DIR
      mount_fs $FS $MOUNT_DIR
      if [[ "$FS" == zfs* ]]; then
        sudo zfs get -H -r -t filesystem -o name,property,value \
          recordsize,compression,logbias zfspool >> "$RESULT_DIR/${BLOCK}.spec"
      fi
      case "$DBMS" in
        postgres) run_postgres_block ;;
        mysql)    run_mysql_block ;;
      esac
      log_ssd_state "$RESULT_DIR/${BLOCK}.spec"
      clear_fs $FS $DEVICE
    done # FPW
  done # FS_GROUPS
  echo "=== WORKLOAD: $WORKLOAD Done ==="
done # WORKLOADS
echo "=== All benchmarks completed ==="
