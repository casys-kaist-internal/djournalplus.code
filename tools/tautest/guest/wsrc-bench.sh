#!/bin/bash
# The write path's cost per pwrite (no fsync), overwriting a cached tau file: what
# pinning a write's source adds.  4 KiB writes take no pin (the control).
#   usage: wsrc-bench.sh <xfs|ext4> [reps] [count]
cd ~/tautest/guest || exit 1
. ./common.sh
FS=${1:-}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <xfs|ext4> [reps] [count]" ;; esac
REPS=${2:-5}
COUNT=${3:-200000}
mkfs_mount "$FS"
for size in ${SIZES:-4096 8192 16384 65536}; do
	for r in $(seq "$REPS"); do
		sudo rm -f "$TAU_MNT/b"
		echo "$FS r$r $(sudo taskset -c 2 "$TAU_BIN/taukill" bench "$TAU_MNT/b" $size $((64 << 20)) "$COUNT")"
	done
done
sudo umount "$TAU_MNT"
