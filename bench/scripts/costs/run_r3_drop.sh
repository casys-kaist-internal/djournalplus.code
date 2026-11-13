#!/bin/bash
# EVAL_PLAN R3 (§6.5 Costs), item 3: DROP TABLE of one sysbench table on a
# running database, tau-EXT4 against EXT4_App, PostgreSQL and MySQL.
#
# Per configuration and WRITE_TIMES entry: the database in place (SOURCE=image:
# the main image, restored as run_main.sh restores it, t16_r32000000 = 16 tables
# of 32M rows; SOURCE=prepare: a new file system and PREP_TABLES tables of
# PREP_ROWS rows, for a short check), started with run_main.sh's settings
# (FPW/doublewrite on for *_App, off for tau), then WRITE_TIME s of
# oltp_write_only at WRITE_THREADS threads (rand-type special, as run_main.sh;
# 0: none, so the table has nothing in the tau journal), then
#
#   DROP TABLE $DROP_TABLE   (sbtest1)
#
# through the database's client, timed by the client (lat_ms: the call, with
# connecting) and by the server (server_ms: PostgreSQL's \timing; MySQL's
# performance_schema TIMER_WAIT of the statement).  PostgreSQL truncates the
# main fork of the table, its indexes and its owned sequence to 0, unlinks their
# _fsm/_vm forks and any segment past the first at once, and the first segments
# at the next checkpoint (md.c mdunlinkfork); InnoDB unlinks the .ibd.
# Between the write phase and the DROP the database writes its dirty pages
# (PostgreSQL CHECKPOINT, InnoDB down to no dirty page), and r3op.py waits for
# the device to be quiet (up to 30 s; "quiet" says whether it was).
# Around it r3op.py measure: the device's writes during the statement and in
# the DROP_AFTER s after it (then a syncfs), split into "home" (the blocks of the
# table's files before the DROP) and the rest; the tau journal's used segments
# before and as a time series after; the tau probe counters where the kernel has
# them.  r3_calls.bt runs from the database's start: the truncate/unlink calls of
# the write phase and of the DROP (r3_calls_report.py, <run>.r3calls.txt).
#
# Configurations: EXT4_App (ext4, FPW on), tau-EXT4 (ext4-tau, FPW off); also
# EXT4_Raw (ext4, off), XFS_App (xfs, on), tau-XFS (xfs-tau, off).  The baselines
# run on the base kernel ($TAU_BASE_KERNEL), or with KCHECK=1 on the tau kernel
# (labeled -kcheck), as run_main.sh.
#
# Usage: [CONFIGS="EXT4_App tau-EXT4"] [SOURCE=image|prepare] [WRITE_TIMES="0 300"]
#        [WRITE_THREADS=64] [DROP_TABLE=sbtest1] [DROP_AFTER=30] [REPS=1]
#        [PREP_TABLES=4 PREP_ROWS=6000000] [KCHECK=1] run_r3_drop.sh {postgres|mysql} <tag>
#        CHECK_ONLY=1, HOST_CHECK=0 as run_r3.sh.
# Results: $TAU_RESULTS/r3/<date>_r3drop_<dbms>_<tag>/ (env.txt, results.jsonl,
#          results.csv, summary.md, per run <dbms>_<config>_w<s>_r<rep>.*).
#          SOURCE=image: a restore (~5-10 min for the ~120 GB image) + WRITE_TIME
#          + ~2 min per run: 2 configurations x 2 write times ~ 1 h per database.
set -e
DBMS=${1:-}
TAG=${2:-}
[[ ( $DBMS == postgres || $DBMS == mysql ) && -n $TAG ]] || { echo "usage: run_r3_drop.sh {postgres|mysql} <tag>"; exit 1; }
[ -n "$TAUFS_ENV_SOURCED" ] || { echo "Do source set_env.sh first."; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"
HERE=$TAUFS_BENCH/scripts/costs

KERNEL=$(uname -r)
TAU_KERNEL=0
[[ $KERNEL == *tjournal* ]] && TAU_KERNEL=1
KCHECK=${KCHECK:-0}
if (( TAU_KERNEL )); then
  if (( KCHECK )); then CONFIGS=${CONFIGS:-EXT4_App tau-EXT4}; else CONFIGS=${CONFIGS:-tau-EXT4}; fi
else
  CONFIGS=${CONFIGS:-EXT4_App}
fi
SOURCE=${SOURCE:-image}
WRITE_TIMES=${WRITE_TIMES:-0 300}
WRITE_THREADS=${WRITE_THREADS:-64}
DROP_TABLE=${DROP_TABLE:-sbtest1}
DROP_AFTER=${DROP_AFTER:-30}
REPS=${REPS:-1}
PREP_TABLES=${PREP_TABLES:-4}
PREP_ROWS=${PREP_ROWS:-6000000}

cfg_fs() {
  case $1 in
    EXT4_App|EXT4_Raw) echo ext4 ;;
    XFS_App) echo xfs ;;
    tau-EXT4) echo ext4-tau ;;
    tau-XFS) echo xfs-tau ;;
  esac
}
for c in $CONFIGS; do
  case $c in
    tau-EXT4|tau-XFS)
      (( TAU_KERNEL )) || { echo "❌ $c runs on the tau kernel, not $KERNEL"; exit 1; } ;;
    EXT4_App|EXT4_Raw|XFS_App)
      if (( KCHECK )); then
        (( TAU_KERNEL )) || { echo "❌ KCHECK=1 runs $c on the tau kernel, not $KERNEL"; exit 1; }
      else
        [[ $KERNEL == "${TAU_BASE_KERNEL:-6.8.0-base+}" ]] ||
          { echo "❌ $c runs on the base kernel ${TAU_BASE_KERNEL:-6.8.0-base+}, not $KERNEL (KCHECK=1: on the tau kernel)"; exit 1; }
      fi ;;
    *) echo "❌ unknown configuration $c"; exit 1 ;;
  esac
