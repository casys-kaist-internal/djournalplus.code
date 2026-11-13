#!/bin/bash
# EVAL_PLAN R3 (§6.5 Costs), items 1 and 2: what a truncate and an unlink cost
# tau, against the same file system without it.
#
#   truncate  ftruncate(fd, 0) of a FILE_MB (1024) file
#   unlink    unlink(2) of such a file, closed (its eviction runs inside the call)
#
# at two journal residencies (STATES): res1g, the whole file in the journal (it
# was overwritten through tau and fsync'd just before, and the call comes before
# tau_max_transaction_age (120 s) lets the checkpoint take it), and res0, none
# of it (overwritten the same way, then an unmount and a mount, which checkpoint
# everything; then read once, so the page cache holds the file in both states).
# The baselines go through the same steps without O_TAU_UNTORN.  Expected from
# taudocs/paper/architecture.md §14.1-14.2 (#385 on, here #401 / #1982):
# truncate at res1g = one commit with a conditional revoke tag (16 B) per mapped
# block (1 GiB: 262,144 tags, 1,033 blocks, ~4 MiB) and no home write, at res0
# no commit (= the baseline); unlink = no commit and no home write, the segments
# given back once the host has the unlink on disk.
#
# AFTERS: how the segments come back.  wait: the host's own commit gives them
# back (ext4 jbd2 every 5 s, XFS's log worker up to 30 s), what a database sees;
# sync: a syncfs right after the call makes the host commit at once, leaving
# tau's part (develop, 11-13: the next journald pass, 10 ms when idle).
#
# Per run (r3op.py): the call's latency; the device's writes (block tracepoint,
# checked against /sys/block/<dev>/stat) during the call ("sync") and after it
# until the segments are back, at least AFTER_MIN s, then a syncfs ("after"),
# each split into "home" (to the file's own blocks) and "other" (journals,
# metadata); the residency (tau_journal_usage: the journal's used segments over
# the count before the overwrite, x the segment size); the time until those
# segments are free again; the host's first jbd2 commit after the call (ext4);
# the tau probe counters where the kernel has them (CONFIG_TAU_PROBE_TORN; the
# paper's perf kernel does not).  One JSON line per run in results.jsonl,
# r3_report.py -> results.csv and summary.md.
#
# Configurations (CONFIGS):
#   EXT4      stock mke2fs (lazy init off), default mount (data=ordered)  base kernel
#   XFS       stock mkfs.xfs, default mount                               base kernel
#   tau-EXT4  tau mke2fs (segments $TAU_SEGSIZE), tjournal,tjournal_size=$TAU_JOURNAL_GB  tau kernel
#   tau-XFS   tau mkfs.xfs -l tjsegsize=$TAU_SEGSIZE,tjmaxsize=${TAU_JOURNAL_GB}G, same mount
# as run_fio.sh.  The baselines run on the base kernel ($TAU_BASE_KERNEL); with
# KCHECK=1 on the tau kernel instead (a kernel cross-check, labeled -kcheck, as
# run_main.sh KCHECK=1).  Each configuration gets a trimmed device and a fresh
# file system; every run a new file, and a remount before it.
#
# A res1g run is void if reclaim scanned the shrinkers between the overwrite and
# the call (drop_caches 2/3, kswapd, direct reclaim: tau then checkpoints the
# file's oldest tx whole): r3op.py records the /proc/vmstat reclaim counters
# that moved ("reclaim"), and nothing here drops caches.
#
# Usage: [CONFIGS="EXT4 tau-EXT4"] [OPS="truncate unlink"] [STATES="res0 res1g"]
#        [AFTERS="wait sync"] [REPS=3]
#        [FILE_MB=1024] [TAU_JOURNAL_GB=32] [AFTER_MIN=6] [KCHECK=1] run_r3.sh <tag>
#        CHECK_ONLY=1: stop after the checks.  HOST_CHECK=0: skip host_setup.sh check.
# Results: $TAU_RESULTS/r3/<date>_r3_<tag>/ (env.txt, fs.txt, results.jsonl,
#          results.csv, summary.md, run.log).  ~25 s a run: 2 configurations x
#          2 ops x 2 states x 2 afters x 3 = 48 runs, ~25 min with the mkfs.
set -e
[ -n "$TAUFS_ENV_SOURCED" ] || { echo "Do source set_env.sh first."; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
HERE=$TAUFS_BENCH/scripts/costs

TAG=${1:?usage: run_r3.sh <tag>}
KERNEL=$(uname -r)
TAU_KERNEL=0
[[ $KERNEL == *tjournal* ]] && TAU_KERNEL=1
KCHECK=${KCHECK:-0}
if (( TAU_KERNEL )); then
  if (( KCHECK )); then CONFIGS=${CONFIGS:-EXT4 tau-EXT4}; else CONFIGS=${CONFIGS:-tau-EXT4}; fi
else
  CONFIGS=${CONFIGS:-EXT4}
fi
OPS=${OPS:-truncate unlink}
STATES=${STATES:-res0 res1g}
AFTERS=${AFTERS:-wait sync}
REPS=${REPS:-3}
FILE_MB=${FILE_MB:-1024}
TAU_JOURNAL_GB=${TAU_JOURNAL_GB:-32}
AFTER_MIN=${AFTER_MIN:-6}
SEG_TIMEOUT=${SEG_TIMEOUT:-120}
NO_DISCARD=${NO_DISCARD:-0}

for c in $CONFIGS; do
  case $c in
    tau-EXT4|tau-XFS)
      (( TAU_KERNEL )) || { echo "❌ $c runs on the tau kernel, not $KERNEL"; exit 1; } ;;
    EXT4|XFS)
      if (( KCHECK )); then
        (( TAU_KERNEL )) || { echo "❌ KCHECK=1 runs $c on the tau kernel, not $KERNEL"; exit 1; }
      else
        [[ $KERNEL == "${TAU_BASE_KERNEL:-6.8.0-base+}" ]] ||
          { echo "❌ $c runs on the base kernel ${TAU_BASE_KERNEL:-6.8.0-base+}, not $KERNEL (KCHECK=1: on the tau kernel)"; exit 1; }
      fi ;;
    *) echo "❌ unknown configuration $c"; exit 1 ;;
  esac
