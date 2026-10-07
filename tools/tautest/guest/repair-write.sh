#!/bin/bash
# Lay down a journaled generation, record where its blocks physically live, and
# leave an uncommitted generation behind. The host then crashes us; the next
# step overwrites those physical blocks directly, which is what a checkpoint
# in-place flush looks like when it tears.
#
#   usage: repair-write.sh <xfs|ext4> [size-mb] [hold-seconds]

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
SIZE_MB=${2:-4}
HOLD=${3:-30}
EXTENT_FILE=${EXTENT_FILE:-$HOME/repair-extent.txt}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> [size-mb] [hold-seconds]"

echo "== preparing $FS =="
mkfs_mount "$FS"

F=$TAU_MNT/repair

echo "== generation A (0x41), fsync-acked =="
sudo "$TAU_BIN/tauwrite" "$F" $((SIZE_MB * MB)) $((0x41)) || die "tauwrite A failed"

# Where do those blocks actually live?  Record it OUTSIDE the test filesystem
# and sync, or the crash takes the note with it.
echo "== recording physical extent =="
# "   0:        0..       4:   25258504..  25258508:      5:   last,eof"
# -> drop ".." and ":" so the fields line up, then take physical start/end.
sudo filefrag -b4096 -v "$F" | awk '
	/^[[:space:]]*[0-9]+:/ {
		gsub(/\.\./, " ");
		gsub(/:/, " ");
		print $4, $5
	}' | sudo tee "$EXTENT_FILE" >/dev/null
sync
[ -s "$EXTENT_FILE" ] || die "could not record the extent map"
echo "  $(wc -l < "$EXTENT_FILE") extent(s):"
cat "$EXTENT_FILE"

echo "== generation B (0x42), NOT fsynced =="
sudo "$TAU_BIN/tauwrite_nofsync" "$F" $((SIZE_MB * MB)) $((0x42)) ||
	die "tauwrite_nofsync B failed"

echo "== armed, holding =="
sleep "$HOLD"
echo "== hold expired =="
