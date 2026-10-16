# Profiling runs of run_main.sh (PROFILE=trace|perf|walkeep|diag), sourced by it:
# the usual restore and 10-min warm-up, then one 5-min measurement at 64
# threads with collectors around it. Separate from the throughput runs, which
# carry no tracing.
#   trace    profile_io.bt: write and sync paths per file type, jbd2 commits and
#            checkpoints, ZFS waits
#   perf     perf lock contention -ab (top 20 waiters with call stacks), then
#            perf record -a -g, 60 s each inside the measurement
#   walkeep  PG only: wal_keep_size keeps every WAL segment of the measurement,
#            then pg_waldump --stats over its LSN range (FPI share of the WAL)
#   diag     the measurement carries only the cheap counters (PG
#            track_wal_io_timing, the DB statistics snapshots); the costly
#            instruments run afterwards, in a diagnosis window on the same DB
#            under the same 64-thread load: MySQL free-page waits
#            (freepage_wait.bt uprobes), ZFS perf record -a -g and perf lock
#            contention (with perf_zfs.py: CPU by thread group and ZFS code
#            path, lock spinning, top stacks, contended locks), PG with FPW
#            pg_waldump --stats over 30 s of WAL. DIAG_TOOLS replaces the
#            instruments, e.g. DIAG_TOOLS=offcpu: the MySQL user threads'
#            on-CPU, CPU-wait and blocked time (schedstat) and their blocked
#            time by stack (offcpu.bt)
# Every profiling run also records mpstat, the DB statistics before and after
# (PG pg_stat_wal/database/io/checkpointer, MySQL global status, INNODB_METRICS,
# file_summary_by_instance, and a 1-s INNODB_METRICS series), the ZFS kstats,
# the jbd2 info, and once per block the configuration (uname, mounts, write
# cache, mkfs/dataset settings, ZFS parameters, all DB settings). PG runs set
# track_wal_io_timing=on; MySQL runs enable the InnoDB buffer and log metrics.

PERF_BIN=${PERF_BIN:-$HOME/codes/linux-6.8.0plus-build/tools/perf/perf}
PG_WAL_KEEP=${PG_WAL_KEEP:-400GB}  # > WAL of warm-up tail + 5 min at 64 threads with FPW
ZFS_TXG_HISTORY=1000               # txgs kept in /proc/spl/kstat/zfs/<pool>/txgs
PROFILE_IO_BT="$TAUFS_BENCH/scripts/sysbench/profile_io.bt"
PROFILE_FREEPAGE_BT="$TAUFS_BENCH/scripts/sysbench/freepage_wait.bt"
PROFILE_OFFCPU_BT="$TAUFS_BENCH/scripts/sysbench/offcpu.bt"
DIAG_TOOLS=${DIAG_TOOLS:-}          # instead of the default instruments
DIAG_SETTLE_S=${DIAG_SETTLE_S:-20}  # diagnosis load before the first instrument
DIAG_WINDOW_S=${DIAG_WINDOW_S:-60}  # each instrument's window
DIAG_WAL_S=30                       # WAL kept and dumped (PG with FPW)
PG_DIAG_WAL_KEEP=200GB              # > DIAG_WAL_S of WAL plus what pg_waldump's run adds