done
case $SOURCE in
  image)
    TABLE=$MAIN_TABLES; ROWS=$MAIN_ROWS_PER_TABLE
    IMAGE_KEY=$(main_image_key)
    BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS
    for c in $CONFIGS; do
      [[ -f "$(fs_image "$(cfg_fs $c)" "$IMAGE_KEY" "$BACKUP_DIR")" ]] ||
        { echo "❌ Missing image $(fs_image "$(cfg_fs $c)" "$IMAGE_KEY" "$BACKUP_DIR") (create_image.sh $DBMS)"; exit 1; }
    done ;;
  prepare) TABLE=$PREP_TABLES; ROWS=$PREP_ROWS ;;
  *) echo "❌ SOURCE: image or prepare"; exit 1 ;;
esac
command -v sysbench >/dev/null || { echo "❌ no sysbench"; exit 1; }
command -v bpftrace >/dev/null || { echo "❌ no bpftrace"; exit 1; }
[[ -e /sys/kernel/btf/vmlinux || -r "${BPFTRACE_BTF:-}" ]] || { echo "❌ r3_calls.bt needs kernel BTF or BPFTRACE_BTF=<file>"; exit 1; }
[[ -n "$DEVICE" && -b "$DEVICE" ]] || { echo "❌ no test device (TAU_DEVICE)"; exit 1; }
[[ "${CHECK_ONLY:-0}" == 0 ]] || { echo "checks passed: $DBMS | $CONFIGS | $SOURCE | $WRITE_TIMES | $KERNEL"; exit 0; }
if [[ "${HOST_CHECK:-1}" != 0 ]]; then
  bash "$TAUFS_BENCH/scripts/host_setup.sh" check || { echo "❌ run bench/scripts/host_setup.sh apply (HOST_CHECK=0 skips)"; exit 1; }
