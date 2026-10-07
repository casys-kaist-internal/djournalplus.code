#!/bin/bash
# Flush order (taudocs/plan.md §10): every crash state a volatile write cache
# can leave, rebuilt from a dm-log-writes log and recovered (guest/flushorder.sh).
#   usage: flushorder-test.sh [xfs|ext4|both] [cases, comma list] [fsyncs]
# cases: append falloc subappend overwrite (default: all).  CONTROL=0 skips the
# control run (records FUA without PREFLUSH: overwrite must FAIL).
# Loop devices on the guest's /dev/shm: no real disk is written.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-append,falloc,subappend,overwrite}
N=${3:-24}
[ "$FSLIST" = both ] && FSLIST="xfs ext4"
CASES=${CASES//,/ }
MOD=$TAUFS_KERNEL/drivers/md/dm-log-writes.ko
[ -f "$MOD" ] || { echo "no $MOD: make drivers/md/dm-log-writes.ko in the kernel tree" >&2; exit 2; }
export VM_MEM=${VM_MEM:-16G}

vm_boot_tested || exit 1
vm_sync_tests || exit 1
vm_scp "$MOD" "$SSH_HOST:~/tautest/" || exit 1

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		echo; echo "############ $fs $c ############"
		out=$(vm_ssh "~/tautest/guest/flushorder.sh $fs $c $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: PASS"*) summary+="$fs $c: PASS\n" ;;
		*) summary+="$fs $c: FAIL\n"; rc=1 ;;
		esac
	done
done
if [ "${CONTROL:-1}" = 1 ]; then
	for fs in $FSLIST; do
		echo; echo "############ $fs control: records FUA without PREFLUSH ############"
		out=$(vm_ssh "RECORD_FUA_ONLY=1 ~/tautest/guest/flushorder.sh $fs overwrite $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: FAIL"*) summary+="$fs control (FUA-only records, overwrite): FAIL, as it must\n" ;;
		*) summary+="$fs control: did not fail -- the test cannot see a missing flush\n"; rc=1 ;;
		esac
	done
fi
vm_kill

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
