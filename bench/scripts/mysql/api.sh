#!/bin/bash
set -e

### MySQL Configuration
MYSQL_BIN="$TAUFS_BENCH/mysql-server/build/bin"
MYSQL_PORT=3306
MYUSER=$TAU_USERNAME

# Fixed server settings shared by every configuration (EVAL_PLAN §2.2).
MY_BUFFER_POOL_SIZE=${TAU_DB_CACHE_GB}G  # 25% of TAU_MEM_GB (bench/machines/<host>.env)
MY_REDO_LOG_CAPACITY=16G   # symmetric with PG max_wal_size
MY_FLUSH_METHOD=fsync      # buffered I/O for every config (8.4 default is O_DIRECT)
# No binary log (--disable-log-bin): with the 8.4 default (on, sync_binlog=1) the
# binlog group commit caps TPS and hides the storage-level costs (2026-09-26).
MY_BINLOG=OFF
# No spin-waiting for redo flushes. The default (50) turns it on and off by a
# CPU-usage heuristic: 32 threads ran slower than 16, and the 64-thread warm-up
# doubled its TPS midway (2026-09-29). innodb_log_writer_threads stays ON (default).
MY_LOG_SPIN_CPU_PCT_HWM=0
# innodb_numa_interleave stays at its 8.4 default (ON: the buffer pool is spread
# over both NUMA nodes). It exists only in a build WITH_NUMA=ON (install_mysql.sh).
MY_EXTRA_ARGS=""           # extra server options, set by run_main.sh variants
MY_PREWRITE_REDO=0         # 1: prewrite_spare_redo after the start (run_main.sh VARIANT=ssd990)
MY_CPUS=${MY_CPUS:-}       # mysqld on these CPUs only (a taskset list; run_main.sh SB_CPUS: the client's)

wait_for_sock () {
  local path="$1" tries="${2:-60}"
  for i in $(seq 1 "$tries"); do
    [[ -S "$path" ]] && return 0
    sleep 1
  done
  echo "Socket $path not found (timeout)" >&2
  return 1
}

