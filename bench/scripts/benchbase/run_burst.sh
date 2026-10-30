#!/bin/bash
# EVAL_PLAN DB5 (elasticity): one hour of BenchBase TPC-C with a burst in the
# middle, the shape of SOSP E10 (taujournal-test.code/figures/results.csv):
# BURST_RATE transactions/s (1000) for PRE_S (600 s), unlimited for BURST_S (2400
# s), BURST_RATE again for POST_S (600 s), TERMINALS (64) throughout, throughput
# in 2-s windows; beside it a 2-s sampler of the WAL directory's size on disk
# (the App configurations' "journal") and of the device's write volume, plus the
# output of JOURNAL_SAMPLE_CMD when set (τ's journal size, for the τ runs). Per
# configuration (FS_GROUPS with FS_FPWON / FS_FPWOFF as in run_tpcc.sh) and per
# WAL_SIZES entry (PG max_wal_size; EVAL_PLAN's EXT4_App variants 4GB and 32GB;
# "default" = the benchmark's 16GB): the trim and restore of the TPC-C image,
# the benchmark settings, WARMUP_TIME (600 s) of unlimited load at TERMINALS (0:
# none), then the hour. PostgreSQL only (MySQL would resize its pre-created redo
# files at start).
# Results: $TAU_RESULTS/benchbase/postgres/<ts>_burst/, <label>.{xml,log,...},
# <label>.samples.csv, summary.md (burst_report.py).
# Usage: [FS_GROUPS=ext4 FS_FPWON=ext4 FS_FPWOFF=] [WAL_SIZES="4GB 32GB"] [TERMINALS=64]
#        [BURST_RATE=1000] [PRE_S=600 BURST_S=2400 POST_S=600] [WARMUP_TIME=600]
#        run_burst.sh postgres [warehouses (1100)]
set -e
MODE="$1"
WH="${2:-1100}"
[[ "$MODE" == postgres ]] || { echo "Usage: $0 postgres [warehouses] (DB5 runs PostgreSQL only)"; exit 1; }
[ -n "$TAUFS_ENV_SOURCED" ] || { echo "Do source set_env.sh first."; exit 1; }
FS_GROUPS="${FS_GROUPS-ext4}"
FS_FPWON="${FS_FPWON-ext4}"
FS_FPWOFF="${FS_FPWOFF-}"
WAL_SIZES="${WAL_SIZES-4GB 32GB}"
TERMINALS=${TERMINALS:-64}
BURST_RATE=${BURST_RATE:-1000}
PRE_S=${PRE_S:-600}
BURST_S=${BURST_S:-2400}
POST_S=${POST_S:-600}
WARMUP_TIME=${WARMUP_TIME:-600}
SAMPLE_S=2
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
bash "$TAUFS_BENCH/scripts/host_setup.sh" check || { echo "❌ run bench/scripts/host_setup.sh apply"; exit 1; }
if [[ -n "$TAU_BASE_KERNEL" && "$(uname -r)" != "$TAU_BASE_KERNEL" && " $FS_GROUPS " != *tau* ]]; then
  echo "❌ Baseline runs need kernel $TAU_BASE_KERNEL (running $(uname -r))"; exit 1
fi
KEY="tpcc_w$WH"
BACKUP_DIR="$TAU_BACKUP_ROOT/benchbase/$MODE"
for FS in $FS_GROUPS; do
  [[ -e "$BACKUP_DIR/${FS}_${KEY}.img" ]] || { echo "❌ no image $BACKUP_DIR/${FS}_${KEY}.img (create_image.sh)"; exit 1; }
done
OUT="$TAU_RESULTS/benchbase/$MODE/$(date +%Y%m%d_%H%M%S)_burst"
mkdir -p "$OUT"
source "$TAUFS_BENCH/scripts/benchbase/tpcc_lib.sh"
exec > >(tee -a "$OUT/run.log") 2>&1
cp "$0" "$OUT/"
echo "=== DB5 burst: $MODE, $WH warehouses, $TERMINALS terminals, ${BURST_RATE}/s for ${PRE_S} s," \
  "unlimited for ${BURST_S} s, ${BURST_RATE}/s for ${POST_S} s; WAL sizes ${WAL_SIZES:-default};" \
  "FS $FS_GROUPS (FPW on: $FS_FPWON; off: $FS_FPWOFF) $(date -u --rfc-3339=seconds)"
git -C "$TAUFS_BENCH/benchbase" log -1 --format='benchbase %h %cs' > "$OUT/versions"
log_env "$OUT/env.txt"

