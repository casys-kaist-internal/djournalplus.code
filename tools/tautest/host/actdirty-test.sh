#!/bin/bash
# Pages dirtied before activation, then a power cut (kernel taudocs/bug.md #68):
# the file reads its data or zeroes, never a deleted file's old blocks.  From
# #402 ext4's activation writes them home first (act_flush), as XFS since #358.
#   usage: actdirty-test.sh [xfs|ext4|both] [rounds]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
ROUNDS=${2:-2}
ARM_DEADLINE=${ARM_DEADLINE:-180}
[ "$FSLIST" = both ] && FSLIST="xfs ext4"

rc=0
summary=""
for fs in $FSLIST; do
	for round in $(seq 1 "$ROUNDS"); do
		tag="$fs round $round/$ROUNDS"
		echo; echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		vm_ssh "~/tautest/guest/actdirty-write.sh $fs" &
		writer=$!
		st=""; waited=0
		while [ "$waited" -lt "$ARM_DEADLINE" ]; do
			sleep 2; waited=$((waited + 2))
			st=$(vm_ssh 'cat ~/actdirty-status 2>/dev/null')
			[ -n "$st" ] && break
		done
		if [ "$st" != ARMED ]; then
			echo "RESULT[$tag]: SKIP (not armed: $st)"
			summary+="$tag: SKIP\n"; rc=1
			kill $writer 2>/dev/null; vm_crash; continue
		fi
		vm_crash || { rc=1; break 2; }
		kill $writer 2>/dev/null
		vm_boot_tested || { rc=1; break 2; }
		if vm_ssh "~/tautest/guest/actdirty-verify.sh $fs"; then
			echo "RESULT[$tag]: PASS"; summary+="$tag: PASS\n"
		else
			echo "RESULT[$tag]: FAIL"; summary+="$tag: FAIL\n"
			vm_console_faults; rc=1
		fi
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
