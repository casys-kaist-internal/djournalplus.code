#!/bin/bash
# Drive guest/xfs-hold-stress.sh: does tau's XFS commit ordering bracket
# deadlock against the XFS log?  See that script for the cycle being tested.
#
# Runs the default configuration first, so a FAIL there says "reproduces on stock
# settings" rather than "reproduces if you tune logbufs down".
#
# 64m is not a choice: mkfs refuses a smaller log on a device this size.  Squeeze
# comes from the workload (churners fill the CIL), not from the log geometry.
#
# Before spending rounds here, run guest/xfs-hold-probe.sh once -- it wedges in
# ~25s on a tree with the bug, and on a fixed tree it prints call counts telling
# you whether the bracket was exercised at all.
#
#   usage: xfs-hold-test.sh [rounds] [secs]
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

ROUNDS=${1:-20}
SECS=${2:-5}

# logsize logbufs racers bigwriters churners
CONFIGS=${CONFIGS:-"
64m 8 8 3 6
64m 2 8 3 6
64m 8 12 3 8
"}

# A wedged guest leaves the ssh command hanging forever, so cap it here too.
# Must exceed the guest's own DEADLINE (which dumps stacks before giving up).
GUEST_DEADLINE=${GUEST_DEADLINE:-120}
HOST_TIMEOUT=${HOST_TIMEOUT:-$((ROUNDS * (SECS + 20) + GUEST_DEADLINE + 300))}

rc=0

vm_boot_tested || exit 1
vm_sync_tests || exit 1

echo "$CONFIGS" | while read -r logsize logbufs racers bigw churners; do
	[ -n "${logsize:-}" ] || continue
	echo
	echo "############ log=$logsize logbufs=$logbufs racers=$racers big=$bigw churn=$churners ############"

	if vm_ssh_timeout "$HOST_TIMEOUT" \
		"TAU_MKFS_XFS_OPTS='${TAU_MKFS_XFS_OPTS:-}' DEADLINE=$GUEST_DEADLINE CHURNERS=$churners \
		 ~/tautest/guest/xfs-hold-stress.sh $ROUNDS $racers $bigw $SECS $logsize $logbufs"
	then
		echo "RESULT[log=$logsize logbufs=$logbufs]: PASS"
	else
		echo "RESULT[log=$logsize logbufs=$logbufs]: FAIL (exit $?)"
		vm_console_faults
		echo "FAILED" > /tmp/tau-hold-test.failed
		break
	fi

	# Each configuration starts from a clean kernel: a wedge in one must not be
	# blamed on state the previous one left behind.
	vm_boot_tested || { echo "FAILED" > /tmp/tau-hold-test.failed; break; }
	vm_sync_tests  || { echo "FAILED" > /tmp/tau-hold-test.failed; break; }
done

# The loop runs in a subshell (pipe), so it cannot set rc directly.
[ -f /tmp/tau-hold-test.failed ] && { rc=1; rm -f /tmp/tau-hold-test.failed; }

echo
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