profile_check() {
  case "$PROFILE" in
    trace|perf) ;;
    diag)
      if [[ "$DBMS" == "mysql" ]]; then
        nm "$MYSQL_BIN/mysqld" | grep -q " T _Z22buf_LRU_get_free_blockP10buf_pool_t" ||
          { echo "❌ mysqld has no buf_LRU_get_free_block symbol for the uprobes"; return 1; }
      fi
      "$PERF_BIN" version --build-options 2>/dev/null | grep -q "bpf_skeletons: \[ on" ||
        { echo "❌ $PERF_BIN lacks BPF skeletons (perf lock contention -b)"; return 1; }
      if [[ " $DIAG_TOOLS " == *" offcpu "* ]]; then
        [[ "$DBMS" == "mysql" ]] || { echo "❌ DIAG_TOOLS=offcpu is for mysql"; return 1; }
        sudo grep -q " finish_task_switch$" /proc/kallsyms ||
          { echo "❌ no finish_task_switch for offcpu.bt's kprobe"; return 1; }
      fi
      ;;
    walkeep) [[ "$DBMS" == "postgres" ]] || { echo "❌ PROFILE=walkeep is for postgres"; return 1; } ;;
    *) echo "❌ Unknown PROFILE: $PROFILE"; return 1 ;;
  esac
  [[ -e /sys/kernel/btf/vmlinux ]] || { echo "❌ PROFILE needs kernel BTF (boot $TAU_BASE_KERNEL)"; return 1; }
  if [[ "$PROFILE" == "perf" ]]; then
    "$PERF_BIN" version --build-options 2>/dev/null | grep -q "bpf_skeletons: \[ on" ||
      { echo "❌ $PERF_BIN lacks BPF skeletons (perf lock contention -b)"; return 1; }
  fi
  command -v mpstat >/dev/null || { echo "❌ mpstat not found (sysstat)"; return 1; }
}

# Before PG starts
profile_pg_settings() {
  pg_conf_set "$1" "track_wal_io_timing" "on"
  if [[ "$PROFILE" == "walkeep" ]]; then
    pg_conf_set "$1" "wal_keep_size" "$PG_WAL_KEEP"
  fi
}

# After mysqld starts
profile_mysql_settings() {
  local -; set +e   # run_main.sh runs under set -e; a failed collector must not stop it
  $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "
    SET GLOBAL innodb_monitor_enable = 'module_buffer';
    SET GLOBAL innodb_monitor_enable = 'module_log';"
  return 0
}

my_q() { $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -NBe "$1"; }
pg_q() { sudo -u "$PGUSER" "$PG_BIN/psql" -XAt -p "$PG_PORT" -d "$DBNAME" -c "$1"; }

