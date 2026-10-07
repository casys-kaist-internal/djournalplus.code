#!/bin/bash
# Blocks a tau file freed and another file reused are not replayed over (#20).
#   usage: trunc-reuse-test.sh [xfs|ext4|both] [trunc|punch|collapse|keep|all]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-all}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [trunc|punch|collapse|keep|all]" >&2; exit 2 ;;
esac
[ "$CASES" = all ] && CASES="trunc punch collapse keep"

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		tag="$fs $c"
		echo
		echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		vm_ssh "TAU_FS_SIZE=${TAU_FS_SIZE:-8g} ~/tautest/guest/trunc-reuse.sh $fs $c write"
		w=$?
		if [ $w -eq 3 ]; then
			summary+="$tag: INCONCLUSIVE\n"
			vm_crash
			continue
		elif [ $w -ne 0 ]; then
			summary+="$tag: SKIP (setup failed)\n"
			vm_crash
			continue
		fi
		vm_crash || { rc=1; break 2; }
		vm_boot || { rc=1; break 2; }
		vm_ssh "~/tautest/guest/trunc-reuse.sh $fs $c verify"
		case $? in
		0) summary+="$tag: PASS\n" ;;
		3) summary+="$tag: INCONCLUSIVE\n" ;;
		*) summary+="$tag: FAIL\n"; vm_console_faults; rc=1 ;;
		esac
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