burst_config() {  # <file>: the three phases, the standard mix, no think time
  local f=$1 phase
  {
    cat <<EOF
<?xml version="1.0"?>
<parameters>
    <type>$TYPE</type>
    <driver>$DRIVER</driver>
    <url>$URL</url>
    <username>$DB_USER</username>
    <password></password>
    <isolation>$ISOLATION</isolation>
    <batchsize>128</batchsize>
    <loaderThreads>32</loaderThreads>
    <scalefactor>$WH</scalefactor>
    <terminals>$TERMINALS</terminals>
    <randomWarehouse>true</randomWarehouse>
    <works>
EOF
    for phase in "$PRE_S $BURST_RATE" "$BURST_S unlimited" "$POST_S $BURST_RATE"; do
      set -- $phase
      cat <<EOF
        <work>
            <time>$1</time>
            <rate>$2</rate>
            <weights>45,43,4,4,4</weights>
        </work>
EOF
    done
    cat <<EOF
    </works>
    <transactiontypes>
        <transactiontype><name>NewOrder</name></transactiontype>
        <transactiontype><name>Payment</name></transactiontype>
        <transactiontype><name>OrderStatus</name></transactiontype>
        <transactiontype><name>Delivery</name></transactiontype>
        <transactiontype><name>StockLevel</name></transactiontype>
    </transactiontypes>
</parameters>
EOF
  } > "$f"
}

# Every SAMPLE_S: time, WAL directory bytes on disk, device sectors written,
# and JOURNAL_SAMPLE_CMD's output (one line) when set
sampler() {  # <csv>
  local dev
  dev=$(tau_stat_devs)
  echo "epoch,wal_bytes,dev_sectors_written,journal" > "$1"
  while :; do
    echo "$(date +%s.%N),$(sudo du -sb "$PG_DATA/pg_wal" 2>/dev/null | cut -f1),$(awk -v d="$dev" \
      '$3 == d {print $10}' /proc/diskstats),$( [[ -n "$JOURNAL_SAMPLE_CMD" ]] && eval "$JOURNAL_SAMPLE_CMD" 2>/dev/null | head -1)" >> "$1"
    sleep "$SAMPLE_S"
  done
}

for FS in $FS_GROUPS; do
  for FPW in off on; do
    if [[ "$FPW" == off && " $FS_FPWOFF " != *" $FS "* ]] || [[ "$FPW" == on && " $FS_FPWON " != *" $FS "* ]]; then
      continue
    fi
    for WAL in ${WAL_SIZES:-default}; do
      LABEL="${MODE}_burst_${FS}_fpw_${FPW}_wal${WAL}_w${WH}_c${TERMINALS}"
      echo "=== $LABEL: restoring ${FS}_${KEY} on $DEVICE $(date -u +%T)"
      restore_filesystem $FS "$KEY" "$BACKUP_DIR"
      mount_fs $FS "$MOUNT_DIR"
      echo "mount: $(findmnt -no FSTYPE,OPTIONS "$MOUNT_DIR" | head -1)"
      set_fpw "$FPW"
      db_fs_settings "$FS"
      [[ "$WAL" == default ]] || pg_wal_max_set "$PG_DATA" "$WAL"
      SERVER_LOG="$OUT/${LABEL}_server.log"
      db_start
      q "SHOW max_wal_size" | sed 's/^/max_wal_size /' > "$OUT/$LABEL.settings"
      q "SHOW full_page_writes" | sed 's/^/full_page_writes /' >> "$OUT/$LABEL.settings"
      if (( WARMUP_TIME > 0 )); then
        echo "--> warm-up ${WARMUP_TIME} s, $TERMINALS terminals, unlimited $(date -u +%T)"
        bb_config "$OUT/${LABEL}_warmup.xml" true "$WARMUP_TIME" 0
        bb "${LABEL}_warmup" --execute=true -d "$OUT/${LABEL}_warmup" -s 10
      fi
      echo "--> $LABEL: $((PRE_S + BURST_S + POST_S)) s $(date -u +%T)"
      burst_config "$OUT/$LABEL.xml"
      log_dev_stat begin "$OUT/$LABEL.io"
      db_counters begin "$OUT/$LABEL.io"
      sampler "$OUT/$LABEL.samples.csv" &
      smp=$!
      bb "$LABEL" --execute=true -d "$OUT/$LABEL" -s "$SAMPLE_S"
      kill "$smp" 2>/dev/null || true
      wait "$smp" 2>/dev/null || true
      log_dev_stat end "$OUT/$LABEL.io"
      db_counters end "$OUT/$LABEL.io"
      echo "    $(tr '\n' ' ' < "$OUT/$LABEL.jvm_time")"
      db_stop
      umount_fs "$MOUNT_DIR"
      clear_fs $FS "$DEVICE"
    done
  done
done
python3 "$TAUFS_BENCH/scripts/benchbase/burst_report.py" "$OUT" > "$OUT/summary.md" || true
echo "=== done $(date -u --rfc-3339=seconds) -> $OUT"
