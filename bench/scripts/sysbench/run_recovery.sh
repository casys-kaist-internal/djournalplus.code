#!/bin/bash
# EVAL_PLAN R2 (recovery time), end to end: crash a database under the sysbench
# oltp_write_only load in its steady state and time the file system's and the
# database's recovery. Per configuration (FS_GROUPS with FS_FPWON / FS_FPWOFF as
# in run_main.sh) and trial (TRIALS, 3), each from a fresh trim and restore of
# the main image (16 tables x 32M rows): the benchmark settings, run_main.sh's
# 10-min warm-up at 64 threads, then the same 64-thread load (a seed per trial)
# and CRASH_AFTER s (300) into it:
#   1. the WAL position and the last checkpoint's redo position (PG
#      pg_control_checkpoint(), InnoDB SHOW ENGINE INNODB STATUS)
#   2. the crash: the file system shut down at once without flushing its log
#      (stock xfs_io -x -c shutdown: the ext4/XFS going-down ioctl with
#      NOLOGFLUSH, as xfstests' godown), then SIGKILL to the database and sysbench
#   3. unmount, then timed: the mount (the file system's journal recovery, τ's
#      recovery on τ configurations) and the database start until it accepts
#      connections (PG: pg_ctl -w, WAL replay and the end-of-recovery checkpoint;
#      MySQL: mysqld until mysqladmin ping answers, InnoDB's redo apply); the
#      server logs keep the redo range and the database's own timings
#   4. a clean shutdown
# MySQL runs with log_error_verbosity=3 (InnoDB's recovery notes). Results:
# $TAU_RESULTS/recovery/<db>/<ts>/, per trial <label>.times (key=value),
# .warmup.log, .sysbench.log, .server.log (before the crash), .restart.log,
# .dmesg; summary.md (recovery_report.py).
# Usage: [FS_GROUPS=ext4 FS_FPWON=ext4 FS_FPWOFF=] [TRIALS=3] [CRASH_AFTER=300]
#        run_recovery.sh <postgres|mysql>
set -e
DBMS="${1:-}"
[[ "$DBMS" == postgres || "$DBMS" == mysql ]] || { echo "Usage: $0 <postgres|mysql>"; exit 1; }
[ -n "$TAUFS_ENV_SOURCED" ] || { echo "Do source set_env.sh first."; exit 1; }
FS_GROUPS="${FS_GROUPS-ext4}"
FS_FPWON="${FS_FPWON-ext4}"
FS_FPWOFF="${FS_FPWOFF-}"
TRIALS=${TRIALS:-3}
CRASH_AFTER=${CRASH_AFTER:-300}
WARMUP_TIME=${WARMUP_TIME:-600}
THREADS=64
SEED_WARMUP=1   # run_main.sh's
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"
XFS_IO="$STOCK_DIR/usr/sbin/xfs_io"
[[ -x "$XFS_IO" ]] || { echo "❌ no stock xfs_io (install_stock_mkfs.sh)"; exit 1; }
bash "$TAUFS_BENCH/scripts/host_setup.sh" check || { echo "❌ run bench/scripts/host_setup.sh apply"; exit 1; }
if [[ -n "$TAU_BASE_KERNEL" && "$(uname -r)" != "$TAU_BASE_KERNEL" && " $FS_GROUPS " != *tau* ]]; then
  echo "❌ Baseline runs need kernel $TAU_BASE_KERNEL (running $(uname -r))"; exit 1
fi
TABLE=$MAIN_TABLES
ROWS=$MAIN_ROWS_PER_TABLE
IMAGE_KEY=$(main_image_key)
BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$DBMS
DBNAME="main_t${TABLE}"
for FS in $FS_GROUPS; do
  [[ -f "$BACKUP_DIR/${FS}_${IMAGE_KEY}.img" ]] || { echo "❌ Missing image $BACKUP_DIR/${FS}_${IMAGE_KEY}.img"; exit 1; }
  case $FS in zfs*|btrfs*) echo "❌ $FS: the going-down ioctl is for ext4 and XFS"; exit 1 ;; esac
