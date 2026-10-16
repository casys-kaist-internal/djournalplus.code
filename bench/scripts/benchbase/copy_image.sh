#!/bin/bash
# TPC-C images of the other file systems from the ext4 one (create_image.sh):
# the same database, laid out by one sequential copy instead of hours of
# loading per file system. The ext4 image's data directory is archived once on
# the backup disk (<db>/datadir_tpcc_w<WH>.tar); then for every FS in
# TARGET_FILESYSTEM: a fresh FS on the test SSD, the archive extracted into it
# (zfs-8k/16k: the WAL/redo moved to zfspool/log, as sysbench's
# create_image.sh does), and a <db>/<fs>_tpcc_w<WH>.img image for run_tpcc.sh.
# Sizes and the log go to $TAU_RESULTS/benchbase/copy_<db>_<ts>/.
# Usage: TARGET_FILESYSTEM="xfs ext4-dj40 zfs-8k" copy_image.sh <postgres|mysql> [warehouses (1100)]
set -e
MODE="$1"
WH="${2:-1100}"
[[ "$MODE" == "postgres" || "$MODE" == "mysql" ]] || { echo "Usage: $0 <postgres|mysql> [warehouses]"; exit 1; }
[[ -n "$TARGET_FILESYSTEM" ]] || { echo "❌ set TARGET_FILESYSTEM"; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
KEY="tpcc_w$WH"
BACKUP_DIR="$TAU_BACKUP_ROOT/benchbase/$MODE"
TAR="$BACKUP_DIR/datadir_$KEY.tar"
case "$MODE" in
  postgres) DDIR=pgsql_data OWNER=$PGUSER ;;
  mysql)    DDIR=mysql_data OWNER=$MYUSER ;;
esac
[[ -e "$TAR" || -e "$BACKUP_DIR/ext4_$KEY.img" ]] || { echo "❌ no $BACKUP_DIR/ext4_$KEY.img (create_image.sh)"; exit 1; }
for FS in $TARGET_FILESYSTEM; do
  [[ "$FS" != ext4 ]] || { echo "❌ ext4 is the source"; exit 1; }
  [[ ! -e "$BACKUP_DIR/${FS}_${KEY}.img" ]] || { echo "❌ $BACKUP_DIR/${FS}_${KEY}.img exists"; exit 1; }
done
OUT="$TAU_RESULTS/benchbase/copy_${MODE}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
exec > >(tee -a "$OUT/copy.log") 2>&1

if [[ ! -e "$TAR" ]]; then
  echo "=== archive the ext4 image's $DDIR $(date -u --rfc-3339=seconds)"
  restore_filesystem ext4 "$KEY" "$BACKUP_DIR"
  mount_fs ext4 "$MOUNT_DIR"
  sudo tar -C "$MOUNT_DIR" -cf "$TAR.tmp" "$DDIR"
  sudo mv "$TAR.tmp" "$TAR"
  umount_fs "$MOUNT_DIR"
  echo "    $(du -h "$TAR" | cut -f1) $(date -u +%T)"
fi

for FS in $TARGET_FILESYSTEM; do
  echo "=== $FS $(date -u --rfc-3339=seconds)"
  do_mkfs $FS "$DEVICE"
  mount_fs $FS "$MOUNT_DIR"
  sudo tar -C "$MOUNT_DIR" -xpf "$TAR"
  LOG_DIR=$(db_log_dir $FS)
  if [[ -n "$LOG_DIR" ]]; then
    sudo chown "$OWNER:$OWNER" "$LOG_DIR"
    case "$MODE" in
      postgres)
        sudo mv "$MOUNT_DIR/$DDIR/pg_wal" "$LOG_DIR/pg_wal"
        sudo ln -s "$LOG_DIR/pg_wal" "$MOUNT_DIR/$DDIR/pg_wal"
        sudo chown -h "$OWNER:$OWNER" "$MOUNT_DIR/$DDIR/pg_wal"
        ;;
      mysql)
        sudo mv "$MOUNT_DIR/$DDIR/#innodb_redo" "$LOG_DIR/"
        ;;
    esac
  fi
  sync
  { echo "datadir_bytes $(sudo du -sbL "$MOUNT_DIR/$DDIR" | cut -f1)"
    [[ -n "$LOG_DIR" ]] && echo "log_bytes $(sudo du -sb "$LOG_DIR" | cut -f1)"
    df -B1 --output=used "$MOUNT_DIR" | tail -1 | awk '{print "fs_used_bytes", $1}'
  } > "$OUT/size_$FS"
  cat "$OUT/size_$FS"
  umount_fs "$MOUNT_DIR"
  echo "--> image $(date -u +%T)"
  create_backup_fs_image $FS "$KEY" "$BACKUP_DIR"
  case $FS in zfs*) clear_fs $FS "$DEVICE" ;; esac
  echo "[✓] $BACKUP_DIR/${FS}_${KEY}.img $(date -u --rfc-3339=seconds)"
done
