#!/bin/bash
# Overwrite cost: throughput and device write amplification, tau vs vanilla.
#
#   usage: overwrite-bench.sh [ext4|xfs|both]
#
# Rewriting existing blocks is what tau's undo-redo hybrid is designed around:
# the first dirty of a block is journaled, but once anchored a rewrite goes
# straight to its original location with only a small revoke tag journaled. So
# unlike an append (which is always a first dirty, and pays ~2x), a steady
# stream of overwrites should land close to 1x.
#
# The file is created and fsynced in a separate setup step that is NOT measured,
# so the journaled first-write is excluded.

cd "$(dirname "$0")" || exit 1
. ./common.sh

WHICH=${1:-both}
case "$WHICH" in both) FSLIST="ext4 xfs" ;; ext4|xfs) FSLIST=$WHICH ;; *) die "usage: $0 [ext4|xfs|both]" ;; esac

OW=${OW:-$TAU_BIN/tauoverwrite}
[ -x "$OW" ] || die "missing $OW (build with tools/tautest/Makefile)"

FILE_MB=${FILE_MB:-512}
FSIZE=$((FILE_MB * 1024 * 1024))

# label io-bytes count fsync-every mode
PATTERNS=(
	"seq-1m-nosync   1048576 512   0  seq"
	"rand-16k-sync   16384   8000  1  rand"
	"rand-16k-x16    16384   32000 16 rand"
)

# NVMe SMART counter: /proc/diskstats reports zeros for this passthrough device.
# One data unit is 512,000 bytes.
duw() {
	sudo nvme smart-log "$TAU_DEV" 2>/dev/null |
		awk -F: '/Data Units Written/ {split($2,a,"("); gsub(/[ \t]/,"",a[1]); print a[1]}'
}
duw_mb() { echo $(( ($2 - $1) * 512000 / 1048576 )); }

mount_for() {	# mount_for <fs> <vanilla|tau>
	sudo umount "$TAU_MNT" 2>/dev/null || true
	case "$1/$2" in
	ext4/vanilla) sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1 &&
	              sudo mount -t ext4 "$TAU_DEV" "$TAU_MNT" ;;
	ext4/tau)     sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1 &&
	              sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$TAU_MNT" ;;
	xfs/vanilla)  sudo "$MKFS_XFS" -f "$TAU_DEV" >/dev/null 2>&1 &&
	              sudo mount -t xfs "$TAU_DEV" "$TAU_MNT" ;;
	xfs/tau)      sudo "$MKFS_XFS" "$TAU_DEV" -f -l tjmaxsize=1G >/dev/null 2>&1 &&
	              sudo mount -t xfs -o tjournal "$TAU_DEV" "$TAU_MNT" ;;
	esac || die "mount failed for $1/$2"
}

sudo mkdir -p "$TAU_MNT"

for fs in $FSLIST; do
	echo
	echo "################ $fs ################"
	for p in "${PATTERNS[@]}"; do
		set -- $p
		label=$1 io=$2 cnt=$3 every=$4 mode=$5
		wrote_mb=$((io * cnt / 1048576))
		echo "-- $label (${io}B x $cnt = ${wrote_mb} MB rewritten, fsync/${every}, $mode) --"

		for variant in vanilla tau; do
			[ "$variant" = tau ] && tauflag=1 || tauflag=0
			mount_for "$fs" "$variant"

			# not measured: the first write of every block is journaled
			sudo "$OW" setup "$TAU_MNT/ow.dat" "$FSIZE" "$tauflag" >/dev/null
			sudo umount "$TAU_MNT"
			case "$fs/$variant" in
			ext4/vanilla) sudo mount -t ext4 "$TAU_DEV" "$TAU_MNT" ;;
			ext4/tau)     sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$TAU_MNT" ;;
			xfs/vanilla)  sudo mount -t xfs "$TAU_DEV" "$TAU_MNT" ;;
			xfs/tau)      sudo mount -t xfs -o tjournal "$TAU_DEV" "$TAU_MNT" ;;
			esac
			# warm the page cache so the rewrite hits resident, anchored blocks
			sudo "$OW" run "$TAU_MNT/ow.dat" "$FSIZE" "$io" "$cnt" "$every" "$mode" "$tauflag" >/dev/null

			sync; sleep 2; s0=$(duw)
			printf '   %-8s ' "$variant"
			sudo "$OW" run "$TAU_MNT/ow.dat" "$FSIZE" "$io" "$cnt" "$every" "$mode" "$tauflag"
			sudo umount "$TAU_MNT"; sync; sleep 3; s1=$(duw)
			echo "            device wrote $(duw_mb "$s0" "$s1") MB for ${wrote_mb} MB of rewrites"
		done
	done
done

echo
echo "kernel faults: $(kernel_faults)"
