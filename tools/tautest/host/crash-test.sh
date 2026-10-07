#!/bin/bash
# Full crash-recovery run, driven from the host:
#
#   boot -> write the matrix -> SIGKILL qemu (power cut) -> boot -> verify
#
# Every file in the matrix was fsync-acked before the crash, so anything that
# does not come back byte-for-byte is a durability bug.
#
#   usage: crash-test.sh [xfs|ext4|both]
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

	echo "--- laying out the matrix ---"
	if ! vm_ssh "TAU_MKFS_XFS_OPTS='${TAU_MKFS_XFS_OPTS:-}' ~/tautest/guest/matrix-write.sh $fs"; then
		echo "RESULT[$fs]: FAIL (could not write the matrix)"
		rc=1
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
	if vm_ssh "~/tautest/guest/matrix-verify.sh $fs"; then
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