# mysqld recreates its spare redo files (#innodb_redo/#ib_redoN_tmp) at every
# start with fallocate(FALLOC_FL_ZERO_RANGE), i.e. as unwritten extents. Until
# each has been written once (about innodb_redo_log_capacity of redo), every redo
# write converts extents and every redo fdatasync also commits the file system
# journal: on the 990 PRO 4TB, XFS runs 7-8x and ext4 2x slower, and a slow
# configuration stays in that phase for hours (2026-10-28; diag_mysql_* in
# results/libra09/sysbench). Once mysqld has created them and before any load,
# overwrite the spares with zeros (their content) with O_DIRECT, as in a server
# that has run for a while. XFS and ext4 only: on ZFS mysqld writes the zeros.
prewrite_spare_redo() {  # <redo dir>
  local dir="$1" fst list prev="" f sz t0 i n=0
  fst=$(stat -f -c %T "$dir")
  if [[ "$fst" != xfs && "$fst" != ext2/ext3 ]]; then
    echo "[*] spare redo pre-write skipped ($fst)"
    return 0
  fi
  sleep 20   # the spares appear shortly after the socket; then wait for a stable listing
  for (( i = 0; i < 12; i++ )); do
    list=$(ls -i "$dir" | sort)
    [[ "$list" == "$prev" && "$list" == *_tmp* ]] && break
    prev=$list
    sleep 5
  done
  t0=$(date +%s)
  for f in "$dir"/*_tmp; do
    sz=$(stat -c %s "$f")
    (( sz % 1048576 == 0 )) || { echo "❌ $f: size $sz is not a multiple of 1 MiB"; return 1; }
    sudo dd if=/dev/zero of="$f" bs=1M count=$(( sz / 1048576 )) oflag=direct conv=notrunc,fsync \
      status=none || return 1
    n=$(( n + 1 ))
  done
  [[ "$(ls -i "$dir" | sort)" == "$list" ]] || { echo "❌ the redo files changed during the pre-write"; return 1; }
  echo "[*] pre-wrote $n spare redo files in $(( $(date +%s) - t0 )) s"
}

# Start mysqld in the background with the fixed settings; sets MYSQLD_PID.
# start_mysqld <datadir> <socket> <doublewrite: ON|OFF> <error log>
start_mysqld() {
  local datadir="$1" sock="$2" dblwr="$3" errlog="$4" extra=()
  [[ "$MY_BINLOG" == "OFF" ]] && extra+=(--disable-log-bin)
  extra+=($MY_EXTRA_ARGS)
  ${MY_CPUS:+taskset -c $MY_CPUS} $MYSQL_BIN/mysqld \
      --datadir="$datadir" \
      --socket="$sock" \
      --port="$MYSQL_PORT" \
      --pid-file="$datadir/mysqld.pid" \
      --bind-address=127.0.0.1 \
      --skip-networking=0 \
      --log-error="$errlog" \
      --innodb_buffer_pool_size=$MY_BUFFER_POOL_SIZE \
      --innodb_redo_log_capacity=$MY_REDO_LOG_CAPACITY \
      --innodb_flush_method=$MY_FLUSH_METHOD \
      --innodb_doublewrite=$dblwr \
      --innodb_log_spin_cpu_pct_hwm=$MY_LOG_SPIN_CPU_PCT_HWM \
      "${extra[@]}" &
  MYSQLD_PID=$!
  wait_for_sock "$sock" 120 || return 1
  if [[ "$MY_PREWRITE_REDO" == 1 ]]; then
    local redo_dir=$datadir
    [[ " $MY_EXTRA_ARGS " =~ \ --innodb_log_group_home_dir=([^ ]+) ]] && redo_dir=${BASH_REMATCH[1]}
    prewrite_spare_redo "$redo_dir/#innodb_redo"
  fi
}

# Doublewrite (the DWB cost), redo and data write volume, one line.
log_mysql_io_counters() {
  local sock="$1" tag="$2" out="$3"
  echo "$tag $($MYSQL_BIN/mysql -uroot --socket="$sock" -NBe "
    SHOW GLOBAL STATUS WHERE Variable_name IN
      ('Innodb_dblwr_pages_written', 'Innodb_dblwr_writes', 'Innodb_os_log_written',
       'Innodb_data_written', 'Innodb_pages_written', 'Innodb_data_fsyncs')" \
    | awk '{printf "%s=%s ", $1, $2}')" >> "$out"
  # Thread time in file syncs (misc) and all file I/O (wait), in picoseconds
  echo "$tag $($MYSQL_BIN/mysql -uroot --socket="$sock" -NBe "
    SELECT SUBSTRING_INDEX(EVENT_NAME, '/', -1), COUNT_MISC, SUM_TIMER_MISC, SUM_TIMER_WAIT
    FROM performance_schema.file_summary_by_event_name
    WHERE EVENT_NAME IN ('wait/io/file/sql/binlog', 'wait/io/file/innodb/innodb_log_file',
                         'wait/io/file/innodb/innodb_dblwr_file', 'wait/io/file/innodb/innodb_data_file')" \
    | awk '{printf "ps_%s_misc=%s ps_%s_misc_ps=%s ps_%s_wait_ps=%s ", $1, $2, $1, $3, $1, $4}')" >> "$out"
}

log_mysql_specs() {
  local sock="$1"
  local out_log="$2"
  local dbname="${3:-}"

  {
    echo "===== MySQL Server Info ====="
    date

    echo -e "\n-- Version --"
    $MYSQL_BIN/mysql -uroot --socket="$sock" -e "SELECT VERSION() AS version\G"

    echo -e "\n-- InnoDB Config --"
    $MYSQL_BIN/mysql -uroot --socket="$sock" -e "
      SHOW VARIABLES LIKE 'innodb_doublewrite';
      SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
      SHOW VARIABLES LIKE 'innodb_flush_method';
      SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
      SHOW VARIABLES LIKE 'innodb_log_file_size';
      SHOW VARIABLES LIKE 'innodb_redo_log_capacity';
      SHOW VARIABLES LIKE 'innodb_log_group_home_dir';
      SHOW VARIABLES LIKE 'innodb_page_size';
      SHOW VARIABLES LIKE 'innodb_file_per_table';
      SHOW VARIABLES LIKE 'log_bin';
      SHOW VARIABLES LIKE 'innodb_log_spin_cpu%';
      SHOW VARIABLES LIKE 'innodb_log_writer_threads';
      SHOW VARIABLES LIKE 'innodb_numa_interleave';
      SHOW VARIABLES LIKE 'innodb_use_native_aio';
      SHOW VARIABLES LIKE 'sync_binlog';
    "

    echo -e "\n-- Charset/Collation --"
    $MYSQL_BIN/mysql -uroot --socket="$sock" -e "
      SHOW VARIABLES LIKE 'character_set_server';
      SHOW VARIABLES LIKE 'collation_server';
    "

    echo -e "\n-- Database Sizes --"
    if [[ -n "$dbname" ]]; then
      $MYSQL_BIN/mysql -uroot --socket="$sock" -NBe "
        SELECT ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS size_gb
        FROM information_schema.tables
        WHERE table_schema='${dbname}';
      "
    else
      $MYSQL_BIN/mysql -uroot --socket="$sock" -NBe "
        SELECT table_schema,
               ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS size_gb
        FROM information_schema.tables
        GROUP BY table_schema;
      "
    fi
  } >> "$out_log" 2>&1
  $MYSQL_BIN/mysqladmin -uroot -h127.0.0.1 -P"$MYSQL_PORT" variables >> "$out_log"
}