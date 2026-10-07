#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Capture phase: build the dm-log-writes stack, run `torner gen` on it, and
# leave behind the three artifacts everything downstream needs.
#
#     base.img       the backing device as it was before logging started
#     log.img        the dm-log-writes log
#     progress.img   the P2 progress log (outside the stack under test)
#
# Those are ordinary files, which is the whole point: capture happens once, and
# every later state is rebuilt offline from base + log.  That decoupling is what
# makes the state exploration parallel.
#
# Runs on the host against loop devices (validates the pipeline on stock ext4)
# or inside the guest against real virtio devices (the tau configurations).
#
# Needs root for losetup/dmsetup/mount.  Everything it creates lives under
# --workdir and is torn down on exit; no persistent device is touched.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
. "$HERE/fsmap.sh"

WORKDIR=""
FS="ext4"
DEV_SIZE="1G"
LOG_SIZE="1G"
PROG_SIZE="64M"
MODE="overwrite"
DURATION=5
THREADS=4
PAGES=4096
UNIT=16384
GEN_ARGS=""
FSYNC_EVERY=1
MARK_EVERY=128
RUN_ID=""
KEEP_STACK=0
KEEP_BACKING=0

DM_NAME="torner-log"
export TORNER_ZPOOL="${TORNER_ZPOOL:-torner_pool}"
MNT=""
LOOP_BACK=""; LOOP_LOG=""; LOOP_PROG=""

usage() {
	cat >&2 <<EOF
usage: capture.sh --workdir DIR [options]

  --workdir DIR      where artifacts and loop-backed images are created
  --fs FS            ext4 | ext4-data | tau-ext4 | tau-xfs        [ext4]
  --dev-size SZ      backing device size                          [1G]
  --log-size SZ      dm-log-writes log size                       [1G]
  --mode M           torner gen mode                              [overwrite]
  --duration S       workload seconds                             [5]
  --threads N        workload threads                             [4]
  --pages N          atomic units in the target file              [4096]
  --unit BYTES       application atomic unit                      [16384]
  --fsync-every K    fsync policy                                 [1]
  --gen-args "..."   extra torner gen options, e.g. interference:
                     "--other-fsync-ms 5 --writeback-ms 2 --direct"
  --run-id U64       stamped into the data (defaults to time)
  --keep-stack       leave the dm stack up (for debugging)
  --keep-backing     keep backing.img (the post-workload device); it is
                     reproducible by replaying the whole log onto base

Artifacts land in DIR: base.img, log.img, progress.img, capture.json,
atoms.json (how each application write reached the device; torner atoms)
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--workdir)     WORKDIR="$2"; shift 2 ;;
	--fs)          FS="$2"; shift 2 ;;
	--dev-size)    DEV_SIZE="$2"; shift 2 ;;
	--log-size)    LOG_SIZE="$2"; shift 2 ;;
	--mode)        MODE="$2"; shift 2 ;;
	--duration)    DURATION="$2"; shift 2 ;;
	--threads)     THREADS="$2"; shift 2 ;;
	--pages)       PAGES="$2"; shift 2 ;;
	--unit)        UNIT="$2"; shift 2 ;;
	--gen-args)    GEN_ARGS="$2"; shift 2 ;;
	--fsync-every) FSYNC_EVERY="$2"; shift 2 ;;
	--mark-every)  MARK_EVERY="$2"; shift 2 ;;
	--run-id)      RUN_ID="$2"; shift 2 ;;
	--keep-stack)  KEEP_STACK=1; shift ;;
	--keep-backing) KEEP_BACKING=1; shift ;;
	-h|--help)     usage ;;
	*) echo "capture.sh: unknown option $1" >&2; usage ;;
	esac
done

[ -n "$WORKDIR" ] || usage
[ -x "$TORNER" ] || { echo "capture.sh: torner not built at $TORNER" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "capture.sh: must run as root (losetup/dmsetup/mount)" >&2; exit 1; }

die() { echo "capture.sh: $*" >&2; exit 1; }
say() { echo "[capture] $*" >&2; }

cleanup() {
	[ "$KEEP_STACK" = 1 ] && return
	fs_is_zfs "$FS" && fs_zfs_export
	[ -n "$MNT" ] && mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null
	dmsetup remove "$DM_NAME" 2>/dev/null
	[ -n "$LOOP_BACK" ] && losetup -d "$LOOP_BACK" 2>/dev/null
	[ -n "$LOOP_LOG" ]  && losetup -d "$LOOP_LOG" 2>/dev/null
	[ -n "$LOOP_PROG" ] && losetup -d "$LOOP_PROG" 2>/dev/null
	return 0
}
trap cleanup EXIT

