#!/bin/bash
# Blocks a tau file freed and another file reused are not replayed over (#20).
# A free the host lost in a power cut leaves the file as it was (kernel
# plan.md §12.4): the range's newest copies stay in the journal until the host
# has the free.
#   truncr     truncate with the range's writes still in the running tx: the
#              commit that takes them tags the blocks it gives them
#   gate       truncate, the host told to commit late: the file as before it
#   gatepunch  the same with a punch
#   uncond     control: gate with the revoke tags unconditional -- must fail
#   nohold     control: gate with the txs not held for the host -- must fail
#   usage: trunc-reuse-test.sh [xfs|ext4|both] [trunc|truncr|punch|collapse|keep|gate|gatepunch|uncond|nohold|all]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-all}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [trunc|truncr|punch|collapse|keep|gate|gatepunch|uncond|nohold|all]" >&2; exit 2 ;;
esac
[ "$CASES" = all ] && CASES="trunc truncr punch collapse keep gate gatepunch uncond nohold"

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		tag="$fs $c"
		echo
		echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		case $c in
		uncond) env="FREE_UNCOND=1"; gc=gate ;;
		nohold) env="FREE_NOHOLD=1"; gc=gate ;;
		*) env=""; gc=$c ;;
		esac
		vm_ssh "$env TAU_FS_SIZE=${TAU_FS_SIZE:-8g} ~/tautest/guest/trunc-reuse.sh $fs $gc write"
		w=$?
		if [ $w -eq 3 ]; then
			summary+="$tag: INCONCLUSIVE\n"
			vm_crash
			continue
		elif [ $w -ne 0 ] && { [ "${gc#gate}" != "$gc" ] || [ "$gc" = truncr ] ||
				       [ -n "$(vm_console_faults)" ]; }; then
			summary+="$tag: FAIL (before the power cut)\n"
			vm_console_faults
			rc=1
			vm_crash
			continue
		elif [ $w -ne 0 ]; then
			summary+="$tag: SKIP (setup failed)\n"
			vm_crash
			continue
		fi
		vm_crash || { rc=1; break 2; }
		vm_boot || { rc=1; break 2; }
		vm_ssh "~/tautest/guest/trunc-reuse.sh $fs $gc verify"
		v=$?
		if [ "$gc" != "$c" ]; then
			# a control: the file must come back wrong
			case $v in
			1) summary+="$tag: PASS (the control failed, as it must)\n" ;;
			3) summary+="$tag: INCONCLUSIVE\n" ;;
			*) summary+="$tag: FAIL (the control passed: the run does not see it)\n"
			   rc=1 ;;
			esac
			continue
		fi
		case $v in
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
