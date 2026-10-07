#!/bin/bash
# Run the concurrency stress inside the guest and report back. No crash: this
# hunts for kernel BUGs and hangs in the write-during-commit paths.
#
#   usage: stress-test.sh [xfs|ext4|both] [rounds] [racers] [seconds]
#
# If the guest wedges, ssh may stop answering — the serial console log still
# has the stacks (sysrq-w is triggered automatically on a detected hang).
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
ROUNDS=${2:-200}
RACERS=${3:-6}
SECS=${4:-5}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [rounds] [racers] [seconds]" >&2; exit 2 ;;
esac

rc=0

vm_boot_tested || exit 1
vm_sync_tests || exit 1

for fs in $FSLIST; do
	echo
	echo "############ $fs stress ############"
	if vm_ssh "TAU_MOUNT_OPTS='${TAU_MOUNT_OPTS:-tjournal}' ~/tautest/guest/stress.sh $fs $ROUNDS $RACERS $SECS"; then
		echo "RESULT[$fs]: PASS"
	else
		echo "RESULT[$fs]: FAIL"
		echo "--- serial console ---"
		vm_console_faults
		rc=1
		# A wedged guest cannot run the next filesystem.
		vm_is_up || { echo "guest is unresponsive, rebooting"; vm_reboot || break; }
	fi
done

echo
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
