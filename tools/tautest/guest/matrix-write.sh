#!/bin/bash
# Lay out the crash-recovery matrix on a freshly made tau filesystem.
#
# Every file here was fsync-acked, so after a crash + recovery it must read
# back exactly as written (matrix-verify.sh checks that). The last step writes
# large files to push the journal into checkpointing, which is what made the
# earlier data-loss bugs reproducible.
#
#   usage: matrix-write.sh <xfs|ext4>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"
check_tools

echo "== preparing $FS on $TAU_DEV =="
mkfs_mount "$FS"
sudo dmesg -C

D=$TAU_MNT

echo "== writing matrix =="
# fA: small file, single transaction
sudo "$TAUWRITE" "$D/fA" $((3 * MB)) 11

# fB: larger than one 128MB journal segment -> multi-segment allocation
sudo "$TAUWRITE" "$D/fB" $((200 * MB)) 22

# fC: overwrite. The second write goes in place with a revoke record; recovery
#     must honour the revoke and not replay the older journaled copy.
sudo "$TAUWRITE" "$D/fC" $((3 * MB)) 33
sudo "$TAUWRITE" "$D/fC" $((3 * MB)) 44

# fD: two regions with a hole between them -> multiple transactions, tid 0 and 1
sudo "$TAUWRITE" "$D/fD" $((3 * MB)) 55 0
sudo "$TAUWRITE" "$D/fD" $((3 * MB)) 66 $((8 * MB))

# fE: unaligned offset and partial block
sudo "$TAUWRITE" "$D/fE" 5000 77 512

# fF: never fsynced -> negative control, content is not checked
sudo "$TAUWRITE_NOFSYNC" "$D/fF" $((3 * MB)) 88

# fG: three consecutive overwrites. Exercises the re-journal cycle
#     (anchored -> revoke -> re-journal) rather than a single revoke.
sudo "$TAUWRITE" "$D/fG" $((2 * MB)) 91
sudo "$TAUWRITE" "$D/fG" $((2 * MB)) 92
sudo "$TAUWRITE" "$D/fG" $((2 * MB)) 93

# race: writer thread + fsync thread on the same range, then a settled write.
#       Exercises write-during-commit (BH_TauPending) and revoke handling.
sudo "$TAURACE" "$D/race" $((1 * MB)) 6

# pressure: force checkpointing so the journal recycles segments
for i in 1 2; do
	sudo "$TAUWRITE" "$D/big$i" $((120 * MB)) $((50 + i))
done

echo "== matrix ready =="
echo "Now crash the VM (host: tools/tautest/host/crash-test.sh does this for you),"
echo "reboot, and run: matrix-verify.sh $FS"