done
for o in $OPS; do [[ $o == truncate || $o == unlink ]] || { echo "❌ OPS: truncate unlink"; exit 1; }; done
for s in $STATES; do [[ $s == res0 || $s == res1g ]] || { echo "❌ STATES: res0 res1g"; exit 1; }; done
for s in $AFTERS; do [[ $s == wait || $s == sync ]] || { echo "❌ AFTERS: wait sync"; exit 1; }; done
[[ -n "$DEVICE" && -b "$DEVICE" ]] || { echo "❌ no test device (TAU_DEVICE)"; exit 1; }
[[ "${CHECK_ONLY:-0}" == 0 ]] || { echo "checks passed: $CONFIGS | $OPS | $STATES | $KERNEL"; exit 0; }
if [[ "${HOST_CHECK:-1}" != 0 ]]; then
  bash "$TAUFS_BENCH/scripts/host_setup.sh" check || { echo "❌ run bench/scripts/host_setup.sh apply (HOST_CHECK=0 skips)"; exit 1; }
fi

STATDEV=$(tau_stat_devs)
SIZE=$(( FILE_MB << 20 ))
OP=$HERE/r3op.py
if (( KCHECK )); then KSUF=-kcheck; else KSUF=; fi
RESULT_DIR=$TAU_RESULTS/r3/$(date +%Y%m%d_%H%M%S)_r3_$TAG$KSUF
mkdir -p "$RESULT_DIR"
cp "$0" "$OP" "$HERE/r3_report.py" "$RESULT_DIR/"
JSONL=$RESULT_DIR/results.jsonl
LOG=$RESULT_DIR/run.log
log_env "$RESULT_DIR/env.txt"
{
  echo
  echo "## r3"
  echo "test device: $DEVICE ($(cat /sys/block/$TAU_DEVICE_NAME/device/model 2>/dev/null | xargs), serial $(cat /sys/block/$TAU_DEVICE_NAME/device/serial 2>/dev/null | xargs)), stats from /sys/block/$STATDEV/stat, write_cache $(cat /sys/block/$TAU_DEVICE_NAME/queue/write_cache), NO_DISCARD=$NO_DISCARD"
  echo "kernel: $KERNEL $(uname -v)"
  echo "umbrella: $(git -C "$TAUFS_ROOT" describe --always --dirty --abbrev=12 2>/dev/null) ($(git -C "$TAUFS_ROOT" log -1 --format='%h %s' 2>/dev/null | cut -c1-80)); bench/scripts/costs $(git -C "$TAUFS_ROOT" status --porcelain -- bench/scripts/costs 2>/dev/null | wc -l) uncommitted"
  echo "mkfs: baselines $STOCK_DIR (stock); tau $TAUFS_E2FSPROGS/misc/mke2fs ($(git -C "$TAUFS_E2FSPROGS" log -1 --format=%h 2>/dev/null)), $TAUFS_XFSPROGS/mkfs/mkfs.xfs ($(git -C "$TAUFS_XFSPROGS" log -1 --format=%h 2>/dev/null))"
  if [[ -d /sys/module/tau_journal/parameters ]]; then
    echo "tau parameters: $(cd /sys/module/tau_journal/parameters && for p in tau_max_transaction_age tau_max_commmit_age tau_cp_small_tx tauvar_force_reclaim tauvar_thres_checkpoint tau_shrink_seeks tau_segment_per_alloc tau_defer_txdirty_cpflush; do printf '%s=%s ' $p "$(cat $p 2>/dev/null)"; done)"
    echo "tau probe counters: $(ls /sys/module/tau_journal/parameters | grep -c '^tau_probe_') (0: CONFIG_TAU_PROBE_TORN off)"
  fi
  sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
  echo "CONFIGS=$CONFIGS OPS=$OPS STATES=$STATES AFTERS=$AFTERS REPS=$REPS FILE_MB=$FILE_MB TAU_SEGSIZE=$TAU_SEGSIZE TAU_JOURNAL_GB=$TAU_JOURNAL_GB AFTER_MIN=$AFTER_MIN SEG_TIMEOUT=$SEG_TIMEOUT KCHECK=$KCHECK"
} >> "$RESULT_DIR/env.txt"
echo "=== r3: $RESULT_DIR ($CONFIGS | $OPS | $STATES | x$REPS | $KERNEL) $(date -u --rfc-3339=seconds)" | tee -a "$LOG"