fi

STATDEV=$(tau_stat_devs)
DBNAME="main_t${TABLE}"
OP=$HERE/r3op.py
if (( KCHECK )); then KSUF=-kcheck; else KSUF=; fi
RESULT_DIR=$TAU_RESULTS/r3/$(date +%Y%m%d_%H%M%S)_r3drop_${DBMS}_$TAG$KSUF
mkdir -p "$RESULT_DIR"
cp "$0" "$OP" "$HERE/r3_report.py" "$HERE/r3_calls.bt" "$HERE/r3_calls_report.py" "$RESULT_DIR/"
JSONL=$RESULT_DIR/results.jsonl
LOG=$RESULT_DIR/run.log
log_env "$RESULT_DIR/env.txt"
{
  echo
  echo "## r3 drop"
  echo "test device: $DEVICE ($(cat /sys/block/$TAU_DEVICE_NAME/device/model 2>/dev/null | xargs), serial $(cat /sys/block/$TAU_DEVICE_NAME/device/serial 2>/dev/null | xargs)), stats from /sys/block/$STATDEV/stat, write_cache $(cat /sys/block/$TAU_DEVICE_NAME/queue/write_cache)"
  echo "kernel: $KERNEL $(uname -v)"
  echo "umbrella: $(git -C "$TAUFS_ROOT" describe --always --dirty --abbrev=12 2>/dev/null) ($(git -C "$TAUFS_ROOT" log -1 --format='%h %s' 2>/dev/null | cut -c1-80)); bench/scripts/costs $(git -C "$TAUFS_ROOT" status --porcelain -- bench/scripts/costs 2>/dev/null | wc -l) uncommitted"
  echo "database: $DBMS, $( [[ $DBMS == postgres ]] && "$PG_BIN/postgres" --version || "$MYSQL_BIN/mysqld" --version 2>/dev/null | sed 's/.*Ver //'); sysbench $(sysbench --version | cut -d' ' -f2)"
  if [[ -d /sys/module/tau_journal/parameters ]]; then
    echo "tau parameters: $(cd /sys/module/tau_journal/parameters && for p in tau_max_transaction_age tau_max_commmit_age tau_cp_small_tx tauvar_force_reclaim tauvar_thres_checkpoint tau_shrink_seeks; do printf '%s=%s ' $p "$(cat $p 2>/dev/null)"; done)"
    echo "tau probe counters: $(ls /sys/module/tau_journal/parameters | grep -c '^tau_probe_') (0: CONFIG_TAU_PROBE_TORN off)"
  fi
  echo "CONFIGS=$CONFIGS SOURCE=$SOURCE TABLES=$TABLE ROWS=$ROWS${IMAGE_KEY:+ IMAGE_KEY=$IMAGE_KEY} WRITE_TIMES=$WRITE_TIMES WRITE_THREADS=$WRITE_THREADS DROP_TABLE=$DROP_TABLE DROP_AFTER=$DROP_AFTER REPS=$REPS TAU_SEGSIZE=$TAU_SEGSIZE TAU_JSIZE=${TAU_JSIZE:-32} KCHECK=$KCHECK"
} >> "$RESULT_DIR/env.txt"
echo "=== r3 drop: $RESULT_DIR ($DBMS | $CONFIGS | $SOURCE t$TABLE x $ROWS | write $WRITE_TIMES s | $KERNEL) $(date -u --rfc-3339=seconds)" | tee -a "$LOG"

mono_ns() { python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC))'; }
mark() { echo "$1 $(mono_ns) $(date -u +%FT%T.%N)" >> "$O.r3calls.marks"; }

