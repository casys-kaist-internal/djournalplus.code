#!/bin/bash
# Does recovery actually repair a torn in-place copy from the journal?
#
# tau_do_checkpoint() writes a still-uncommitted transaction's buffers to their
# home blocks with the buffer merely VM-dirty and no folio lock, so that copy
# can tear. The code's defence is that recovery replays the older journaled
# generation over it. That defence had never been tested - crashing into the
# window is luck. So we tear the blocks ourselves, deterministically, and check
# the file comes back.
#
#   usage: repair-test.sh [xfs|ext4|both] [rounds] [size-mb]
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
ROUNDS=${2:-3}
SIZE_MB=${3:-4}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [rounds] [size-mb]" >&2; exit 2 ;;
esac

rc=0

for fs in $FSLIST; do
	echo
	echo "############ $fs ############"

	for round in $(seq 1 "$ROUNDS"); do
		echo "--- round $round/$ROUNDS ---"

		vm_boot_tested || { rc=1; break; }
		vm_sync_tests || { rc=1; break; }

		vm_ssh "~/tautest/guest/repair-write.sh $fs $SIZE_MB 40" &
		writer=$!
		sleep 12

		# The setup has to have landed, or tearing nothing proves nothing.
		if ! vm_ssh "sudo test -s /mnt/test/repair && test -s ~/repair-extent.txt"; then
			echo "RESULT[$fs round $round]: SKIP (setup did not land)"
			kill $writer 2>/dev/null
			vm_crash
			continue
		fi

		vm_crash || { rc=1; break; }
		kill $writer 2>/dev/null

		vm_boot_tested || { rc=1; break; }
		if vm_ssh "~/tautest/guest/repair-verify.sh $fs"; then
			echo "RESULT[$fs round $round]: PASS"
		else
			echo "RESULT[$fs round $round]: FAIL"
			vm_console_faults
			rc=1
			break
		fi
	done
done

echo
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