# Configuration, once per block: profile_dump_once <out prefix>
profile_dump_once() {
  local -; set +e   # run_main.sh runs under set -e; a failed collector must not stop it
  local o=$1 ctrl=${TAU_DEVICE_NAME%n*}
  { uname -a; cat /proc/cmdline; } > "$o.uname"
  grep -E " $MOUNT_DIR(/[^ ]*)? " /proc/mounts > "$o.mounts"
  echo "$TAU_DEVICE_NAME $(cat /sys/block/$TAU_DEVICE_NAME/queue/write_cache)" > "$o.write_cache"
  sudo nvme get-feature "/dev/$ctrl" -f 6 -H >> "$o.write_cache" 2>&1
  case "$FS" in
    ext4*) sudo dumpe2fs -h "$DEVICE" > "$o.dumpe2fs" 2>&1 ;;
    xfs*)  xfs_info "$MOUNT_DIR" > "$o.xfs_info" 2>&1 ;;
    zfs*)  sudo zfs get -t filesystem all > "$o.zfs_get_all" 2>&1
           grep -H . /sys/module/zfs/parameters/* | sed 's|/sys/module/zfs/parameters/||' > "$o.zfs_params"
           cat /sys/module/zfs/version > "$o.zfs_version" ;;
  esac
  case "$DBMS" in
    postgres) pg_q "select name, setting, unit, source from pg_settings order by 1" > "$o.pg_settings" ;;
    mysql)    my_q "SHOW GLOBAL VARIABLES" > "$o.my_variables"
              my_q "SELECT NAME, ENABLED, TIMED FROM performance_schema.setup_instruments
                    WHERE NAME LIKE 'wait/io/file/%'" > "$o.my_ps_file_instruments" ;;
  esac
  return 0
}

# DB and kernel counters: profile_snapshot <begin|end> <out prefix>
profile_snapshot() {
  local -; set +e   # run_main.sh runs under set -e; a failed collector must not stop it
  local tag=$1 o=$2
  case "$DBMS" in
    postgres)
      pg_q "select 'time=' || extract(epoch from now()) || ' lsn=' || pg_current_wal_lsn()
              || ' lsn_bytes=' || pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0');
            select 'wal_records=' || wal_records || ' wal_fpi=' || wal_fpi || ' wal_bytes=' || wal_bytes
              || ' wal_buffers_full=' || wal_buffers_full || ' wal_write=' || wal_write
              || ' wal_sync=' || wal_sync || ' wal_write_time=' || wal_write_time
              || ' wal_sync_time=' || wal_sync_time from pg_stat_wal;
            select 'xact_commit=' || xact_commit || ' xact_rollback=' || xact_rollback
              from pg_stat_database where datname = current_database();
            select 'ckpt_num_timed=' || num_timed || ' ckpt_num_requested=' || num_requested
              || ' ckpt_write_time=' || write_time || ' ckpt_sync_time=' || sync_time
              || ' ckpt_buffers_written=' || buffers_written from pg_stat_checkpointer;
            select 'io_fsyncs=' || coalesce(sum(fsyncs), 0) || ' io_writes=' || coalesce(sum(writes), 0)
              from pg_stat_io;" | sed "s/^/$tag /" >> "$o.pgstat"
      pg_q "select '$tag', backend_type, object, context, writes, fsyncs from pg_stat_io
            where coalesce(writes, 0) > 0 or coalesce(fsyncs, 0) > 0" >> "$o.pg_stat_io"
      ;;
    mysql)
      my_q "SHOW GLOBAL STATUS" | sed "s/^/$tag /" >> "$o.my_status"
      my_q "SELECT NAME, SUBSYSTEM, COUNT, STATUS FROM information_schema.INNODB_METRICS" \
        | sed "s/^/$tag /" >> "$o.my_metrics"
      my_q "SELECT FILE_NAME, EVENT_NAME, COUNT_WRITE, COUNT_MISC, SUM_NUMBER_OF_BYTES_WRITE,
                   SUM_TIMER_WRITE, SUM_TIMER_MISC FROM performance_schema.file_summary_by_instance
            WHERE COUNT_WRITE > 0 OR COUNT_MISC > 0" | sed "s/^/$tag /" >> "$o.my_files"
      ;;
  esac
  case "$FS" in
    zfs*)  for k in dmu_tx zil arcstats; do
             { echo "== $tag"; cat /proc/spl/kstat/zfs/$k; } >> "$o.kstat_$k"
           done
           { echo "== $tag"; cat /proc/spl/kstat/zfs/zfspool/txgs; } >> "$o.kstat_txgs" ;;
    ext4*) { echo "== $tag"; sudo cat /proc/fs/jbd2/${TAU_DEVICE_NAME}-8/info; } >> "$o.jbd2_info" ;;
  esac
  return 0
}

# Around the sysbench measurement: profile_begin <label>, profile_end <label>
profile_begin() {
  local -; set +e   # run_main.sh runs under set -e; a failed collector must not stop it
  local o="$RESULT_DIR/$1"
  [[ "$FS" == zfs* ]] && echo $ZFS_TXG_HISTORY | sudo tee /sys/module/zfs/parameters/zfs_txg_history >/dev/null
  profile_snapshot begin "$o"
  S_TIME_FORMAT=ISO mpstat 1 $((RUNNING_TIME + 10)) > "$o.mpstat" 2>&1 &
  PROF_MPSTAT_PID=$!
  if [[ "$DBMS" == "mysql" ]]; then
    ( while :; do
        echo "$(date -u +%T) $(my_q "SELECT NAME, COUNT FROM information_schema.INNODB_METRICS
            WHERE NAME IN ('log_lsn_checkpoint_age', 'log_max_modified_age_async',
                           'log_max_modified_age_sync', 'log_lsn_current', 'log_lsn_last_checkpoint')
               OR NAME LIKE 'buffer_flush_sync%'" | awk '{printf "%s=%s ", $1, $2}')"
        sleep 1
      done ) > "$o.my_metrics_1s" 2>&1 &
    PROF_SAMPLER_PID=$!
  fi
  case "$PROFILE" in
    trace)
      local filt=0 devnum
      [[ "$DBMS" == "mysql" ]] && filt=$MYSQLD_PID
      devnum=$(( (0x$(stat -c %t "$DEVICE") << 20) | 0x$(stat -c %T "$DEVICE") ))
      sudo bpftrace "$PROFILE_IO_BT" "$filt" "$devnum" > "$o.bpftrace" 2>&1 &
      PROF_BT_PID=$!
      # start the measurement only once every probe is attached
      local i
      for (( i = 0; i < 60; i++ )); do
        grep -q "^Attaching" "$o.bpftrace" 2>/dev/null && break
        sleep 1
      done
      sleep 2
      ;;
    perf)
      ( sleep 60
        sudo "$PERF_BIN" lock contention -a -b -E 20 --max-stack 16 -v -- sleep 60 > "$o.perf_lock" 2>&1
        sleep 60
        sudo "$PERF_BIN" record -a -g -F 99 -o "$o.perf.data" -- sleep 60 > "$o.perf_record.log" 2>&1
      ) &
      PROF_PERF_PID=$!
      ;;
  esac
  echo "begin $(date -u +%s.%N)" > "$o.time"
  return 0
}

profile_end() {
  local -; set +e   # run_main.sh runs under set -e; a failed collector must not stop it
  local o="$RESULT_DIR/$1"
  echo "end $(date -u +%s.%N)" >> "$o.time"
  if [[ -n "$PROF_BT_PID" ]]; then
    sudo kill -INT "$PROF_BT_PID" 2>/dev/null; wait "$PROF_BT_PID" 2>/dev/null; PROF_BT_PID=
  fi
  if [[ -n "$PROF_PERF_PID" ]]; then
    wait "$PROF_PERF_PID" 2>/dev/null; PROF_PERF_PID=
    sudo "$PERF_BIN" report -i "$o.perf.data" --no-children --sort sym -g none --stdio 2>/dev/null \
      | grep -v '^#' | grep '%' | head -60 > "$o.perf_self"
    sudo "$PERF_BIN" report -i "$o.perf.data" --no-children --sort comm,dso -g none --stdio 2>/dev/null \
      | grep -v '^#' | grep '%' | head -40 > "$o.perf_comm"
    sudo "$PERF_BIN" report -i "$o.perf.data" --children --sort sym -g caller,0.5,callee --stdio 2>/dev/null \
      | head -3000 > "$o.perf_callgraph"
  fi
  [[ -n "$PROF_SAMPLER_PID" ]] && { kill "$PROF_SAMPLER_PID" 2>/dev/null; wait "$PROF_SAMPLER_PID" 2>/dev/null; PROF_SAMPLER_PID=; }
  kill "$PROF_MPSTAT_PID" 2>/dev/null; wait "$PROF_MPSTAT_PID" 2>/dev/null
  profile_snapshot end "$o"
  if [[ "$PROFILE" == "walkeep" ]]; then
    local lsn0 lsn1
    lsn0=$(awk '$1 == "begin" && $3 ~ /^lsn=/ {sub("lsn=", "", $3); print $3}' "$o.pgstat")
    lsn1=$(awk '$1 == "end" && $3 ~ /^lsn=/ {sub("lsn=", "", $3); print $3}' "$o.pgstat")
    echo "pg_waldump --stats $lsn0 .. $lsn1" > "$o.waldump"
    sudo -u "$PGUSER" "$PG_BIN/pg_waldump" --stats -p "$PG_DATA/pg_wal" -s "$lsn0" -e "$lsn1" \
      >> "$o.waldump" 2>&1
  fi
  if [[ "$PROFILE" == "diag" ]]; then profile_diag "$1"; fi
  return 0
}

# The diagnosis window after a measurement (PROFILE=diag): profile_diag <label>.
# A second sysbench run at the same thread count keeps the load while the
# instruments run one after the other.
profile_diag() {
  local -; set +e   # run_main.sh runs under set -e; a failed collector must not stop it
  local o="$RESULT_DIR/$1.diag" tools=() t total sb
  if [[ -n "$DIAG_TOOLS" ]]; then
    tools=($DIAG_TOOLS)
  else
    [[ "$DBMS" == "mysql" ]] && tools+=(freepage)
    [[ "$FS" == zfs* ]] && tools+=(perf_record perf_lock)
    [[ "$DBMS" == "postgres" && "$FPW" == "on" ]] && tools+=(waldump)
  fi
  (( ${#tools[@]} )) || return 0
  total=$(( DIAG_SETTLE_S + ${#tools[@]} * (DIAG_WINDOW_S + 10) + 10 ))
  echo "--> Diagnosis $1 (${tools[*]}, load ${total}s)"
  sysbench $WORKLOAD "${SB_ARGS[@]}" --threads=$THREADS --time=$total \
    $(seed_opt $((90000 + THREADS))) --report-interval=10 run > "$o.sysbench.log" 2>&1 &
  sb=$!
  sleep "$DIAG_SETTLE_S"
  for t in "${tools[@]}"; do
    "diag_$t" "$o"
    sleep 10
  done
  wait "$sb"
  if [[ -e "$o.perf.data" ]]; then
    PERF="$PERF_BIN" python3 "$TAUFS_BENCH/scripts/sysbench/perf_zfs.py" "$o.perf.data" "$o.perf_lock" \
      > "$o.perf.zfs" 2>&1
  fi
  return 0
}

# MySQL: free-page waits per thread over DIAG_WINDOW_S, with the counters
# (commits, wait_free, INNODB_METRICS) of the same window
diag_freepage() {
  local o=$1.freepage bt i
  sed "s|MYSQLD|$MYSQL_BIN/mysqld|g" "$PROFILE_FREEPAGE_BT" > "$o.bt.script"
  sudo bpftrace "$o.bt.script" "$MYSQLD_PID" > "$o.bt" 2>&1 &
  bt=$!
  for (( i = 0; i < 60; i++ )); do
    grep -q "^window_begin_ns" "$o.bt" 2>/dev/null && break
    sleep 1
  done
  diag_mysql_counters begin "$o"
  sleep "$DIAG_WINDOW_S"
  diag_mysql_counters end "$o"
  sudo kill -INT "$bt" 2>/dev/null
  wait "$bt" 2>/dev/null
}

# MySQL: where the user threads' time goes over DIAG_WINDOW_S: per-thread
# schedstat (on a CPU, waiting for one; the rest is blocked) and offcpu.bt
# (blocked time by stack), with the counters of the same window
diag_offcpu() {
  local o=$1.offcpu bt i
  sudo env BPFTRACE_MAX_MAP_KEYS=200000 bpftrace "$PROFILE_OFFCPU_BT" "$MYSQLD_PID" > "$o.bt" 2>&1 &
  bt=$!
  for (( i = 0; i < 60; i++ )); do
    grep -q "^window_begin_ns" "$o.bt" 2>/dev/null && break
    sleep 1
  done
  diag_mysql_counters begin "$o"
  diag_schedstat begin "$o"
  sleep "$DIAG_WINDOW_S"
  diag_schedstat end "$o"
  diag_mysql_counters end "$o"
  sudo kill -INT "$bt" 2>/dev/null
  wait "$bt" 2>/dev/null
}

diag_schedstat() {  # <begin|end> <out prefix>: per mysqld thread: tid, name, ns on a CPU, ns waiting for one, timeslices
  local t
  {
    echo "$1 time=$(date -u +%s.%N)"
    for t in /proc/$MYSQLD_PID/task/*; do
      echo "$1 ${t##*/} $(tr -d ' ' < "$t/comm") $(cat "$t/schedstat")"
    done
  } >> "$2.schedstat" 2>/dev/null
}

