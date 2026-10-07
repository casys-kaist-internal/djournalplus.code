#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

# Can be given in the environment, e.g. TARGET_FILESYSTEM=ext4-dj20
TARGET_FILESYSTEM="${TARGET_FILESYSTEM-ext4 xfs}"

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"

SB_TABLES=($MAIN_TABLES)

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$MODE


command -v sysbench >/dev/null || { echo "sysbench not found"; exit 1; }
command -v partclone.ext4 >/dev/null || { echo "partclone.ext4 not found"; exit 1; }
mkdir -p "$BACKUP_DIR"

for FS in ${TARGET_FILESYSTEM}; do
  # partclone will not overwrite an image; fail before the hour of loading
  if [ -e "$BACKUP_DIR/${FS}_$(main_image_key).img" ]; then
    echo "❌ $BACKUP_DIR/${FS}_$(main_image_key).img exists; move it away first"
    exit 1
  fi
done

for FS in ${TARGET_FILESYSTEM}; do
  for TABLE in "${SB_TABLES[@]}"; do
    echo "=== Setting up FS: $FS in device($DEVICE) ==="
    do_mkfs $FS $DEVICE
    mount_fs $FS $MOUNT_DIR

    case "$MODE" in
      postgres)
      DBNAME="main_t${TABLE}"
      ROWS=$MAIN_ROWS_PER_TABLE

      PG_DATA="$MOUNT_DIR/pgsql_data"
      sudo mkdir -p $PG_DATA
      sudo chown -R $PGUSER:$PGUSER $PG_DATA
      LOG_DIR=$(db_log_dir $FS)
      if [[ -n "$LOG_DIR" ]]; then
        # the WAL in its own dataset (do_mkfs); pg_wal becomes a symlink to it
        sudo chown $PGUSER:$PGUSER "$LOG_DIR"
        $PG_BIN/initdb -D $PG_DATA --waldir="$LOG_DIR/pg_wal"
      else
        $PG_BIN/initdb -D $PG_DATA
      fi
      pg_fpw $PG_DATA "off"
      case $FS in btrfs|zfs*) pg_cow_settings $PG_DATA ;; esac
      $PG_BIN/pg_ctl -D $PG_DATA start

      echo "[*] Create DB & sysbench prepare"
      $PG_BIN/createdb $DBNAME

      sysbench --db-driver=pgsql \
          --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
          --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
          oltp_read_write --tables="$SB_TABLES" --table-size="$ROWS" prepare

      # Freeze the loaded rows now (also sets hint bits and the visibility map).
      # Otherwise every restored run spends its measurements in aggressive
      # autovacuums that freeze the whole freshly loaded dataset (2026-09-29).
      $PG_BIN/vacuumdb -d "$DBNAME" --freeze --analyze --jobs="$SB_TABLES"
      $PG_BIN/psql -d postgres -c "CHECKPOINT;"

      echo "[*] Stop PostgreSQL"
      $PG_BIN/pg_ctl -D $PG_DATA -t 600 stop
      ;;
      mysql)
      MY_DATA="$MOUNT_DIR/mysql_data"
      MY_SOCK="$MY_DATA/mysql.sock"
      DBNAME="main_t${TABLE}"
      ROWS=$MAIN_ROWS_PER_TABLE

      echo "[*] Initialize MySQL datadir"
      sudo mkdir -p $MY_DATA
      sudo chown -R $MYUSER:$MYUSER $MY_DATA
      LOG_DIR=$(db_log_dir $FS)
      MY_FS_ARGS=()
      if [[ -n "$LOG_DIR" ]]; then
        # the redo log in its own dataset (do_mkfs): <LOG_DIR>/#innodb_redo
        sudo chown $MYUSER:$MYUSER "$LOG_DIR"
        MY_FS_ARGS=(--innodb_log_group_home_dir="$LOG_DIR")
      fi
      # native AIO off on ZFS, as in run_main.sh
      case $FS in zfs*) MY_FS_ARGS+=(--innodb_use_native_aio=OFF) ;; esac
      echo "[*] Initialize MySQL"
      # Redo log at the run-time capacity from the start: InnoDB pre-creates all
      # 32 redo files and keeps them through shutdown, so a restored image does
      # not spend its first ~16 GB of redo creating files at about half speed.
      $MYSQL_BIN/mysqld --initialize-insecure --datadir="$MY_DATA" \
          --innodb_redo_log_capacity=$MY_REDO_LOG_CAPACITY "${MY_FS_ARGS[@]}"

      # No binlog while loading, or the prepare binlogs (~ the data size) end up
      # in the image. Benchmark runs have no binlog either (MY_BINLOG in mysql/api.sh).
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
          --disable-log-bin \
          --innodb_redo_log_capacity=$MY_REDO_LOG_CAPACITY \
          "${MY_FS_ARGS[@]}" \
          --log-error="$MY_DATA/mysqld.err" &

      wait_for_sock "$MY_SOCK" 60

      # This option can reduce prepare time, but performance may vary.
      # Not using this option when evaluating performance.
      # --sync_binlog=0 \
      # --innodb_buffer_pool_size=140G \
      # --innodb_flush_log_at_trx_commit=0 \
      # Also, use threads=32 for sysbench prepare for faster loading.

      echo "[*] Create DB & sysbench prepare"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
      sysbench --db-driver=mysql \
          --mysql-user=root --mysql-socket="$MY_SOCK" --mysql-db="$DBNAME" \
          oltp_read_write --threads=32 --tables="$SB_TABLES" --table-size="$ROWS" prepare

      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
      $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
      sleep 5
      echo "[*] Redo log in the image: $(ls "${LOG_DIR:-$MY_DATA}/#innodb_redo" | wc -l) files, $(du -sh "${LOG_DIR:-$MY_DATA}/#innodb_redo" | cut -f1)"
      ;;
    esac
    sleep 1
    echo "[*] Unmount before imaging"
    umount_fs "$MOUNT_DIR"
    sleep 1
    create_backup_fs_image $FS "$(main_image_key)" $BACKUP_DIR

    echo "[✓] Done: $BACKUP_DIR/${FS}_$(main_image_key).img"
  done
  echo "=== FS: $FS Done ==="
  if [ "$FS" == "zfs" ] || [[ "$FS" == zfs-* ]]; then
    clear_fs $FS $DEVICE
  fi
done

echo "All done."
