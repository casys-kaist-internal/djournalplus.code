#!/bin/bash
# Crash-recovery run for the fallocate/unwritten path:
#
#   boot -> salt free space -> fallocate + tau writes -> SIGKILL qemu
#        -> boot -> verify contents AND that no stale block leaked
#
# See guest/falloc-write.sh for what the matrix covers and why the salt is
# there.  This is the companion to crash-test.sh, which only exercises delayed
# allocation.
#
#   usage: falloc-test.sh [xfs|ext4|both]
#
# WARNING: this runs mkfs on $TAU_DEV inside the guest (default /dev/nvme0n1).
# Everything on that device is destroyed.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both]" >&2; exit 2 ;;
esac

rc=0

vm_boot_tested || exit 1
vm_sync_tests || exit 1

for fs in $FSLIST; do
	echo
	echo "############ $fs ############"

	echo "--- laying out the fallocate matrix ---"
	# TAU_FS_SIZE keeps the filesystem small enough that the salt can fill it;
	# see guest/falloc-write.sh for why that is what gives the stale-data check
	# its power.
	if ! vm_ssh "TAU_MKFS_XFS_OPTS='${TAU_MKFS_XFS_OPTS:-}' \
		     TAU_FS_SIZE='${TAU_FS_SIZE:-}' SALT_CAP_MB='${SALT_CAP_MB:-}' \
		     ~/tautest/guest/falloc-write.sh $fs"; then
		echo "RESULT[$fs]: FAIL (could not write the matrix)"
		rc=1
		vm_is_up || vm_boot
		continue
	fi

	echo "--- power cut ---"
	vm_crash || { rc=1; continue; }

	echo "--- rebooting ---"
	if ! vm_boot; then
		echo "RESULT[$fs]: FAIL (VM did not come back)"
		vm_console_faults
		rc=1
		continue
	fi

	echo "--- verifying recovery ---"
	if vm_ssh "~/tautest/guest/falloc-verify.sh $fs"; then
		echo "RESULT[$fs]: PASS"
	else
		echo "RESULT[$fs]: FAIL"
		vm_console_faults
		rc=1
	fi
done

echo
if [ $rc -eq 0 ]; then
	echo "ALL PASS"
else
	echo "FAILURES (console log: $VM_LOG)"
fi
exit $rc