fs_make() {
  mountpoint -q "$MOUNT_DIR" && sudo umount "$MOUNT_DIR"
  local ext=lazy_itable_init=0,lazy_journal_init=0 xk=()
  if (( NO_DISCARD )); then
    ext+=,nodiscard; xk=(-K)
  else
    echo "[+] Trimming $DEVICE (blkdiscard)"
    sudo blkdiscard -f "$DEVICE"
  fi
  case $1 in
    EXT4)     stock_mke2fs -q -t ext4 -E "$ext" -F "$DEVICE" ;;
    XFS)      stock_mkfs_xfs -q -f "${xk[@]}" "$DEVICE" ;;
    tau-EXT4) tau_mke2fs -q -t ext4 -E "$ext${TAU_SEGSIZE:+,tau_segsize=$TAU_SEGSIZE}" -F "$DEVICE" ;;
    tau-XFS)  tau_mkfs_xfs -q -f "${xk[@]}" -l ${TAU_SEGSIZE:+tjsegsize=$TAU_SEGSIZE,}tjmaxsize=${TAU_JOURNAL_GB}G "$DEVICE" ;;
  esac
  sudo mkdir -p "$MOUNT_DIR"
  fs_mount "$1"
  sudo chown "$(id -u):$(id -g)" "$MOUNT_DIR"
}

fs_mount() {
  ! mountpoint -q "$MOUNT_DIR" || return 0
  case $1 in
    EXT4)     sudo mount -t ext4 "$DEVICE" "$MOUNT_DIR" ;;
    XFS)      sudo mount -t xfs "$DEVICE" "$MOUNT_DIR" ;;
    tau-EXT4) sudo mount -t ext4 -o tjournal,tjournal_size="$TAU_JOURNAL_GB" "$DEVICE" "$MOUNT_DIR" ;;
    tau-XFS)  sudo mount -t xfs -o tjournal,tjournal_size="$TAU_JOURNAL_GB" "$DEVICE" "$MOUNT_DIR" ;;
  esac
}

remount() { sudo umount "$MOUNT_DIR"; fs_mount "$1"; }

