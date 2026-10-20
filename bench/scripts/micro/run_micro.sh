#!/bin/bash
# §6.3 microbenchmarks with atomicw (atomicw.c here): one 16 KiB pwrite +
# fdatasync per op and thread, on the configurations below, one CSV line per
# run (results.csv; per run also a latency histogram and an ops/s timeline).
#
# Per configuration and pattern (ZFS: per thread count too, FRESH_PER_THREADS):
# trim the whole test SSD, mkfs, mount, for overwrite fill the files once per
# file count, then leave the SSD idle for SETTLE seconds (after a large
# discard the PM1735 runs ~15% slower at one thread for 4-5 min). Per run:
# delete the previous run's files, remount (empties the page cache and ZFS's
# ARC), then atomicw: 10 s not counted, 60 s measured. No trim between runs:
# a whole-device trim slows the next minutes (TRIM_BETWEEN_RUNS=1 restores
# fstrim / zpool trim -w, the latter ~10 min per run). ZFS gets a fresh pool
# per thread count because its copy-on-write writes would otherwise fill the
# untrimmed SSD over a pattern (~3 TB at 1-64 threads x 3).
#
# Configurations (stock mkfs, as the database baselines):
#   EXT4_Raw   ext4, data=ordered (delalloc)
#   EXT4_Data  ext4 with a 40,000 MB journal (-J size=40000), data=journal
#   XFS_Raw    xfs defaults
#   ZFS        one dataset, ashift=12, recordsize=16K, compression=off,
#              atime=off, ZIL on the same device (ARC as the host sets it)
#
# Usage: [CONFIGS="EXT4_Raw EXT4_Data ZFS XFS_Raw"] [PATTERNS="overwrite prealloc hole append"]
#        [THREADS_LIST="1 2 4 8 16 32 64"] [FILES_LIST=64] [REPS=3] [WARMUP=10] [DURATION=60]
#        run_micro.sh <tag>
set -e
[ -n "$TAUFS_ENV_SOURCED" ] || { echo "Do source set_env.sh first."; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"

TAG=${1:?usage: run_micro.sh <tag>}
CONFIGS=${CONFIGS:-EXT4_Raw EXT4_Data ZFS XFS_Raw}
PATTERNS=${PATTERNS:-overwrite prealloc hole append}
THREADS_LIST=${THREADS_LIST:-1 2 4 8 16 32 64}
FILES_LIST=${FILES_LIST:-64}
REPS=${REPS:-3}
WARMUP=${WARMUP:-10}
DURATION=${DURATION:-60}
TOTAL=${TOTAL:-128G}
SETTLE=${SETTLE:-300}
TRIM_BETWEEN_RUNS=${TRIM_BETWEEN_RUNS:-0}
FRESH_PER_THREADS=${FRESH_PER_THREADS-ZFS}

if [[ "${HOST_CHECK:-1}" != 0 ]]; then
  bash "$TAUFS_BENCH/scripts/host_setup.sh" check || { echo "❌ run bench/scripts/host_setup.sh apply"; exit 1; }
fi
AW=$TAUFS_BENCH_WS/micro/atomicw
mkdir -p "$(dirname "$AW")"
gcc -O2 -Wall -pthread -o "$AW" "$TAUFS_BENCH/scripts/micro/atomicw.c"
STATDEV=$(tau_stat_devs)

RESULT_DIR=$TAU_RESULTS/micro/$(date +%Y%m%d_%H%M%S)_$TAG
mkdir -p "$RESULT_DIR/hist" "$RESULT_DIR/timeline"
cp "$0" "$TAUFS_BENCH/scripts/micro/atomicw.c" "$RESULT_DIR/"
CSV=$RESULT_DIR/results.csv
"$AW" --csv-header | awk -F, 'BEGIN { OFS = "," } { $4 = "rep," $4; print "config," $0 }' > "$CSV"
log_env "$RESULT_DIR/env.txt"
{
  echo "test device: $DEVICE (stats from /sys/block/$STATDEV/stat), write_cache $(cat /sys/block/$TAU_DEVICE_NAME/queue/write_cache)"
  echo "kernel: $(uname -r)"
  sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_bytes vm.dirty_background_bytes \
    vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
  echo "zfs_arc_max: $(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null)"
  echo "CONFIGS=$CONFIGS PATTERNS=$PATTERNS THREADS_LIST=$THREADS_LIST FILES_LIST=$FILES_LIST REPS=$REPS WARMUP=$WARMUP DURATION=$DURATION TOTAL=$TOTAL SETTLE=$SETTLE TRIM_BETWEEN_RUNS=$TRIM_BETWEEN_RUNS FRESH_PER_THREADS=$FRESH_PER_THREADS"
} >> "$RESULT_DIR/env.txt"
echo "=== micro: $RESULT_DIR ($CONFIGS | $PATTERNS | threads $THREADS_LIST | files $FILES_LIST | x$REPS) $(date -u --rfc-3339=seconds)"

fs_make() {
  sudo zpool destroy -f zfspool 2>/dev/null || true
  mountpoint -q "$MOUNT_DIR" && sudo umount "$MOUNT_DIR"
  echo "[+] Trimming $DEVICE (blkdiscard)"
  sudo blkdiscard -f "$DEVICE"
  case $1 in
    EXT4_Raw)  stock_mke2fs -q -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "$DEVICE" ;;
    EXT4_Data) stock_mke2fs -q -t ext4 -J size=40000 -E lazy_itable_init=0,lazy_journal_init=0 -F "$DEVICE" ;;
    XFS_Raw)   stock_mkfs_xfs -q -f "$DEVICE" ;;
    ZFS)
      sudo wipefs -a "$DEVICE" >/dev/null
      sudo zpool create -f -o ashift=12 -O recordsize=16K -O compression=off -O atime=off \
        -O mountpoint="$MOUNT_DIR" zfspool "$DEVICE"
      ;;
    *) echo "Unknown config $1"; exit 1 ;;
  esac
  sudo mkdir -p "$MOUNT_DIR"
  fs_mount "$1"
  sudo chown "$(id -u):$(id -g)" "$MOUNT_DIR"
}

