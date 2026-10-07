#!/bin/bash
# Crash the VM while the checkpoint daemon may be flushing an uncommitted
# transaction's buffers to their home blocks, and check the file did not tear.
#
# Why this exists: tau_do_checkpoint() marks such a buffer VM-dirty without the
# folio lock, so the in-place copy can tear. The code argues recovery repairs
# it from the older journaled copy. But generation B already committed a revoke
# for those blocks, which tells recovery NOT to replay the journaled copy - so
# the argument may not hold. Rather than trust the comment, crash into it.
#
# The crash delay is randomised per round because the dangerous window is short
# and we cannot aim at it directly; the odds come from repetition.
#
#   usage: cp-race-test.sh [xfs|ext4|both] [rounds] [size-mb]
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
ROUNDS=${2:-10}
SIZE_MB=${3:-8}
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
		# Wait for the workload to say the three generations are down,
		# then crash a moment later. A fixed delay cannot straddle this:
		# too early and the file is still zeroes, too late and C has
		# been committed in the background so nothing rolls back.
		delay=${CPRACE_DELAY:-$((1 + RANDOM % 4))}
		echo "--- round $round/$ROUNDS (crash ${delay}s after armed) ---"

		vm_boot_tested || { rc=1; break; }
		vm_sync_tests || { rc=1; break; }
		vm_ssh "rm -f ~/cprace-armed"

		vm_ssh "~/tautest/guest/cp-race-write.sh $fs $SIZE_MB 60" &
		writer=$!

		armed=0
		for _ in $(seq 1 120); do
			if vm_ssh "test -f ~/cprace-armed" 2>/dev/null; then
				armed=1
				break
			fi
			sleep 1
		done
		if [ "$armed" -eq 0 ]; then
			echo "RESULT[$fs round $round]: SKIP (never armed)"
			kill $writer 2>/dev/null
			vm_crash
			continue
		fi
		sleep "$delay"

		vm_crash || { rc=1; break; }
		kill $writer 2>/dev/null

		vm_boot_tested || { rc=1; break; }
		if vm_ssh "~/tautest/guest/cp-race-verify.sh $fs"; then
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
