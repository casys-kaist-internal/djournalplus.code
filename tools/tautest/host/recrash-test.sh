#!/bin/bash
# A crash inside the write that frees every journal segment at once -- the end
# of recovery, the unmount -- with the segment map on two blocks: every state
# that write can leave, rebuilt from a dm-log-writes log and recovered
# (guest/recrash.sh, kernel taudocs/bug.md #78).
#   usage: recrash-test.sh [xfs|ext4|both] [modes, comma list] [rewrites]
# modes: recover umount (default: both).  EXPECT_FAIL=1 is the control on a
# kernel without the fix (up to #398): every mode must FAIL there.  RC_VERBOSE=1
# prints every state with A's recovery lines.
# Loop devices on the guest's /dev/shm: no real disk is written.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
MODES=${2:-recover,umount}
N=${3:-40}
[ "$FSLIST" = both ] && FSLIST="xfs ext4"
MODES=${MODES//,/ }
MOD=$TAUFS_KERNEL/drivers/md/dm-log-writes.ko
[ -f "$MOD" ] || { echo "no $MOD: make drivers/md/dm-log-writes.ko in the kernel tree" >&2; exit 2; }
export VM_MEM=${VM_MEM:-16G}

vm_boot_tested || exit 1
vm_sync_tests || exit 1
vm_scp "$MOD" "$SSH_HOST:~/tautest/" || exit 1

rc=0
summary=""
for fs in $FSLIST; do
	for m in $MODES; do
		echo; echo "############ $fs $m ############"
		out=$(vm_ssh "RC_VERBOSE=${RC_VERBOSE:-0} ~/tautest/guest/recrash.sh $fs $m $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: PASS"*) v=PASS ;;
		*"RESULT: FAIL"*) v=FAIL ;;
		*"RESULT: INCONCLUSIVE"*) v=INCONCLUSIVE ;;
		*) v=ERROR ;;
		esac
		if [ "${EXPECT_FAIL:-0}" = 1 ]; then
			[ $v = FAIL ] && summary+="$fs $m: FAIL, as it must without the fix\n" ||
				{ summary+="$fs $m: $v -- the control did not fail\n"; rc=1; }
		else
			summary+="$fs $m: $v\n"
			[ $v = PASS ] || rc=1
		fi
	done
done
vm_kill

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