done
OUT="$TAU_RESULTS/recovery/$DBMS/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1
cp "$0" "$OUT/"
echo "=== R2 recovery: $DBMS, FS $FS_GROUPS (FPW/DWB on: $FS_FPWON; off: $FS_FPWOFF), $TRIALS trials," \
  "warm-up ${WARMUP_TIME} s, crash ${CRASH_AFTER} s into the $THREADS-thread load $(date -u --rfc-3339=seconds)"
log_env "$OUT/env.txt"

now() { date +%s.%N; }
since() { awk -v a="$(now)" -v b="$1" 'BEGIN {printf "%.3f", a - b}'; }

case "$DBMS" in
  postgres)
    PG_DATA="$MOUNT_DIR/pgsql_data"
    q() { $PG_BIN/psql -XAt -h 127.0.0.1 -p "$PG_PORT" -U "$PGUSER" -d "$DBNAME" -c "$1"; }
    db_settings() {
      pg_fpw "$PG_DATA" "$FPW"
      pg_fixed_settings "$PG_DATA"
    }
    db_start() {
      $PG_BIN/pg_ctl -D "$PG_DATA" -l "$1" -w -t 3600 start > /dev/null
      PG_PM=$(head -1 "$PG_DATA/postmaster.pid")   # unreadable once the file system is down
    }
    db_stop() { $PG_BIN/pg_ctl -D "$PG_DATA" -t 600 stop; }
    db_positions() {
      q "SELECT 'lsn=' || pg_current_wal_lsn() || ' redo_lsn=' || redo_lsn || ' checkpoint_lsn=' || checkpoint_lsn
           || ' wal_since_redo=' || pg_wal_lsn_diff(pg_current_wal_lsn(), redo_lsn)
           || ' checkpoint_time=' || extract(epoch from checkpoint_time) FROM pg_control_checkpoint()"
    }
    db_kill() {
      local pids
      pids="$PG_PM $(pgrep -P "$PG_PM" | tr '\n' ' ')"
      kill -9 $pids 2>/dev/null || true
      while ps -p "$(echo $pids | tr ' ' ',')" > /dev/null; do sleep 0.1; done
    }
    db_after_remount() { rm -f "$PG_DATA/postmaster.pid"; }   # every PG process is gone
    SB_ARGS=(--db-driver=pgsql --auto_inc=on --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT"
             --pgsql-user="$PGUSER" --pgsql-db="$DBNAME")
    ;;
  mysql)
    MY_DATA="$MOUNT_DIR/mysql_data"
    MY_SOCK="$MY_DATA/mysql.sock"
    MY_EXTRA_ARGS="$MY_EXTRA_ARGS --log-error-verbosity=3"
    q() { $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -NBe "$1"; }
    db_settings() { if [[ "$FPW" == on ]]; then DBW=ON; else DBW=OFF; fi; }
    db_start() {
      start_mysqld "$MY_DATA" "$MY_SOCK" "$DBW" "$1" || true   # its socket wait ends after 120 s
      until $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" ping > /dev/null 2>&1; do
        kill -0 "$MYSQLD_PID" 2>/dev/null || { echo "❌ mysqld exited"; return 1; }
        sleep 0.1
      done
    }
    db_stop() { $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown; wait "$MYSQLD_PID" || true; }
    db_positions() {
      q "SHOW ENGINE INNODB STATUS\G" | awk '
        /^Log sequence number/ {lsn = $NF} /^Last checkpoint at/ {ck = $NF}
        END {print "lsn=" lsn, "checkpoint_lsn=" ck, "redo_since_checkpoint=" lsn - ck}'
    }
    db_kill() { kill -9 "$MYSQLD_PID" 2>/dev/null || true; wait "$MYSQLD_PID" 2>/dev/null || true; }
    # a socket file left by the killed server would answer the start's wait at once
    db_after_remount() { rm -f "$MY_SOCK" "$MY_SOCK.lock"; }
    SB_ARGS=(--db-driver=mysql --mysql-user=root --mysql-socket="$MY_SOCK" --mysql-db="$DBNAME")
    ;;
