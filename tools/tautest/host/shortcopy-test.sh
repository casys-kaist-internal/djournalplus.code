#!/bin/bash
# A write whose source faults partway leaves the rest of its block alone, at
# runtime and after a power cut (#24); one that faults before its first byte
# does not let the fsync after it return before a commit in flight (efault, #69).
#   usage: shortcopy-test.sh [xfs|ext4|both] [short|efault|all]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

usage() { echo "usage: $0 [xfs|ext4|both] [short|efault|all]" >&2; exit 2; }
FSLIST=${1:-both}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) usage ;;
esac
CASES=${2:-all}
case "$CASES" in
all) CASES="short efault" ;;
short|efault) ;;
*) usage ;;
esac

rc=0
summary=""
for fs in $FSLIST; do
	echo
	echo "############ $fs ############"
	vm_boot_tested || { rc=1; break; }
	vm_sync_tests || { rc=1; break; }
	for c in $CASES; do
		[ $c = short ] && w=write v=verify || w=efault v=efault-verify
		if ! vm_ssh "~/tautest/guest/shortcopy.sh $fs $w"; then
			summary+="$fs $c: FAIL (runtime)\n"
			vm_console_faults
			rc=1
			vm_crash
			vm_boot || { rc=1; break 2; }
			continue
		fi
		vm_crash || { rc=1; break 2; }
		vm_boot || { rc=1; break 2; }
		if vm_ssh "~/tautest/guest/shortcopy.sh $fs $v"; then
			summary+="$fs $c: PASS\n"
		else
			summary+="$fs $c: FAIL (after the power cut)\n"
			vm_console_faults
			rc=1
		fi
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
