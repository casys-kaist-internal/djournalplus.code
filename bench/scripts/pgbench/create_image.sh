#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

SCALE_LIST=(1000)
TARGET_FILESYSTEM="ext4"

PG_BIN="$TAUFS_BENCH_WS/pg_install/bin"
PGUSER=$TAU_USERNAME
DEVICE=$TAU_DEVICE
BACKUP_DIR=$TAU_BACKUP_ROOT/pgbench
MOUNT_DIR="/mnt/temp"

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/pgbench/pg_ctl.sh"

start_postgres() {
  $PG_BIN/pg_ctl -D $PG_DATA start
}

stop_postgres() {
  $PG_BIN/pg_ctl -D $PG_DATA stop
}

init_postgres() {
  $PG_BIN/initdb -D $PG_DATA
  start_postgres
}

sudo mkdir -p "$BACKUP_DIR"

# MAIN LOOP
for FS in ${TARGET_FILESYSTEM}; do
  for SCALE in "${SCALE_LIST[@]}"; do
    echo "=== Setting up FS: $FS in device($DEVICE) ==="
    do_mkfs $FS $DEVICE
    mount_fs $FS $MOUNT_DIR
  
    PG_DATA="$MOUNT_DIR/postgre"
    sudo mkdir -p $PG_DATA
    sudo chown -R $PGUSER:$PGUSER $PG_DATA

    PGDB="pgbench_s${SCALE}"
    echo "[+] Initializing PostgreSQL: scale=$SCALE"
    $PG_BIN/initdb -D $PG_DATA
    pg_fpw_off $PG_DATA
    $PG_BIN/pg_ctl -D $PG_DATA start
    echo "[+] Creating database: $PGDB"
    $PG_BIN/createdb $PGDB
    $PG_BIN/pgbench -i -s $SCALE $PGDB
    $PG_BIN/psql -d postgres -c "CHECKPOINT;"
    $PG_BIN/pg_ctl -D $PG_DATA stop
    sleep 1
    umount_fs $MOUNT_DIR
    sleep 1
    sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/${FS}_s${SCALE}.img"
  done
  echo "=== FS: $FS Done ==="
  clear_fs $FS $DEVICE
done
