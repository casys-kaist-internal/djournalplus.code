#!/bin/bash
# XFS tau with THP on (taudocs/plan.md §6.9): a tau block lives on an order-0
# folio, everything else -- other files, a tau file's read-only ranges -- may
# use large ones.  README.
#   write half (guest/thp-write.sh): random writes, truncates and punches with
#   large folios on a plain XFS mount and on a file of a tjournal mount that is
#   not tau; a file activated with large folios cached; files activated under
#   an mmap reader -- each tau write that lands on a large folio splits (or
#   drops) it.  Then a power cut, and (guest/thp-verify.sh) every file against
#   what was fsynced.
#   usage: thp-test.sh
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FAULTS='kernel BUG|invalid opcode|soft lockup|WARNING: CPU'
# console faults since line $1 of the console log
faults_since() { tail -n +$(($1 + 1)) "$VM_LOG" | grep -aE "$FAULTS"; }

vm_boot_tested || exit 1
vm_sync_tests || exit 1
start=$(wc -l < "$VM_LOG")
T=$(mktemp)

vm_ssh_timeout 3600 "bash ~/tautest/guest/thp-write.sh" | tee "$T"
w=${PIPESTATUS[0]}
met=$(sed -n 's/.*THP_MET=\([0-9]*\).*/\1/p' "$T" | tail -1)
weak=$(sed -n 's/.*THP_WEAK=\([0-9]*\).*/\1/p' "$T" | tail -1)
ready=$(grep -c READY-FOR-CRASH "$T")
rm -f "$T"
v=1
if [ "$w" -eq 0 ] && [ "$ready" -gt 0 ]; then
	echo "--- power cut ---"
	vm_crash
	echo "--- rebooting ---"
	if vm_boot; then
		vm_ssh_timeout 1800 "bash ~/tautest/guest/thp-verify.sh"
		v=$?
	else
		echo "VM did not come back"
	fi
else
	echo "the write half failed (rc=$w)"
fi

n=$(faults_since "$start" | wc -l)
echo "console faults in this test's boots: $n"
[ "$n" -eq 0 ] || faults_since "$start" | head -5

if [ "$w" -ne 0 ] || [ "$v" -ne 0 ] || [ "$n" -ne 0 ]; then
	echo "FAILURES (write rc=$w, verify rc=$v, console faults $n; console log: $VM_LOG)"
	exit 1
fi
# no large folio seen, or none met by a tau write: THP was not exercised
if [ "${weak:-1}" -ne 0 ] || [ "${met:-0}" -eq 0 ]; then
	echo "RESULT: INCONCLUSIVE -- a case saw no large folio: ${weak:-?}, split or dropped by a tau write: ${met:-0}"
	exit 2
fi
echo "ALL PASS"
exit 0
