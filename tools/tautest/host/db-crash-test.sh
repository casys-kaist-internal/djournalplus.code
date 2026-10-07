#!/bin/bash
# Crash a running database and check that it comes back consistent.
#
#   boot -> load + start the DB -> workload running -> SIGKILL qemu
#        -> boot -> mount (tau recovery) -> restart the DB (WAL/redo recovery)
#        -> check a transactional invariant
#
#   usage: db-crash-test.sh [ext4-tau|xfs-tau|both] [postgres|mysql|both] [scale]
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
DBLIST=${2:-postgres}
SCALE=${3:-20}
case "$FSLIST" in both) FSLIST="ext4-tau xfs-tau" ;; ext4-tau|xfs-tau) ;; *) echo "bad fs" >&2; exit 2 ;; esac
case "$DBLIST" in both) DBLIST="postgres mysql" ;; postgres|mysql) ;; *) echo "bad db" >&2; exit 2 ;; esac

rc=0

vm_boot_tested || exit 1
vm_sync_tests || exit 1

for fs in $FSLIST; do
	for db in $DBLIST; do
		echo
		echo "############ $db on $fs ############"

		echo "--- load and start ---"
		if ! vm_ssh "~/tautest/guest/db-crash-prepare.sh $fs $db $SCALE"; then
			echo "RESULT[$fs/$db]: FAIL (could not get the workload running)"
			rc=1
			vm_is_up || vm_boot
			continue
		fi

		echo "--- power cut (workload still running) ---"
		vm_crash || { rc=1; continue; }

		echo "--- rebooting ---"
		if ! vm_boot; then
			echo "RESULT[$fs/$db]: FAIL (VM did not come back)"
			vm_console_faults
			rc=1
			continue
		fi

		echo "--- recovery ---"
		if vm_ssh "~/tautest/guest/db-crash-verify.sh $fs $db $SCALE"; then
			echo "RESULT[$fs/$db]: PASS"
		else
			echo "RESULT[$fs/$db]: FAIL"
			vm_console_faults
			rc=1
		fi
	done
done

echo
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