db_start() {
  case $DBMS in
    postgres)
      PG_DATA="$MOUNT_DIR/pgsql_data"
      pg_fpw "$PG_DATA" "$FPW"
      pg_fixed_settings "$PG_DATA"
      "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$O.server.log" start
      log_pg_specs "$O.spec" "$DBNAME" "$RUN" ;;
    mysql)
      MY_DATA="$MOUNT_DIR/mysql_data"
      MY_SOCK="$MY_DATA/mysql.sock"
      start_mysqld "$MY_DATA" "$MY_SOCK" "$( [[ $FPW == on ]] && echo ON || echo OFF)" "$O.server.log"
      log_mysql_specs "$MY_SOCK" "$O.spec" "$DBNAME" ;;
  esac
}

db_stop() {
  case $DBMS in
    postgres) "$PG_BIN/pg_ctl" -D "$PG_DATA" -t 600 stop ;;
    mysql) "$MYSQL_BIN/mysqladmin" -uroot --socket="$MY_SOCK" shutdown; wait "$MYSQLD_PID" || true ;;
  esac
}

sb_args() {
  case $DBMS in
    postgres) echo --db-driver=pgsql --auto_inc=on --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
                --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" --tables="$TABLE" --table-size="$ROWS" ;;
    mysql) echo --db-driver=mysql --mysql-user=root --mysql-socket="$MY_SOCK" --mysql-db="$DBNAME" \
             --tables="$TABLE" --table-size="$ROWS" ;;
  esac
}

# SOURCE=prepare: a new file system with the tables, loaded as create_image.sh does
db_prepare() {
  do_mkfs "$FS" "$DEVICE"
  mount_fs "$FS" "$MOUNT_DIR"
  case $DBMS in
    postgres)
      PG_DATA="$MOUNT_DIR/pgsql_data"
      sudo mkdir -p "$PG_DATA"; sudo chown -R "$PGUSER:$PGUSER" "$PG_DATA"
      "$PG_BIN/initdb" -D "$PG_DATA" > "$O.prepare.log" 2>&1
      pg_fpw "$PG_DATA" off
      "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$O.prepare_server.log" start
      "$PG_BIN/createdb" -p "$PG_PORT" "$DBNAME"
      sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" --pgsql-user="$PGUSER" \
        --pgsql-db="$DBNAME" oltp_read_write --threads="$TABLE" --tables="$TABLE" --table-size="$ROWS" prepare \
        >> "$O.prepare.log" 2>&1
      "$PG_BIN/vacuumdb" -p "$PG_PORT" -d "$DBNAME" --freeze --analyze --jobs="$TABLE" >> "$O.prepare.log" 2>&1
      "$PG_BIN/psql" -p "$PG_PORT" -d postgres -c "CHECKPOINT;" >> "$O.prepare.log" 2>&1
      "$PG_BIN/pg_ctl" -D "$PG_DATA" -t 600 stop ;;
    mysql)
      MY_DATA="$MOUNT_DIR/mysql_data"
      MY_SOCK="$MY_DATA/mysql.sock"
      sudo mkdir -p "$MY_DATA"; sudo chown -R "$MYUSER:$MYUSER" "$MY_DATA"
      "$MYSQL_BIN/mysqld" --initialize-insecure --datadir="$MY_DATA" \
        --innodb_redo_log_capacity="$MY_REDO_LOG_CAPACITY" > "$O.prepare.log" 2>&1
      "$MYSQL_BIN/mysqld" --datadir="$MY_DATA" --socket="$MY_SOCK" --port="$MYSQL_PORT" \
        --pid-file="$MY_DATA/mysqld.pid" --bind-address=127.0.0.1 --skip-networking=0 \
        --innodb-doublewrite=0 --innodb_flush_log_at_trx_commit=0 --disable-log-bin \
        --innodb_redo_log_capacity="$MY_REDO_LOG_CAPACITY" --log-error="$O.prepare_server.log" &
      local pid=$!
      wait_for_sock "$MY_SOCK" 120
      "$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
      sysbench --db-driver=mysql --mysql-user=root --mysql-socket="$MY_SOCK" --mysql-db="$DBNAME" \
        oltp_read_write --threads="$TABLE" --tables="$TABLE" --table-size="$ROWS" prepare >> "$O.prepare.log" 2>&1
      "$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
      "$MYSQL_BIN/mysqladmin" -uroot --socket="$MY_SOCK" shutdown
      wait "$pid" || true ;;
  esac
  umount_fs "$MOUNT_DIR"
}

