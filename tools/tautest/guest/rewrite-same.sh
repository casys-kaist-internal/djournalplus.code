#!/bin/bash
# Rewriting the SAME region over and over, write+fsync each time.
#
#   usage: rewrite-same.sh [ext4|xfs|both]
#
# This is the case the undo-redo hybrid should win outright: after the first
# dirty is journaled and anchored, every later rewrite of that same block can
# go straight to its original location with only a revoke tag journaled, so the
# device should see roughly the logical write volume and no more.
#
# The sizes straddle TAU_SMALL_TX (512 journal blocks, i.e. 2 MB): a transaction
# below it is checkpointed eagerly by tau_should_do_checkpoint(), which puts the
# block back in a state where the next write is a first dirty again. The rows
# above and below that line are therefore the interesting comparison.

cd "$(dirname "$0")" || exit 1
. ./common.sh

WHICH=${1:-both}
case "$WHICH" in both) FSLIST="ext4 xfs" ;; ext4|xfs) FSLIST=$WHICH ;; *) die "usage: $0 [ext4|xfs|both]" ;; esac

OW=${OW:-$TAU_BIN/tauoverwrite}
[ -x "$OW" ] || die "missing $OW"

# label region-bytes count   (io == region, so every write hits the same offset)
PATTERNS=(
	"same-4k     4096    20000"
	"same-64k    65536   5000"
	"same-1m     1048576 500"
	"same-4m     4194304 150"
)

duw() {
	sudo nvme smart-log "$TAU_DEV" 2>/dev/null |
		awk -F: '/Data Units Written/ {split($2,a,"("); gsub(/[ \t]/,"",a[1]); print a[1]}'
}

do_mount() {	# do_mount <fs> <vanilla|tau> <mkfs 0|1>
	sudo umount "$TAU_MNT" 2>/dev/null || true
	case "$1/$2" in
	ext4/vanilla) [ "$3" = 1 ] && sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1
	              sudo mount -t ext4 "$TAU_DEV" "$TAU_MNT" ;;
	ext4/tau)     [ "$3" = 1 ] && sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1
	              sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$TAU_MNT" ;;
	xfs/vanilla)  [ "$3" = 1 ] && sudo "$MKFS_XFS" -f "$TAU_DEV" >/dev/null 2>&1
	              sudo mount -t xfs "$TAU_DEV" "$TAU_MNT" ;;
	xfs/tau)      [ "$3" = 1 ] && sudo "$MKFS_XFS" "$TAU_DEV" -f -l tjmaxsize=1G >/dev/null 2>&1
	              sudo mount -t xfs -o tjournal "$TAU_DEV" "$TAU_MNT" ;;
	esac || die "mount failed $1/$2"
}

sudo mkdir -p "$TAU_MNT"

for fs in $FSLIST; do
	echo
	echo "################ $fs ################"
	for p in "${PATTERNS[@]}"; do
		set -- $p
		label=$1 sz=$2 cnt=$3
		logical=$((sz * cnt / 1048576))
		blocks=$((sz / 4096))
		note="below"; [ "$blocks" -ge 512 ] && note="above"
		echo "-- $label ($((sz / 1024)) KB x $cnt = ${logical} MB logical, $blocks blocks: $note TAU_SMALL_TX --"

		for variant in vanilla tau; do
			[ "$variant" = tau ] && tf=1 || tf=0
			do_mount "$fs" "$variant" 1
			sudo "$OW" setup "$TAU_MNT/s.dat" "$sz" "$tf" >/dev/null
			do_mount "$fs" "$variant" 0	  # remount, keep the file
			sync; sleep 2; s0=$(duw)
			printf '   %-8s ' "$variant"
			sudo "$OW" run "$TAU_MNT/s.dat" "$sz" "$sz" "$cnt" 1 seq "$tf"
			sudo umount "$TAU_MNT"; sync; sleep 3; s1=$(duw)
			dev=$(( (s1 - s0) * 512000 / 1048576 ))
			printf '            device %s MB for %s MB logical' "$dev" "$logical"
			[ "$logical" -gt 0 ] && printf '  (%s.%02dx)' \
				$((dev / logical)) $(( (dev * 100 / logical) % 100 ))
			echo
		done
	done
	sudo umount "$TAU_MNT" 2>/dev/null || true
done

echo
echo "kernel faults: $(kernel_faults)"
