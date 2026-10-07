#!/bin/bash
# Hammer mount -> write -> umount, which is where ->sync_fs meets teardown.
#
#   usage: umount-stress.sh <xfs|ext4|both> [cycles]
#
# tau_journal_destroy() ends in kfree(master), and both ext4_kill_sb() and
# xfs_kill_sb() call it *before* kill_block_super(). kill_block_super() then
# runs generic_shutdown_super() -> sync_filesystem() -> ->sync_fs(), so any
# ->sync_fs tau hook dereferences a freed master unless the pointer is cleared.
#
# It hides easily: right after the kfree the memory usually still holds the old
# contents, so the spinlock reads as unlocked and the (already emptied) list
# walk does nothing. It only bites once that allocation is reused -- which is
# what mount/umount churn plus memory pressure produces here.

cd "$(dirname "$0")" || exit 1
. ./common.sh

WHICH=${1:-both}
CYCLES=${2:-25}
case "$WHICH" in both) FSLIST="ext4 xfs" ;; ext4|xfs) FSLIST=$WHICH ;; *) die "usage: $0 <xfs|ext4|both> [cycles]" ;; esac

WRITE=${WRITE:-$TAU_BIN/tauwrite}
[ -x "$WRITE" ] || die "missing $WRITE"

sudo dmesg -C

# Keep the slab churning so a freed tau_master_s gets reused rather than
# sitting there still looking valid.
churn() {
	while :; do
		cat /proc/slabinfo >/dev/null 2>&1
		ls -lR /usr >/dev/null 2>&1
		dd if=/dev/zero of=/dev/null bs=1M count=64 2>/dev/null
	done
}
churn & CHURN=$!
trap 'kill $CHURN 2>/dev/null' EXIT

rc=0
for fs in $FSLIST; do
	echo "== $fs: $CYCLES mount/umount cycles =="
	mkfs_mount "$fs"
	for i in $(seq 1 "$CYCLES"); do
		sudo "$WRITE" "$TAU_MNT/u$i" $((2 * MB)) $((i % 250)) >/dev/null || rc=1
		# the umount is the interesting half: sync_filesystem() runs inside it
		if ! sudo umount "$TAU_MNT"; then
			echo "   FAIL: umount failed on cycle $i"
			rc=1
			break
		fi
		mount_tau "$fs" >/dev/null || { echo "   FAIL: remount $i"; rc=1; break; }
		printf '.'
	done
	echo
	sudo umount "$TAU_MNT" 2>/dev/null
done

kill $CHURN 2>/dev/null

faults=$(kernel_faults)
echo "== kernel faults: $faults =="
if [ "$faults" != "0" ]; then
	show_kernel_faults
	rc=1
fi

[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
