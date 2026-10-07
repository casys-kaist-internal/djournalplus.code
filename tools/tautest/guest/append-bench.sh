#!/bin/bash
# Compare append performance with and without taujournal.
#
#   usage: append-bench.sh [ext4|xfs|both]
#
# Appending is where tau has the most work to do: the blocks do not exist yet,
# so delayed allocation plus the commit-time allocation sit on the fsync path.
# Each filesystem is measured three ways:
#
#   vanilla       plain mount, no tjournal            <- the baseline
#   tau-mount     tjournal mount, file NOT activated  <- cost of just mounting
#   tau-file      tjournal mount, O_TAU_UNTORN        <- the journaled path
#
# The middle row matters: it separates "tau is on this mount" from "tau owns
# this file", so a slowdown can be attributed to one or the other.

cd "$(dirname "$0")" || exit 1
. ./common.sh

WHICH=${1:-both}
case "$WHICH" in both) FSLIST="ext4 xfs" ;; ext4|xfs) FSLIST=$WHICH ;; *) die "usage: $0 [ext4|xfs|both]" ;; esac

APPEND=${APPEND:-$TAU_BIN/tauappend}
[ -x "$APPEND" ] || die "missing $APPEND (build with tools/tautest/Makefile)"

# pattern: label record-bytes count fsync-every
PATTERNS=(
	"wal-4k-sync      4096    20000  1"
	"wal-16k-sync     16384   10000  1"
	"batch-4k-x16     4096    40000  16"
	"stream-1m-nosync 1048576 512    0"
)

mount_plain() {
	sudo umount "$TAU_MNT" 2>/dev/null || true
	case "$1" in
	ext4) sudo "$MKE2FS" -t ext4 -F "$TAU_DEV" >/dev/null 2>&1 &&
	      sudo mount -t ext4 "$TAU_DEV" "$TAU_MNT" ;;
	xfs)  sudo "$MKFS_XFS" -f "$TAU_DEV" >/dev/null 2>&1 &&
	      sudo mount -t xfs "$TAU_DEV" "$TAU_MNT" ;;
	esac || die "plain mount failed"
}

mount_tau() {
	sudo umount "$TAU_MNT" 2>/dev/null || true
	case "$1" in
	ext4) sudo "$MKE2FS" -t ext4 -F "$TAU_DEV" >/dev/null 2>&1 &&
	      sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$TAU_MNT" ;;
	xfs)  sudo "$MKFS_XFS" "$TAU_DEV" -f -l tjmaxsize=1G >/dev/null 2>&1 &&
	      sudo mount -t xfs -o tjournal "$TAU_DEV" "$TAU_MNT" ;;
	esac || die "tau mount failed"
}

run_one() {	# run_one <label> <rec> <count> <every> <tau-flag>
	sudo "$APPEND" "$TAU_MNT/append.dat" "$2" "$3" "$4" "$5"
	sudo rm -f "$TAU_MNT/append.dat"
	sync
}

sudo mkdir -p "$TAU_MNT"

for fs in $FSLIST; do
	echo
	echo "################ $fs ################"
	for p in "${PATTERNS[@]}"; do
		set -- $p
		label=$1 rec=$2 cnt=$3 every=$4
		echo "-- $label (record ${rec}B x $cnt, fsync every ${every:-0}) --"

		mount_plain "$fs"
		printf '   %-10s ' "vanilla"
		run_one "$label" "$rec" "$cnt" "$every" 0

		mount_tau "$fs"
		printf '   %-10s ' "tau-mount"
		run_one "$label" "$rec" "$cnt" "$every" 0

		printf '   %-10s ' "tau-file"
		run_one "$label" "$rec" "$cnt" "$every" 1
	done
	sudo umount "$TAU_MNT" 2>/dev/null || true
done

echo
echo "kernel faults: $(kernel_faults)"
