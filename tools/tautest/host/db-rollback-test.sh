#!/bin/bash
# A database over a rolled-back tau commit (bug.md #44, design.md §19): hold an
# allocating commit of a live database after its record, cut the power, and
# check that recovery rolled it back and the database still recovers whole.
#
#   usage: db-rollback-test.sh [postgres|mysql|both] [rounds] [scale]
#
# XFS only -- ext4 never rolls back.  WARNING: runs mkfs on $TAU_DEV.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

DBLIST=${1:-both}
ROUNDS=${2:-1}
SCALE=${3:-20}
case "$DBLIST" in both) DBLIST="postgres mysql" ;; postgres|mysql) ;; *) echo "bad db" >&2; exit 2 ;; esac

rc=0
summary=""

for round in $(seq 1 "$ROUNDS"); do
	for db in $DBLIST; do
		tag="$db round $round/$ROUNDS"
		echo
		echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }

		out=$(vm_ssh "~/tautest/guest/db-rollback-prepare.sh $db $SCALE" 2>&1)
		echo "$out"
		case "$out" in
		*READY-FOR-CRASH*) ;;
		*INCONCLUSIVE*)
			summary+="$tag: INCONCLUSIVE (no allocating commit)\n"
			continue ;;
		*)
			echo "RESULT[$tag]: FAIL (could not set the window up)"
			summary+="$tag: FAIL\n"
			rc=1
			continue ;;
		esac

		vm_crash || { rc=1; break 2; }
		vm_boot || { echo "RESULT[$tag]: FAIL (VM did not come back)"; summary+="$tag: FAIL\n"; rc=1; continue; }

		vm_ssh "~/tautest/guest/db-rollback-verify.sh $db $SCALE"
		case $? in
		0) echo "RESULT[$tag]: PASS"; summary+="$tag: PASS\n" ;;
		2) echo "RESULT[$tag]: INCONCLUSIVE"; summary+="$tag: INCONCLUSIVE\n" ;;
		*) echo "RESULT[$tag]: FAIL"; summary+="$tag: FAIL\n"; vm_console_faults; rc=1 ;;
		esac
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