fs_mount() {
  case $1 in
    EXT4_Raw)  sudo mount -t ext4 -o data=ordered "$DEVICE" "$MOUNT_DIR" ;;
    EXT4_Data) sudo mount -t ext4 -o data=journal "$DEVICE" "$MOUNT_DIR" ;;
    XFS_Raw)   sudo mount -t xfs "$DEVICE" "$MOUNT_DIR" ;;
    # a whole-disk vdev lives on partition 1 (zpool create partitions the disk)
    ZFS)       zpool list zfspool >/dev/null 2>&1 || sudo zpool import -d "${DEVICE}p1" zfspool ;;
  esac
}

fs_umount() {
  case $1 in
    ZFS) sudo zpool export zfspool ;;
    *)   sudo umount "$MOUNT_DIR" ;;
  esac
}

fs_trim() {
  case $1 in
    ZFS) sudo zpool trim -w zfspool ;;
    *)   sudo fstrim "$MOUNT_DIR" ;;
  esac
}

fs_note() {
  {
    echo "== $1 $(date -u --rfc-3339=seconds)"
    grep " $MOUNT_DIR " /proc/mounts || true
    if [[ $1 == ZFS ]]; then
      sudo zpool get -H ashift,autotrim zfspool
      sudo zfs get -H recordsize,compression,atime,logbias,sync,primarycache zfspool
    fi
  } >> "$RESULT_DIR/fs.txt"
}

# fresh file system (+ the overwrite files of the given file counts), then idle
fresh_fs() {  # <config> <pattern> <file counts...>
  local cfg=$1 pat=$2 f
  shift 2
  echo "=== $cfg $pat: mkfs $(date -u --rfc-3339=seconds)"
  fs_make "$cfg"
  fs_note "$cfg"
  for f in "$@"; do
    if [[ $pat == overwrite ]]; then
      mkdir -p "$MOUNT_DIR/ow_f$f"
      echo "--> $cfg: filling $f files ($TOTAL) $(date -u +%T)"
      "$AW" --prepare --dir "$MOUNT_DIR/ow_f$f" --files "$f" --total "$TOTAL" | tee -a "$RESULT_DIR/prepare.log"
    fi
  done
  mkdir -p "$MOUNT_DIR/run"
  echo "--> settling ${SETTLE} s $(date -u +%T)"
  sleep "$SETTLE"
}

for CONFIG in $CONFIGS; do
  per_t=0
  [[ " $FRESH_PER_THREADS " == *" $CONFIG "* ]] && per_t=1
  for PATTERN in $PATTERNS; do
    (( per_t )) || fresh_fs "$CONFIG" "$PATTERN" $FILES_LIST
    for F in $FILES_LIST; do
      DIR=$MOUNT_DIR/run
      [[ $PATTERN == overwrite ]] && DIR=$MOUNT_DIR/ow_f$F
      for T in $THREADS_LIST; do
        if (( F < T )) && { (( T % F )) || [[ $PATTERN == append ]]; }; then
          continue
        fi
        (( per_t )) && fresh_fs "$CONFIG" "$PATTERN" "$F"
        for (( rep = 1; rep <= REPS; rep++ )); do
          LABEL="${CONFIG}_${PATTERN}_f${F}_t${T}_r${rep}"
          [[ $PATTERN == overwrite ]] || rm -f "$DIR"/f[0-9]*
          (( TRIM_BETWEEN_RUNS )) && fs_trim "$CONFIG"
          fs_umount "$CONFIG"
          drop_caches > /dev/null
          fs_mount "$CONFIG"
          line=$("$AW" --dir "$DIR" --pattern "$PATTERN" --threads "$T" --files "$F" --total "$TOTAL" \
                   --warmup "$WARMUP" --duration "$DURATION" --seed "$rep" --dev "$STATDEV" \
                   --label "$LABEL" --hist "$RESULT_DIR/hist/$LABEL.txt" \
                   --timeline "$RESULT_DIR/timeline/$LABEL.txt")
          echo "$line" | awk -F, -v c="$CONFIG" -v r="$rep" \
            'BEGIN { OFS = "," } { $4 = r "," $4; print c "," $0 }' >> "$CSV"
          echo "    $LABEL: $(echo "$line" | awk -F, '{ printf "%.0f IOPS, fdatasync %.0f us (p99 %.0f), %.1f KB/op", $7, $8, $10, $15 / 1024 }') $(date -u +%T)"
        done
      done
    done
  done
  fs_umount "$CONFIG" || true
  [[ $CONFIG != ZFS ]] || sudo zpool destroy -f zfspool 2>/dev/null || true
done
echo "=== done: $RESULT_DIR $(date -u --rfc-3339=seconds)"