mkdir -p "$WORKDIR" || die "cannot create $WORKDIR"
BACKING="$WORKDIR/backing.img"
LOG="$WORKDIR/log.img"
PROG="$WORKDIR/progress.img"
BASE="$WORKDIR/base.img"
MNT="$WORKDIR/mnt"

[ -n "$RUN_ID" ] || RUN_ID=$(date +%s)

# ---- images -----------------------------------------------------------
# Sparse: the backing device starts as all zeros, which is exactly what the
# base image has to be.  Replay reconstructs every state from base + log, so
# base must be the device as it was *before* dm-log-writes started recording.
say "creating images in $WORKDIR"
rm -f "$BACKING" "$LOG" "$PROG" "$BASE"
truncate -s "$DEV_SIZE" "$BACKING"  || die "truncate backing"
truncate -s "$LOG_SIZE" "$LOG"      || die "truncate log"
truncate -s "$PROG_SIZE" "$PROG"    || die "truncate progress"
truncate -s "$DEV_SIZE" "$BASE"     || die "truncate base"

modprobe dm-log-writes 2>/dev/null || true
grep -qw log-writes /proc/devices 2>/dev/null
dmsetup targets 2>/dev/null | grep -q log-writes || die "dm log-writes target unavailable (CONFIG_DM_LOG_WRITES)"

LOOP_BACK=$(losetup --show -f "$BACKING") || die "losetup backing"
LOOP_LOG=$(losetup --show -f "$LOG")      || die "losetup log"
LOOP_PROG=$(losetup --show -f "$PROG")    || die "losetup progress"
say "loops: backing=$LOOP_BACK log=$LOOP_LOG progress=$LOOP_PROG"

# ---- the write-cache precondition -------------------------------------
# If the backing device advertises no write cache, submit_bio_noacct() strips
# REQ_PREFLUSH/REQ_FUA before dm-log-writes can tag the entry.  Every entry
# then has flags == 0, the log collapses to a single epoch, and every ordering
# invariant passes vacuously.  Check before spending a workload on it.
WC_PATH="/sys/block/$(basename "$LOOP_BACK")/queue/write_cache"
WC=$(cat "$WC_PATH" 2>/dev/null || echo unknown)
say "backing write_cache = $WC"
if [ "$WC" != "write back" ]; then
	say "WARNING: backing device is '$WC'; FLUSH/FUA may be stripped."
	say "         attempting to enable write-back on $LOOP_BACK"
	echo "write back" > "$WC_PATH" 2>/dev/null || true
	WC=$(cat "$WC_PATH" 2>/dev/null || echo unknown)
	say "backing write_cache now = $WC"
fi

# ---- dm stack ---------------------------------------------------------
SECTORS=$(blockdev --getsz "$LOOP_BACK") || die "blockdev"
dmsetup create "$DM_NAME" --table "0 $SECTORS log-writes $LOOP_BACK $LOOP_LOG" \
	|| die "dmsetup create"
DEV="/dev/mapper/$DM_NAME"
say "stack up: $DEV -> $LOOP_BACK (log $LOOP_LOG)"

# ---- mkfs + mount -----------------------------------------------------
# ZFS mounts its own dataset at /<pool>; everything else mounts at $WORKDIR/mnt.
if fs_is_zfs "$FS"; then
	MNT="/$TORNER_ZPOOL"
else
	mkdir -p "$MNT"
fi

fs_setup "$FS" "$DEV" || die "mkfs/zpool create failed for $FS"
MOUNT_OPTS="$FS_MOUNT_OPTS"
UNTORN="$FS_UNTORN"

# What fsck says about a filesystem that has only just been created.  Anything
# in here is mkfs's doing, not a crash's, and must not count against P3.
fs_fsck_report "$FS" "$DEV" > "$WORKDIR/fsck-baseline.txt"
BASELINE_N=$(wc -l < "$WORKDIR/fsck-baseline.txt")
[ "$BASELINE_N" = 0 ] || say "note: pristine $FS already has $BASELINE_N fsck finding(s); P3 is judged relative to them"

