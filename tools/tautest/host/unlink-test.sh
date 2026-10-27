#!/bin/bash
# An unlinked tau file is let go by whoever holds it last, not at unmount; the
# blocks it gave back can be reused across a power cut (#24).  Its journal
# segments wait for the host to have the unlink (plan.md §12.3):
#   gate    the unlink lost in a power cut: the file is back with its last fsync
#   nogate  the control: segments given back at once, the same run must fail
#   reuse   a new tau file under the dead one's ino: the host commit is forced
#   usage: unlink-test.sh [xfs|ext4|both] [live|crash|gate|nogate|reuse|all]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-all}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [live|crash|gate|nogate|reuse|all]" >&2; exit 2 ;;
esac
[ "$CASES" = all ] && CASES="live crash gate nogate reuse"

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		tag="$fs $c"
		echo
		echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		if [ "$c" = live ]; then
			vm_ssh "~/tautest/guest/unlink.sh $fs live"
			case $? in
			0) summary+="$tag: PASS\n" ;;
			*) summary+="$tag: FAIL\n"; vm_console_faults; rc=1 ;;
			esac
			continue
		fi
		case $c in
		crash) write="TAU_FS_SIZE=${TAU_FS_SIZE:-8g} ~/tautest/guest/unlink.sh $fs write"
		       verify="~/tautest/guest/unlink.sh $fs verify" ;;
		gate) write="~/tautest/guest/unlink.sh $fs gate-write"
		      verify="~/tautest/guest/unlink.sh $fs gate-verify" ;;
		nogate) write="NOGATE=1 ~/tautest/guest/unlink.sh $fs gate-write"
			verify="~/tautest/guest/unlink.sh $fs gate-verify" ;;
		reuse) write="~/tautest/guest/unlink.sh $fs reuse-write"
		       verify="~/tautest/guest/unlink.sh $fs reuse-verify" ;;
		*) echo "unknown case $c" >&2; rc=1; continue ;;
		esac
		vm_ssh "$write"
		case $? in
		0) ;;
		3) summary+="$tag: INCONCLUSIVE\n"; vm_crash; continue ;;
		*) summary+="$tag: FAIL (before the power cut)\n"; vm_console_faults
		   rc=1; vm_crash; continue ;;
		esac
		vm_crash || { rc=1; break 2; }
		vm_boot || { rc=1; break 2; }
		vm_ssh "$verify"
		v=$?
		if [ "$c" = nogate ]; then
			# the control: without the gate the file must come back wrong
			case $v in
			1) summary+="$tag: PASS (the control failed, as it must)\n" ;;
			3) summary+="$tag: INCONCLUSIVE\n" ;;
			*) summary+="$tag: FAIL (the control passed: the run does not see the gate)\n"
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
