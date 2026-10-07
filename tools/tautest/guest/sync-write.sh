#!/bin/bash
# Write one tau file per durability barrier, then leave the box to be crashed.
#
#   usage: sync-write.sh <xfs|ext4>
#
# fsync(2) on a tau file lands in ext4_tau_sync_file/xfs_tau_sync_file, which
# commit the tau transaction. sync(2) and syncfs(2) instead go through
# sync_inodes_sb(), which hands the work to a bdi kworker -- so whichever tau
# hook lives in ->writepages sees PF_KTHREAD set. This lays out one file per
# barrier so a single crash tells us which of them actually persist.
#
# s_fsync is the control: if that one fails, the problem is not sync(2).

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"
SYNCBIN=${SYNCBIN:-$TAU_BIN/tausync}
[ -x "$SYNCBIN" ] || die "missing $SYNCBIN (build with tools/tautest/Makefile)"

echo "== preparing $FS on $TAU_DEV =="
mkfs_mount "$FS"
sudo dmesg -C

D=$TAU_MNT
SZ=$((3 * MB))

# Each barrier gets its own file and its own byte value, so the verify step can
# say exactly which barrier failed.
#
# Order matters: sync(2) and syncfs(2) are whole-filesystem barriers, so any
# file written before them gets carried along for free. The two that are meant
# to persist nothing of their own -- s_sfr and s_none -- therefore have to come
# last, otherwise they pass for the wrong reason.
sudo "$SYNCBIN" "$D/s_fsync"  "$SZ" 111 fsync
sudo "$SYNCBIN" "$D/s_sync"   "$SZ" 122 sync
sudo "$SYNCBIN" "$D/s_syncfs" "$SZ" 133 syncfs

# s_sync2: fsync one pattern, then overwrite it and only sync(2). The overwrite
# takes the anchored->revoke path, so nothing lands in the tau transaction --
# the data has to reach its home location and the revoke has to be committed.
# This is the case a whole-file commit can silently skip.
sudo "$SYNCBIN" "$D/s_sync2"  "$SZ" 166 fsync
sudo "$SYNCBIN" "$D/s_sync2"  "$SZ" 177 sync

sudo "$SYNCBIN" "$D/s_sfr"    "$SZ" 144 sfr
sudo "$SYNCBIN" "$D/s_none"   "$SZ" 155 none

echo "== written, ready to crash =="
