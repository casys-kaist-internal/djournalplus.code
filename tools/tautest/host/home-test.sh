#!/bin/bash
# New blocks go home, not to the journal (kernel plan.md §12.5).
#   basic      new data written home by its commit, an overwrite journaled;
#              both survive a power cut
#   race       a rewrite of a page its commit is writing home waits for that
#              commit, then is journaled; it survives a power cut
#   reuse      a block given back after a punch and written home: its older
#              journal copy is not replayed over it
#   nowait     control: race with the rewrite going in place -- must fail
#   norevoke   control: reuse with recovery ignoring home tags -- must fail
#   usage: home-test.sh [xfs|ext4|both] [basic|race|reuse|nowait|norevoke|all]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-all}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [basic|race|reuse|nowait|norevoke|all]" >&2; exit 2 ;;
esac
[ "$CASES" = all ] && CASES="basic race reuse nowait norevoke"

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		tag="$fs $c"
		echo
		echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		wenv=""; venv=""; gc=$c
		case $c in
		nowait) wenv="HOME_NOWAIT=1"; gc=race ;;
		norevoke) venv="HOME_NOREVOKE=1"; gc=reuse ;;
		esac
		vm_ssh "$wenv TAU_FS_SIZE=${TAU_FS_SIZE:-8g} ~/tautest/guest/home.sh $fs $gc write"
		w=$?
		if [ $w -eq 3 ]; then
			summary+="$tag: INCONCLUSIVE\n"
			vm_crash
			continue
		elif [ "$c" = nowait ]; then
			# the control fails in the write phase: the rewrite went in place
			if [ $w -eq 1 ] && [ -z "$(vm_console_faults)" ]; then
				summary+="$tag: PASS (the control failed, as it must)\n"
			else
				summary+="$tag: FAIL (the control passed: the run does not see it)\n"
				vm_console_faults
				rc=1
			fi
			vm_crash
			continue
		elif [ $w -ne 0 ]; then
			summary+="$tag: FAIL (before the power cut)\n"
			vm_console_faults
			rc=1
			vm_crash
			continue
		fi
		vm_crash || { rc=1; break 2; }
		vm_boot || { rc=1; break 2; }
		vm_ssh "$venv ~/tautest/guest/home.sh $fs $gc verify"
		v=$?
		if [ "$c" = norevoke ]; then
			case $v in
			1) summary+="$tag: PASS (the control failed, as it must)\n" ;;
			*) summary+="$tag: FAIL (the control passed: the run does not see it)\n"
			   rc=1 ;;
			esac
			continue
		fi
		case $v in
		0) summary+="$tag: PASS\n" ;;
		*) summary+="$tag: FAIL\n"; vm_console_faults; rc=1 ;;
		esac
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