diag_mysql_counters() {  # <begin|end> <out prefix>
  echo "$1 time=$(date -u +%s.%N) $(my_q "SHOW GLOBAL STATUS WHERE Variable_name IN
      ('Com_commit', 'Innodb_buffer_pool_wait_free', 'Innodb_buffer_pool_pages_flushed',
       'Innodb_buffer_pool_reads', 'Innodb_data_fsyncs', 'Innodb_os_log_fsyncs')" \
    | awk '{printf "%s=%s ", $1, $2}')" >> "$2.status"
  my_q "SELECT NAME, COUNT FROM information_schema.INNODB_METRICS
        WHERE NAME LIKE 'buffer_LRU%' OR NAME LIKE 'buffer_flush_sync%'
           OR NAME LIKE 'buffer_flush_single%'" | sed "s/^/$1 /" >> "$2.metrics"
}

# ZFS: system-wide CPU profile, kernel and user stacks. The dso report keeps
# the [zfs]/[spl] modules apart; the symbol reports resolve the module symbols
# from /proc/kallsyms (merging their dso into [kernel.kallsyms])
diag_perf_record() {
  local o=$1.perf
  sudo "$PERF_BIN" record -a -g -F 99 -o "$o.data" -- sleep "$DIAG_WINDOW_S" > "$o.record.log" 2>&1
  sudo "$PERF_BIN" report -i "$o.data" --no-children --sort dso -g none --stdio 2>/dev/null \
    | grep -v '^#' | grep '%' | head -40 > "$o.dso"
  sudo "$PERF_BIN" report -i "$o.data" --kallsyms=/proc/kallsyms --no-children --sort dso,sym \
    -g none --stdio 2>/dev/null | grep -v '^#' | grep '%' | head -80 > "$o.sym"
  sudo "$PERF_BIN" report -i "$o.data" --no-children --sort comm,dso -g none --stdio 2>/dev/null \
    | grep -v '^#' | grep '%' | head -40 > "$o.comm"
  sudo "$PERF_BIN" report -i "$o.data" --kallsyms=/proc/kallsyms --no-children --sort sym \
    -g caller,0.5,callee,function,percent --percent-limit 1 --stdio 2>/dev/null \
    | head -4000 > "$o.callgraph"
  sudo chown "$(id -u):$(id -g)" "$o.data"   # after the reports: perf report refuses other users' files
}

