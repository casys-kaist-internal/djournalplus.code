#!/bin/bash
# BenchBase TPC-C images for run_tpcc.sh: <warehouses> loaded by BenchBase on a
# fresh file system on the test SSD with the benchmark server settings (FPW/DWB
# off; MySQL without flushing the redo at commit while loading), then PG
# VACUUM FREEZE ANALYZE and a checkpoint, MySQL ANALYZE TABLE and a slow
# shutdown, and a partclone image $TAU_BACKUP_ROOT/benchbase/<db>/<fs>_tpcc_w<WH>.img.
# The load log and the database size go to $TAU_RESULTS/benchbase/image_<db>_<ts>/.
# Usage: [TARGET_FILESYSTEM="ext4 xfs"] create_image.sh <postgres|mysql> [warehouses (1100)]
set -e
MODE="$1"
WH="${2:-1100}"
TERMINALS=32
TARGET_FILESYSTEM="${TARGET_FILESYSTEM:-ext4}"
[[ "$MODE" == "postgres" || "$MODE" == "mysql" ]] || { echo "Usage: $0 <postgres|mysql> [warehouses]"; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
KEY="tpcc_w$WH"
BACKUP_DIR="$TAU_BACKUP_ROOT/benchbase/$MODE"
mkdir -p "$BACKUP_DIR"
for FS in $TARGET_FILESYSTEM; do
  case $FS in
    ext4|xfs) ;;
    *) echo "❌ $FS: only ext4 and xfs are loaded here"; exit 1 ;;
  esac
  # partclone will not overwrite an image; fail before the hours of loading
  [[ ! -e "$BACKUP_DIR/${FS}_${KEY}.img" ]] || { echo "❌ $BACKUP_DIR/${FS}_${KEY}.img exists"; exit 1; }
done
OUT="$TAU_RESULTS/benchbase/image_${MODE}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
source "$TAUFS_BENCH/scripts/benchbase/tpcc_lib.sh"
exec > >(tee -a "$OUT/image.log") 2>&1
git -C "$TAUFS_BENCH/benchbase" log -1 --format='benchbase %h %cs' > "$OUT/versions"
java -version 2>&1 | head -1 >> "$OUT/versions"

for FS in $TARGET_FILESYSTEM; do
  echo "=== $MODE TPC-C image: $WH warehouses, $FS on $DEVICE $(date -u --rfc-3339=seconds)"
  do_mkfs $FS "$DEVICE"
  mount_fs $FS "$MOUNT_DIR"
  [[ "$MODE" == mysql ]] && MY_EXTRA_ARGS="--innodb_flush_log_at_trx_commit=0"
  SERVER_LOG="$OUT/server_$FS.log"
  db_init
  echo "--> load $(date -u +%T)"
  bb_config "$OUT/load_$FS.xml" false 60 0
  bb "load_$FS" --create=true --load=true -d "$OUT/load_$FS"
  echo "    load: $(tr '\n' ' ' < "$OUT/load_$FS.jvm_time")"
  grep -q "^exit=0" "$OUT/load_$FS.jvm_time" || { echo "❌ load failed"; exit 1; }
  echo "--> after the load $(date -u +%T)"
  case "$MODE" in
    postgres)
      $PG_BIN/vacuumdb -h 127.0.0.1 -p "$PG_PORT" -d tpcc --freeze --analyze --jobs=32 > /dev/null
      q "CHECKPOINT"
      echo "db_bytes $(q "SELECT pg_database_size('tpcc')")" > "$OUT/size_$FS"
      du -sb "$PG_DATA" | awk '{print "datadir_bytes", $1}' >> "$OUT/size_$FS"
      db_stop
      ;;
    mysql)
      for t in $(q "SHOW TABLES"); do q "ANALYZE TABLE $t" > /dev/null; done
      echo "db_bytes $(du -sb "$MY_DATA/tpcc" | cut -f1)" > "$OUT/size_$FS"
      du -sb "$MY_DATA" | awk '{print "datadir_bytes", $1}' >> "$OUT/size_$FS"
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0"
      db_stop
      MY_EXTRA_ARGS=""
      ;;
  esac
  echo "warehouses $WH" >> "$OUT/size_$FS"
  cat "$OUT/size_$FS"
  umount_fs "$MOUNT_DIR"
  echo "--> image $(date -u +%T)"
  create_backup_fs_image $FS "$KEY" "$BACKUP_DIR"
  echo "[✓] $BACKUP_DIR/${FS}_${KEY}.img $(date -u --rfc-3339=seconds)"
done
