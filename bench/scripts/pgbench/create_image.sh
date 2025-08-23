#!/bin/bash
set -e

SCALE_LIST=(5000 10000 20000)
TARGET_FILESYSTEM="ext4 zfs"

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/postgres/api.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/pgbench

create_backup_fs_image()
{
  FS=$1
  SCALE=$2
  case $FS in
    ext4)
      sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/${FS}_s${SCALE}.img"
      ;;
    zfs)
      mount_fs $FS $MOUNT_DIR
      sudo zfs snapshot zfspool@pgbackup
      sudo sh -c "zfs send zfspool@pgbackup > '$BACKUP_DIR/${FS}_s${SCALE}.img'"
      umount_fs $MOUNT_DIR
      ;;
    taujournal)
      sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/${FS}_s${SCALE}.img"
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
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
    pg_fpw $PG_DATA "off"
    $PG_BIN/pg_ctl -D $PG_DATA start
    echo "[+] Creating database: $PGDB"
    $PG_BIN/createdb $PGDB
    $PG_BIN/pgbench -i -s $SCALE $PGDB
    $PG_BIN/psql -d postgres -c "CHECKPOINT;"
    $PG_BIN/pg_ctl -D $PG_DATA stop
    sleep 1
    umount_fs $MOUNT_DIR
    sleep 1
    create_backup_fs_image $FS $SCALE
  done
  echo "=== FS: $FS Done ==="
  clear_fs $FS $DEVICE
done