# ZFS: the most contended locks (kernel mutexes, rwsems, spinlocks) by caller, with stacks
diag_perf_lock() {
  sudo "$PERF_BIN" lock contention -a -b -E 25 --max-stack 16 -v -- sleep "$DIAG_WINDOW_S" \
    > "$1.perf_lock" 2>&1
}

# PG with FPW: how much of the WAL is full-page images, over DIAG_WAL_S of load
diag_waldump() {
  local o=$1.waldump lsn0 lsn1
  pg_q "ALTER SYSTEM SET wal_keep_size = '$PG_DIAG_WAL_KEEP'" >/dev/null
  pg_q "SELECT pg_reload_conf()" >/dev/null
  sleep 2
  lsn0=$(pg_q "SELECT pg_current_wal_lsn()")
  sleep "$DIAG_WAL_S"
  lsn1=$(pg_q "SELECT pg_current_wal_lsn()")
  echo "pg_waldump --stats $lsn0 .. $lsn1 (${DIAG_WAL_S}s)" > "$o"
  sudo -u "$PGUSER" "$PG_BIN/pg_waldump" --stats -p "$PG_DATA/pg_wal" -s "$lsn0" -e "$lsn1" >> "$o" 2>&1
  pg_q "ALTER SYSTEM RESET wal_keep_size" >/dev/null
  pg_q "SELECT pg_reload_conf()" >/dev/null
}
