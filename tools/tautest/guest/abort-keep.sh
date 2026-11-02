#!/bin/bash
# The unmount after an abort leaves the journal for the next mount (#65): an
# fsync'd rewrite that lives only in the journal comes back after umount +
# mount, on a discard mount, where blocks the unmount gave back are trimmed.
# usage: abort-keep.sh <xfs|ext4>
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1
P=/sys/module/tau_journal/parameters
F=$TAU_MNT/keep
SIZE=$((1 << 20))
small=$(cat $P/tau_cp_small_tx); age=$(cat $P/tau_max_transaction_age)

restore() {
	echo 0 | sudo tee $P/tau_inject_fault >/dev/null
	echo "$small" | sudo tee $P/tau_cp_small_tx >/dev/null
	echo "$age" | sudo tee $P/tau_max_transaction_age >/dev/null
}
trap restore EXIT

echo 0 | sudo tee $P/tau_inject_fault >/dev/null
TAU_MOUNT_OPTS=tjournal,discard mkfs_mount "$FS"
sudo chmod 777 "$TAU_MNT"
sudo dmesg -C
# the rewrite stays in the journal: no checkpoint of a small tx, none by age
echo 0 | sudo tee $P/tau_cp_small_tx >/dev/null
echo 3600 | sudo tee $P/tau_max_transaction_age >/dev/null

"$TAUWRITE" "$F" $SIZE 1 >/dev/null || { echo "RESULT: FAIL (first write)"; exit 1; }
"$TAUWRITE" "$F" $SIZE 2 >/dev/null || { echo "RESULT: FAIL (rewrite)"; exit 1; }
# the next commit's record fails: the journal aborts
echo 3 | sudo tee $P/tau_inject_fault >/dev/null
"$TAUWRITE" "$TAU_MNT/other" 4096 3 >/dev/null 2>&1
sudo dmesg | grep -q "aborting" || { echo "RESULT: INCONCLUSIVE (no abort)"; exit 3; }
restore

sudo umount "$TAU_MNT" || { echo "RESULT: FAIL (umount)"; exit 1; }
TAU_MOUNT_OPTS=tjournal mount_tau "$FS"
sudo dmesg | grep -E "TAU: replay done|orphan" | tail -3 | sed 's/^/  /'
rc=0
expect_md5 keep "$F" "$(md5_of_repeat 2 $SIZE)" || rc=1
sudo umount "$TAU_MNT" || rc=1
warn=$(sudo dmesg | grep -cE "WARNING: CPU|orphan list check failed")
[ "$warn" = 0 ] || { sudo dmesg | grep -A6 -E "WARNING: CPU|orphan list check failed" | head -20; rc=1; }
[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
fsck_tau "$FS" || rc=1
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
