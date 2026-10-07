#!/bin/bash
# Does sync(2)/syncfs(2) actually make a tau file durable?
#
#   boot -> write one file per barrier -> SIGKILL qemu -> boot -> verify
#
#   usage: sync-test.sh [xfs|ext4|both]
#
# fsync is included as a control. If fsync survives and sync/syncfs do not,
# the tau commit hook is not reachable from the sync path.
#
# WARNING: runs mkfs on $TAU_DEV inside the guest. That device is destroyed.

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

	if ! vm_ssh "~/tautest/guest/sync-write.sh $fs"; then
		echo "RESULT[$fs]: FAIL (could not write)"
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

	echo "--- verifying ---"
	if vm_ssh "~/tautest/guest/sync-verify.sh $fs"; then
		echo "RESULT[$fs]: PASS"
	else
		echo "RESULT[$fs]: FAIL"
		rc=1
	fi
done

echo
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
