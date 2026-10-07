#!/bin/bash
# fallocate / truncate range operations keep a tau file's data, at runtime and
# after a power cut.
#   usage: range-test.sh [xfs|ext4|both] [collapse|insert|zero|upunch|uzero|utrunc|extend|all]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-all}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [collapse|insert|zero|upunch|uzero|utrunc|extend|all]" >&2; exit 2 ;;
esac
[ "$CASES" = all ] && CASES="collapse insert zero upunch uzero utrunc extend"

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		tag="$fs $c"
		echo
		echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		if ! vm_ssh "~/tautest/guest/range.sh $fs $c write"; then
			summary+="$tag: FAIL (runtime)\n"
			vm_console_faults
			rc=1
			vm_crash
			continue
		fi
		vm_crash || { rc=1; break 2; }
		vm_boot || { rc=1; break 2; }
		if vm_ssh "~/tautest/guest/range.sh $fs $c verify"; then
			summary+="$tag: PASS\n"
		else
			summary+="$tag: FAIL (after the power cut)\n"
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
