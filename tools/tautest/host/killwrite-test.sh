#!/bin/bash
# A write SIGKILLed part way leaves its file all old or all new (G1 against a dying
# writer), at runtime and after a remount: a kill while the kernel waits on the
# source (uffd) and kills at random moments into back-to-back 1 MiB writes (race).
#   usage: killwrite-test.sh [xfs|ext4|both] [rounds]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
ROUNDS=${2:-100}
[ "$FSLIST" = both ] && FSLIST="xfs ext4"

rc=0
summary=""
for fs in $FSLIST; do
	echo; echo "############ $fs ############"
	vm_boot_tested || { rc=1; break; }
	vm_sync_tests || { rc=1; break; }
	out=$(vm_ssh "~/tautest/guest/killwrite.sh $fs $ROUNDS" 2>&1)
	echo "$out"
	for c in uffd race; do
		r=$(echo "$out" | sed -n "s/^RESULT\[$fs $c\]: //p" | tail -1)
		[ -n "$r" ] || r="FAIL (no result)"
		summary+="$fs $c: $r\n"
		[ "${r%% *}" = PASS ] || rc=1
	done
	[ $rc -eq 0 ] || vm_console_faults
	vm_kill
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
