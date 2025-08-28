#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
source "$TAUFS_BENCH/scripts/tpcc/common.sh"

declare -A REPLACEMENTS

for FS in ${TARGET_FILESYSTEM}; do
  for WAREHOUSE in "${WAREHOUSE_LIST[@]}"; do
    echo "=== Setting up FS: $FS in device($DEVICE) ==="
    if [[ "$MODE" == "mysql" && "$FS" == "zfs" ]]; then
      do_mkfs "zfs-16k" $DEVICE
    else
      do_mkfs $FS $DEVICE
    fi
    mount_fs $FS $MOUNT_DIR

    REPLACEMENTS=(
      ["VU"]="$(( $WAREHOUSE < 32 ? $WAREHOUSE : 32 ))"
      ["WAREHOUSE"]="$WAREHOUSE"
    )
    LABEL="w${WAREHOUSE}"
    BACKUP_DIR=$TAU_BACKUP_ROOT/tpcc/$MODE
    mkdir -p "$BACKUP_DIR"

    case "$MODE" in
      postgres)
      PG_DATA="$MOUNT_DIR/postgres"
      sudo mkdir -p $PG_DATA
      sudo chown -R $PGUSER:$PGUSER $PG_DATA
      $PG_BIN/initdb -D $PG_DATA -U $PGUSER
      pg_fpw $PG_DATA "off"
      $PG_BIN/pg_ctl -D $PG_DATA start

      echo "[*] Create DB & hammerdb prepare"
      $PG_BIN/psql -U $PGUSER -d postgres -c "CREATE USER $APP_USER WITH SUPERUSER PASSWORD '$APP_PASS';"
      $PG_BIN/createdb -U $PGUSER $DBNAME

      BUILD_TCL="$HAMMERDB/build_postgres_${LABEL}.tcl"
      render_tcl_template "$HAMMERDB/build_postgres_template.tcl" $BUILD_TCL REPLACEMENTS

      pushd $HAMMERDB
      ./hammerdbcli auto $BUILD_TCL
      popd

      $PG_BIN/psql -U $PGUSER -d $DBNAME -c "ANALYZE;"
      $PG_BIN/psql -U $PGUSER -d postgres -c "CHECKPOINT;"

      mkdir -p "$RESULT_DIR/$MODE"
      log_pg_specs "$RESULT_DIR/$MODE/${FS}_${LABEL}.spec" $DBNAME

      echo "[*] Stop PostgreSQL"
      $PG_BIN/pg_ctl -D $PG_DATA stop
      ;;
      mysql)
      MY_DATA="$MOUNT_DIR/mysql"
      MY_SOCK="$MY_DATA/mysql.sock"
      REPLACEMENTS["MYSOCKET"]=$MY_SOCK

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
          --log-error="$MY_DATA/mysqld.err" &
      wait_for_sock "$MY_SOCK" 60

      echo "[*] Create DB & hammerdb prepare"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "CREATE USER '$APP_USER'@'localhost' IDENTIFIED BY '$APP_PASS';"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "GRANT ALL PRIVILEGES ON *.* TO '$APP_USER'@'localhost' WITH GRANT OPTION;"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "FLUSH PRIVILEGES;"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
      BUILD_TCL="$HAMMERDB/build_mysql_${LABEL}.tcl"
      render_tcl_template "$HAMMERDB/build_mysql_template.tcl" $BUILD_TCL REPLACEMENTS

      pushd $HAMMERDB
      ./hammerdbcli auto $BUILD_TCL
      popd

      mkdir -p "$RESULT_DIR/$MODE"
      log_mysql_specs $MY_SOCK "$RESULT_DIR/$MODE/${FS}_${LABEL}.spec" $DBNAME

      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
      $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
      ;;
    esac
    sleep 1
    echo "[*] Unmount before imaging"
    umount_fs "$MOUNT_DIR"
    sleep 1
    create_backup_fs_image $FS $LABEL $BACKUP_DIR

    echo "[✓] Done: $OUT_IMG"
  done
  echo "=== FS: $FS Done ==="
  clear_fs $FS $DEVICE
done

echo "All done."