# After the write phase: the database's dirty pages written (PostgreSQL CHECKPOINT;
# InnoDB flushes to 0 dirty pages), then the device left quiet by r3op.py, so the
# DROP's window holds the DROP and not the tail of the load.  What the tau journal
# holds of the table then is what those writes left in it (used segments, before).
db_settle() {
  local t0=$SECONDS i d
  case $DBMS in
    postgres) "$PG_BIN/psql" -XAt -p "$PG_PORT" -d postgres -c "CHECKPOINT;" ;;
    mysql)
      "$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_max_dirty_pages_pct_lwm = 0; SET GLOBAL innodb_max_dirty_pages_pct = 0;"
      for (( i = 0; i < 600; i++ )); do
        d=$("$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -NBe "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_dirty'" | awk '{print $2}')
        (( d < 64 )) && break
        sleep 1
      done ;;
  esac
  echo "settle: $(( SECONDS - t0 )) s" | tee -a "$O.spec"
}

# the files of the table and its indexes (PG: every segment and fork)
table_files() {
  case $DBMS in
    postgres)
      local rel
      for rel in $("$PG_BIN/psql" -XAt -p "$PG_PORT" -d "$DBNAME" -c "
          SELECT pg_relation_filepath(c.oid) FROM pg_class c
          WHERE c.oid = '$DROP_TABLE'::regclass
             OR c.oid IN (SELECT indexrelid FROM pg_index WHERE indrelid = '$DROP_TABLE'::regclass)
             OR c.oid = (SELECT reltoastrelid FROM pg_class WHERE oid = '$DROP_TABLE'::regclass)
             OR c.oid IN (SELECT indexrelid FROM pg_index WHERE indrelid =
                          (SELECT reltoastrelid FROM pg_class WHERE oid = '$DROP_TABLE'::regclass))
             OR c.oid IN (SELECT objid FROM pg_depend WHERE refobjid = '$DROP_TABLE'::regclass
                          AND classid = 'pg_class'::regclass AND deptype IN ('a', 'i'))"); do
        ls -d "$PG_DATA/$rel" "$PG_DATA/$rel".* "$PG_DATA/${rel}"_* 2>/dev/null || true
      done ;;
    mysql) ls -d "$MY_DATA/$DBNAME/$DROP_TABLE.ibd" ;;
  esac
}