fs_note() {
  {
    echo "== $1 $(date -u --rfc-3339=seconds)"
    grep " $MOUNT_DIR " /proc/mounts || true
    case $1 in
      *EXT4) sudo dumpe2fs -h "$DEVICE" 2>/dev/null | grep -E '^(Filesystem features|Block size|Journal size)' || true ;;
      *XFS)  xfs_info "$MOUNT_DIR" 2>/dev/null | head -3 || true ;;
    esac
    # tau refuses O_DIRECT|O_TAU_UNTORN with EINVAL: the check that tau is active
    python3 - "$MOUNT_DIR/.taucheck" <<'EOF'
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | os.O_DIRECT | 0o40000000, 0o644)
    os.close(fd)
    print("O_DIRECT|O_TAU_UNTORN accepted: tau not active")
except OSError as e:
    print("O_DIRECT|O_TAU_UNTORN: " + ("EINVAL, tau active" if e.errno == errno.EINVAL else errno.errorcode[e.errno]))
EOF
    rm -f "$MOUNT_DIR/.taucheck"
  } >> "$RESULT_DIR/fs.txt" 2>&1
}

# one run: a new file, remount, overwrite (+ remount for res0), the measured call
run_one() {  # <config> <op> <state> <after: wait|sync> <rep>
  local c=$1 op=$2 st=$3 af=$4 rep=$5 f tau=() base read=() ow vm0 end sync=()
  f=$MOUNT_DIR/r3/$op-$st-$af-$rep
  [[ $c == tau-* ]] && tau=(--tau)
  [[ $af == sync ]] && sync=(--after-sync)
  mkdir -p "$MOUNT_DIR/r3"
  python3 "$OP" create "$f" "$SIZE"
  remount "$c"
  base=$(python3 "$OP" usage "$TAU_DEVICE_NAME")
  vm0=$(python3 "$OP" vmstat)
  ow=$(python3 "$OP" overwrite "$f" "$SIZE" "${tau[@]}")
  end=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["end_ns"])' "$ow")
  if [[ $st == res0 ]]; then
    remount "$c"
    read=(--read)
  fi
  local cfg=$c
  [[ $c == tau-* ]] || cfg=$c$KSUF
  local label=(config=$cfg state=$st after=$af rep=$rep "overwrite=$ow")
  sudo python3 "$OP" measure --op "$op" --path "$f" "${tau[@]}" "${read[@]}" "${sync[@]}" --dev "$TAU_DEVICE_NAME" \
    --statdevs "$STATDEV" --mnt "$MOUNT_DIR" ${base:+$( [[ $base != - ]] && echo --used-base "$base")} \
    --since-ns "$end" --vm0 "$vm0" --after-min "$AFTER_MIN" --seg-timeout "$SEG_TIMEOUT" \
    --label "${label[@]}" >> "$JSONL"
  tail -1 "$JSONL" | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("  %-9s %-8s %-5s %-4s r%s  lat %8.3f ms  sync %7.1f KiB (home %d)  after %8.1f KiB (home %d)  res %s MiB  seg_back %s ms  host_commit %s ms  trace_ok %s%s" % (
    r["config"], r["op"], r["state"], r["after"], r["rep"], r["lat_ms"], (r["sync_other_bytes"] + r["sync_home_bytes"]) / 1024,
    r["sync_home_bytes"], (r["after_other_bytes"] + r["after_home_bytes"]) / 1024, r["after_home_bytes"],
    r.get("resident_mib", "-"), r.get("seg_return_ms", "-"), r.get("host_commit_ms", "-"), r["trace_ok"],
    "  RECLAIM " + str(r["reclaim"]) if r["reclaim"] else ""))' | tee -a "$LOG"
  rm -f "$f"
  remount "$c"
}

for c in $CONFIGS; do
  echo "=== $c $(date -u --rfc-3339=seconds)" | tee -a "$LOG"
  fs_make "$c"
  fs_note "$c"
  for op in $OPS; do
    for st in $STATES; do
      for af in $AFTERS; do
        for (( rep = 1; rep <= REPS; rep++ )); do
          run_one "$c" "$op" "$st" "$af" "$rep"
        done
      done
    done
  done
  sudo umount "$MOUNT_DIR"
done
python3 "$HERE/r3_report.py" "$RESULT_DIR"
echo "=== done $(date -u --rfc-3339=seconds): $RESULT_DIR" | tee -a "$LOG"
