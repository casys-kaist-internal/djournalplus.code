#!/bin/bash
# Does sync(2) wait for a tau commit that is already in flight?
#
#   boot -> big write + one sync(2) -> SIGKILL qemu -> boot -> verify
#
#   usage: sync-race-test.sh [xfs|ext4|both] [rounds] [delay-us]
#
# This targets the window where master->running_tau has already been
# decremented but the commit has not landed. It is timing dependent, so it runs
# several rounds and fails if ANY of them loses data. A single passing round
# proves nothing; see guest/sync-race-write.sh for how the window is set up.
#
# WARNING: runs mkfs on $TAU_DEV inside the guest. That device is destroyed.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
ROUNDS=${2:-3}
DELAY=${3:-50000}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [rounds] [delay-us]" >&2; exit 2 ;;
esac

rc=0
lost=0

vm_boot_tested || exit 1
vm_sync_tests || exit 1

for fs in $FSLIST; do
	for r in $(seq 1 "$ROUNDS"); do
		echo
		echo "############ $fs round $r/$ROUNDS (delay ${DELAY}us) ############"

		if ! vm_ssh "COMMIT_AGE=${COMMIT_AGE:-0} ONLY=${ONLY:-both} ${SZ:+SZ=$SZ} ~/tautest/guest/sync-race-write.sh $fs $DELAY"; then
			echo "RESULT[$fs/$r]: FAIL (could not write)"
			rc=1
			continue
		fi

		echo "--- power cut ---"
		vm_crash || { rc=1; continue; }

		echo "--- rebooting ---"
		if ! vm_boot; then
			echo "RESULT[$fs/$r]: FAIL (VM did not come back)"
			vm_console_faults
			rc=1
			continue
		fi

		if vm_ssh "ONLY=${ONLY:-both} ${SZ:+SZ=$SZ} ~/tautest/guest/sync-race-verify.sh $fs"; then
			echo "RESULT[$fs/$r]: PASS"
		else
			echo "RESULT[$fs/$r]: FAIL"
			lost=$((lost + 1))
			rc=1
		fi
	done
done

echo
if [ $rc -eq 0 ]; then
	echo "ALL PASS"
else
	echo "FAILURES ($lost round(s) lost sync-acked data; console log: $VM_LOG)"
fi
exit $rc