if fs_is_zfs "$FS"; then
	# zpool create already mounted the dataset at $MNT
	mountpoint -q "$MNT" || die "zfs dataset not mounted at $MNT"
	say "zpool $TORNER_ZPOOL created on $DEV, dataset at $MNT"
else
	# shellcheck disable=SC2086
	mount $MOUNT_OPTS "$DEV" "$MNT" || die "mount $FS ($MOUNT_OPTS)"
	say "mounted $FS at $MNT ${MOUNT_OPTS:+($MOUNT_OPTS)}"
fi

# ---- workload ---------------------------------------------------------
# The progress log goes straight to its own loop device, never through the
# file system under test: a crash that loses a write must not be able to lose
# the record of that write too.
say "running torner gen: mode=$MODE threads=$THREADS unit=$UNIT pages=$PAGES duration=${DURATION}s${GEN_ARGS:+ ($GEN_ARGS)}"
# --mark-dev stamps the progress-log position into the log stream.  Replayed
# states need it to know which progress records they are answerable for; see
# the comment on emit_mark() in gen.c.
GEN_JSON=$("$TORNER" gen --file "$MNT/torner.dat" --progress-log "$LOOP_PROG" \
	--progress-direct --run-id "$RUN_ID" --mode "$MODE" --threads "$THREADS" \
	--pages "$PAGES" --unit "$UNIT" --duration "$DURATION" \
	--fsync-every "$FSYNC_EVERY" \
	--mark-dev "$DM_NAME" --mark-every "$MARK_EVERY" $UNTORN $GEN_ARGS) \
	|| die "torner gen failed"
echo "$GEN_JSON"

sync
if fs_is_zfs "$FS"; then
	fs_zfs_export || die "zpool export"
else
	umount "$MNT" || die "umount"
fi
dmsetup remove "$DM_NAME" || die "dmsetup remove"
DM_NAME=""
say "stack torn down"

# ---- verdict ----------------------------------------------------------
# The log is only usable if barriers were actually recorded.  loginv refuses a
# flagless log rather than reporting it clean, so this exit code is meaningful.
say "log summary:"
STAT=$("$TORNER" loginv --log "$LOG" --config "$FS" --stat-only)
STAT_RC=$?
echo "$STAT"

cat > "$WORKDIR/capture.json" <<EOF
{"fs":"$FS","mode":"$MODE","threads":$THREADS,"pages":$PAGES,"unit":$UNIT,
 "gen_args":"$GEN_ARGS",
 "duration_s":$DURATION,"fsync_every":$FSYNC_EVERY,"run_id":$RUN_ID,
 "dev_size":"$DEV_SIZE","write_cache":"$WC","file":"torner.dat",
 "base_is_zero":true,
 "base":"$BASE","log":"$LOG","progress":"$PROG","backing":"$BACKING"}
EOF

if [ "$STAT_RC" != 0 ]; then
	say "FAILED: log is not usable (see reason above)"
	exit 1
fi

# How each application write reached the device -- one bio, or in pieces --
# read off the log by content alone.  This is what the atom-* strategies plan
# from, and on its own it says which crash states can reach a torn write.
"$TORNER" atoms --log "$LOG" --run-id "$RUN_ID" --config "$FS" \
	--workload "torner:$MODE:t$THREADS" > "$WORKDIR/atoms.json" \
	|| say "warning: torner atoms failed; atom-* exploration will not work"
[ -s "$WORKDIR/atoms.json" ] && python3 - "$WORKDIR/atoms.json" <<'PYEOF' >&2
import json, sys
o = json.load(open(sys.argv[1]))
w, s = o["writes"], o["shape"]
print("[capture] application writes: %d  one bio %d  split in-window %d"
      "  split across FLUSH %d  partial %d  (reorderable %d)"
      % (w["workload"], s["one_bio"], s["split_window"], s["split_flush"],
         s["partial"], s["reorderable"]))
PYEOF

# backing.img is the device as the workload left it.  Replaying the whole log
# onto base reproduces it byte for byte (that equality is how the parser was
# validated), so keeping it just doubles the footprint -- and running out of
# room mid-explore shows up as every state stalling in uninterruptible I/O
# rather than as a disk-full error.
if [ "$KEEP_BACKING" = 0 ]; then
	rm -f "$BACKING"
else
	say "kept $BACKING (KEEP_BACKING=1)"
fi

say "artifacts: $BASE $LOG $PROG"
exit 0
