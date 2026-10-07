#!/bin/bash
# A block that missed the transaction at write_end is redone, not dropped: the
# write survives a power cut after its fsync (#41).  Needs CONFIG_TAU_PROBE_TORN.
#   usage: writeend-test.sh [xfs|ext4|both]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

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
summary=""
for fs in $FSLIST; do
	echo
	echo "############ $fs ############"
	vm_boot_tested || { rc=1; break; }
	vm_sync_tests || { rc=1; break; }
	if ! vm_ssh "~/tautest/guest/writeend.sh $fs write"; then
		summary+="$fs: FAIL (before the power cut)\n"
		vm_console_faults
		rc=1
		vm_crash
		continue
	fi
	vm_crash || { rc=1; break; }
	vm_boot || { rc=1; break; }
	if vm_ssh "~/tautest/guest/writeend.sh $fs verify"; then
		summary+="$fs: PASS\n"
	else
		summary+="$fs: FAIL\n"
		vm_console_faults
		rc=1
	fi
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