run_one() {  # <config> <write s> <rep>
  CFG=$1 WT=$2 REP=$3
  FS=$(cfg_fs "$CFG")
  case $CFG in *_App) FPW=on ;; *) FPW=off ;; esac
  local label=$CFG
  [[ $CFG == tau-* ]] || label=$CFG$KSUF
  RUN=${DBMS}_${label}_w${WT}_r${REP}
  O=$RESULT_DIR/$RUN
  echo "=== $RUN ($FS, FPW $FPW) $(date -u --rfc-3339=seconds)" | tee -a "$LOG"
  if [[ $SOURCE == image ]]; then
    restore_filesystem "$FS" "$IMAGE_KEY" "$BACKUP_DIR"
  else
    db_prepare
  fi
  mount_fs "$FS" "$MOUNT_DIR"
  echo "mount: $(findmnt -no FSTYPE,OPTIONS "$MOUNT_DIR" | head -1)" >> "$O.spec"
  db_start
  log_tau_fds "$O.spec"

  local devnum i
  devnum=$(( (0x$(stat -c %t "$DEVICE") << 20) | 0x$(stat -c %T "$DEVICE") ))
  sudo env ${BPFTRACE_BTF:+BPFTRACE_BTF=$BPFTRACE_BTF} bpftrace "$HERE/r3_calls.bt" "$devnum" > "$O.r3calls" 2>&1 &
  local bt=$!
  for (( i = 0; i < 60; i++ )); do grep -q "^Attaching" "$O.r3calls" 2>/dev/null && break; sleep 1; done
  mark write
  if (( WT > 0 )); then
    echo "--> oltp_write_only, $WRITE_THREADS threads, $WT s" | tee -a "$LOG"
    sysbench oltp_write_only $(sb_args) --rand-type=special --threads="$WRITE_THREADS" --time="$WT" \
      --report-interval=10 run > "$O.write.log" 2>&1
  fi

  (( WT == 0 )) || db_settle
  local files cmd re
  mapfile -t files < <(table_files)
  ls -ls "${files[@]}" > "$O.files" 2>&1 || true
  case $DBMS in
    postgres)
      cmd="sudo -u $PGUSER $PG_BIN/psql -X -p $PG_PORT -d $DBNAME -c '\\timing on' -c 'DROP TABLE $DROP_TABLE'"
      re='Time: ([0-9.]+) ms' ;;
    mysql)
      cmd="$MYSQL_BIN/mysql -uroot --socket=$MY_SOCK -D $DBNAME -NBe \"DROP TABLE $DROP_TABLE; SELECT TIMER_WAIT/1000000000 FROM performance_schema.events_statements_history WHERE THREAD_ID = PS_CURRENT_THREAD_ID() AND SQL_TEXT LIKE 'DROP TABLE%' ORDER BY EVENT_ID DESC LIMIT 1\""
      re='^([0-9.]+)\s*$' ;;
  esac
  mark drop
  echo "--> DROP TABLE $DROP_TABLE (${#files[@]} files, $(du -cb "${files[@]}" 2>/dev/null | tail -1 | cut -f1) bytes)" | tee -a "$LOG"
  sudo env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" python3 "$OP" measure --op cmd --cmd "$cmd" --server-re "$re" \
    --home "${files[@]}" --dev "$TAU_DEVICE_NAME" --statdevs "$STATDEV" --mnt "$MOUNT_DIR" \
    --after-min "$DROP_AFTER" --label dbms=$DBMS config=$label op=drop state=w$WT after=wait rep=$REP \
    files=${#files[@]} >> "$JSONL"
  mark after
  tail -1 "$JSONL" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("  %s %s %s r%s: rc %s  lat %.1f ms  server %s ms  sync %.1f KiB (home %d)  after %.1f KiB (home %d)  used %s -> %s  trace_ok %s" % (
    r["dbms"], r["config"], r["state"], r["rep"], r.get("cmd_rc"), r["lat_ms"], r.get("server_ms"),
    (r["sync_other_bytes"] + r["sync_home_bytes"]) / 1024, r["sync_home_bytes"],
    (r["after_other_bytes"] + r["after_home_bytes"]) / 1024, r["after_home_bytes"],
    r.get("used_before", "-"), r.get("used_end", "-"), r["trace_ok"]))' | tee -a "$LOG"
  sudo kill -INT "$bt" 2>/dev/null || true
  wait "$bt" 2>/dev/null || true
  python3 "$HERE/r3_calls_report.py" "$O.r3calls" > "$O.r3calls.txt" 2>&1 || true
  db_stop
  umount_fs "$MOUNT_DIR"
}

for c in $CONFIGS; do
  for wt in $WRITE_TIMES; do
    for (( rep = 1; rep <= REPS; rep++ )); do
      run_one "$c" "$wt" "$rep"
    done
  done
done
python3 "$HERE/r3_report.py" "$RESULT_DIR"
echo "=== done $(date -u --rfc-3339=seconds): $RESULT_DIR" | tee -a "$LOG"