esac
SB_ARGS+=(--tables=$TABLE --table-size=$ROWS --rand-type=special)

for FS in $FS_GROUPS; do
  for FPW in on off; do
    if [[ "$FPW" == off && " $FS_FPWOFF " != *" $FS "* ]] || [[ "$FPW" == on && " $FS_FPWON " != *" $FS "* ]]; then
      continue
    fi
    for (( trial = 1; trial <= TRIALS; trial++ )); do
      LABEL="${DBMS}_recovery_${FS}_fpw_${FPW}_t${TABLE}_c${THREADS}_r${trial}"
      T="$OUT/$LABEL.times"
      echo "=== $LABEL: restoring ${FS}_${IMAGE_KEY} on $DEVICE $(date -u +%T)"
      restore_filesystem $FS "$IMAGE_KEY" "$BACKUP_DIR"
      mount_fs $FS "$MOUNT_DIR"
      echo "fs=$FS fpw=$FPW trial=$trial threads=$THREADS warmup_s=$WARMUP_TIME crash_after_s=$CRASH_AFTER" > "$T"
      echo "mount_options=$(findmnt -no OPTIONS "$MOUNT_DIR" | head -1)" >> "$T"
      db_settings
      db_start "$OUT/$LABEL.server.log"
      echo "--> warm-up ${WARMUP_TIME} s $(date -u +%T)"
      sysbench oltp_write_only "${SB_ARGS[@]}" --threads=$THREADS --time=$WARMUP_TIME \
        --rand-seed=$SEED_WARMUP --report-interval=10 run > "$OUT/$LABEL.warmup.log"
      echo "--> load, crash in ${CRASH_AFTER} s $(date -u +%T)"
      sysbench oltp_write_only "${SB_ARGS[@]}" --threads=$THREADS --time=$((CRASH_AFTER + 600)) \
        --rand-seed=$((2000 + trial)) --report-interval=10 run > "$OUT/$LABEL.sysbench.log" 2>&1 &
      sb=$!
      sleep "$CRASH_AFTER"
      echo "before_crash $(db_positions)" >> "$T"
      dmesg_n=$(sudo dmesg | wc -l)
      t0=$(now)
      sudo "$XFS_IO" -x -c shutdown "$MOUNT_DIR"
      echo "crash_epoch=$t0" >> "$T"
      kill -9 "$sb" 2>/dev/null || true
      db_kill
      wait "$sb" 2>/dev/null || true
      echo "kill_s=$(since "$t0")" >> "$T"
      echo "--> crashed $(date -u +%T); unmount, mount, restart"
      t0=$(now)
      for (( i = 0; i < 60; i++ )); do sudo umount "$MOUNT_DIR" && break; sleep 1; done
      echo "umount_s=$(since "$t0")" >> "$T"
      drop_caches   # the restart reads from the device, as after a power loss
      t0=$(now)
      mount_fs $FS "$MOUNT_DIR"
      echo "mount_s=$(since "$t0")" >> "$T"
      db_after_remount
      t0=$(now)
      db_start "$OUT/$LABEL.restart.log"
      echo "db_start_s=$(since "$t0")" >> "$T"
      sudo dmesg | tail -n +$((dmesg_n + 1)) > "$OUT/$LABEL.dmesg"
      echo "after_restart $(db_positions)" >> "$T"
      cat "$T"
      db_stop
      umount_fs "$MOUNT_DIR"
      clear_fs $FS "$DEVICE"
    done
  done
done
python3 "$TAUFS_BENCH/scripts/sysbench/recovery_report.py" "$OUT" > "$OUT/summary.md" || true
echo "=== done $(date -u --rfc-3339=seconds) -> $OUT"
