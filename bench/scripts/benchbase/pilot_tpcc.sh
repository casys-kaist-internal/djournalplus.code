#!/bin/bash
# TPC-C pilot with BenchBase (EVAL_PLAN TPC-C checklist): load <warehouses> on a
# fresh ext4 on the test SSD with the benchmark server settings (FPW/DWB off),
# record the database size per warehouse, then run 32 terminals. RUNS lists the
# runs as name:randomWarehouse:FPW/DWB:measured s:warm-up s; the default is
#   A_home    2 min, upstream terminal binding (each terminal on its home warehouse)
#   B_random  1 min warm-up + 9 min measured, <randomWarehouse>true</randomWarehouse>
# e.g. RUNS="R1:true:off:300:60 App:true:on:300:60 R2:true:off:300:60" for the
# FPW/DWB cost. The database restarts before every run with its FPW/DWB setting.
# Around each run: the districts' d_next_o_id (which warehouses got new orders,
# and the new-order count from the database), the device and WAL/redo/doublewrite
# counters, BenchBase's results (1-s samples, histograms), the JVM's CPU time and
# mpstat (tpcc_lib.sh tpcc_run).
# Usage: [RUNS=...] [TAG=name] pilot_tpcc.sh <postgres|mysql> [warehouses (100)]   (after set_env.sh)
set -e
MODE="$1"
WH="${2:-100}"
TERMINALS=${TERMINALS:-32}
RUNS=${RUNS:-"A_home:false:off:120:0 B_random:true:off:540:60"}
[[ "$MODE" == "postgres" || "$MODE" == "mysql" ]] || { echo "Usage: $0 <postgres|mysql> [warehouses]"; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
OUT="$TAU_RESULTS/benchbase/${TAG:-pilot}_${MODE}_$(date +%Y%m%d_%H%M%S)"   # TAG: name of the result directory
mkdir -p "$OUT"
source "$TAUFS_BENCH/scripts/benchbase/tpcc_lib.sh"
FS=ext4
exec > >(tee -a "$OUT/pilot.log") 2>&1

echo "=== BenchBase TPC-C pilot: $MODE, $WH warehouses, $FS on $DEVICE $(date -u --rfc-3339=seconds)"
git -C "$TAUFS_BENCH/benchbase" log -1 --format='benchbase %h %cs' > "$OUT/versions"
java -version 2>&1 | head -1 >> "$OUT/versions"
do_mkfs $FS "$DEVICE"
mount_fs $FS "$MOUNT_DIR"
db_init

echo "--> load $WH warehouses $(date -u +%T)"
bb_config "$OUT/load.xml" false 60 0
bb load --create=true --load=true -d "$OUT/load"
echo "    load: $(cat "$OUT/load.jvm_time")"
case "$MODE" in
  postgres)
    $PG_BIN/vacuumdb -h 127.0.0.1 -p "$PG_PORT" -d tpcc --freeze --analyze --jobs=16 > /dev/null
    q "CHECKPOINT"
    echo "db_bytes $(q "SELECT pg_database_size('tpcc')")" > "$OUT/size"
    du -sb "$PG_DATA" | awk '{print "datadir_bytes", $1}' >> "$OUT/size"
    ;;
  mysql)
    for t in $(q "SHOW TABLES"); do q "ANALYZE TABLE $t" > /dev/null; done
    echo "db_bytes $(du -sb "$MY_DATA/tpcc" | cut -f1)" > "$OUT/size"
    du -sb "$MY_DATA" | awk '{print "datadir_bytes", $1}' >> "$OUT/size"
    ;;
esac
echo "warehouses $WH" >> "$OUT/size"
cat "$OUT/size"

for r in $RUNS; do
  IFS=: read -r name random fpw measured warmup <<< "$r"
  db_stop
  set_fpw "$fpw"
  db_start
  echo "--> $name: randomWarehouse=$random, FPW/DWB $fpw, ${warmup} s warm-up + ${measured} s, $TERMINALS terminals $(date -u +%T)"
  tpcc_run "$name" "$random" "$measured" "$warmup" "$fpw"
done

db_stop
umount_fs "$MOUNT_DIR"
echo "=== done $(date -u --rfc-3339=seconds) -> $OUT"
