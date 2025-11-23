#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

# Motivation Test
# SCALE_LIST=(2500)
# TARGET_FILESYSTEM="ext4 xfs zfs"

SCALE_LIST=(5000)
TARGET_FILESYSTEM="taujournal"
SB_TABLES=32

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/sysbench/$MODE


command -v sysbench >/dev/null || { echo "sysbench not found"; exit 1; }
command -v partclone.ext4 >/dev/null || { echo "partclone.ext4 not found"; exit 1; }
mkdir -p "$BACKUP_DIR"

for FS in ${TARGET_FILESYSTEM}; do
  for SCALE in "${SCALE_LIST[@]}"; do
    echo "=== Setting up FS: $FS in device($DEVICE) ==="
    do_mkfs $FS $DEVICE
    mount_fs $FS $MOUNT_DIR

    case "$MODE" in
      postgres)
      DBNAME="sbtest_s${SCALE}"
      ROWS=$(sysbench_rows_per_table "$SCALE")

      PG_DATA="$MOUNT_DIR/postgres"
      sudo mkdir -p $PG_DATA
      sudo chown -R $PGUSER:$PGUSER $PG_DATA
      $PG_BIN/initdb -D $PG_DATA
      pg_wal_max_set $PG_DATA "16GB"
      pg_fpw $PG_DATA "off"
      $PG_BIN/pg_ctl -D $PG_DATA start

      echo "[*] Create DB & sysbench prepare"
      $PG_BIN/createdb $DBNAME

      sysbench --db-driver=pgsql \
          --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
          --pgsql-user="$PGUSER" --pgsql-db="$DBNAME" \
          oltp_read_write --tables="$SB_TABLES" --table-size="$ROWS" prepare

      $PG_BIN/psql -d "$DBNAME"  -c "ANALYZE;"
      $PG_BIN/psql -d postgres -c "CHECKPOINT;"

      echo "[*] Stop PostgreSQL"
      $PG_BIN/pg_ctl -D $PG_DATA stop
      ;;
      mysql)
      MY_DATA="$MOUNT_DIR/mysql"
      MY_SOCK="$MY_DATA/mysql.sock"
      DBNAME="sbtest_s${SCALE}"
      ROWS=$(sysbench_rows_per_table "$SCALE")

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
          --innodb_buffer_pool_size=140G \
          --innodb_redo_log_capacity=10G \
          --innodb_flush_log_at_trx_commit=0 \
          --sync_binlog=0 \
          --innodb-doublewrite=0 \
          --log-error="$MY_DATA/mysqld.err" &
      wait_for_sock "$MY_SOCK" 60

      echo "[*] Create DB & sysbench prepare"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
      sysbench --db-driver=mysql \
          --mysql-user=root --mysql-socket="$MY_SOCK" --mysql-db="$DBNAME" \
          oltp_read_write --tables="$SB_TABLES" --table-size="$ROWS" prepare

      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
      $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
      ;;
    esac
    sleep 1
    echo "[*] Unmount before imaging"
    umount_fs "$MOUNT_DIR"
    sleep 1
    create_backup_fs_image $FS "s$SCALE" $BACKUP_DIR

    echo "[✓] Done: $OUT_IMG"
  done
  echo "=== FS: $FS Done ==="
  if [ "$FS" == "zfs" ] || [[ "$FS" == zfs-* ]]; then
    clear_fs $FS $DEVICE
  fi
done

echo "All done."
