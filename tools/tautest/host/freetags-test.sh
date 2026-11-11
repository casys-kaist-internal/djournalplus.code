#!/bin/bash
# A block-aligned free of a tau file whose pending revoke tags a background
# commit left behind (guest/freetags.sh, kernel taudocs/bug.md #79).
#   usage: freetags-test.sh [xfs|ext4|both] [truncate,punch,zero,skip,keep]
# EXPECT_FAIL=1 is the control on a kernel without the fix (up to #399):
# every case must FAIL there (the BUG, or a guest that stops answering) --
# but ext4 punch, whose writeback of the range commits the pending tags
# before the free, is left out of it.
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-truncate,punch,zero,skip,keep}
DEADLINE=${FT_DEADLINE:-180}
[ "$FSLIST" = both ] && FSLIST="xfs ext4"
CASES=${CASES//,/ }

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		if [ "${EXPECT_FAIL:-0}" = 1 ] && [ "$fs $c" = "ext4 punch" ]; then
			summary+="ext4 punch: left out of the control (its writeback commits the tags first)\n"
			continue
		fi
		echo; echo "############ $fs $c ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		vm_ssh "rm -f ~/ft.done ~/ft.log; (nohup ~/tautest/guest/freetags.sh $fs $c > ~/ft.log 2>&1; echo \$? > ~/ft.done) > /dev/null 2>&1 &"
		# a guest that hit the BUG may not answer: poll, never wait on it
		end=$((SECONDS + DEADLINE))
		while [ "$SECONDS" -lt "$end" ]; do
			sleep 5
			vm_ssh_timeout 10 'test -e ~/ft.done' 2>/dev/null && break
		done
		out=$(vm_ssh_timeout 20 'cat ~/ft.log' 2>/dev/null)
		echo "$out"
		case "$out" in
		*"RESULT: PASS"*) v=PASS ;;
		*"RESULT: INCONCLUSIVE"*) v=INCONCLUSIVE ;;
		*"RESULT: FAIL"*) v=FAIL ;;
		*)	v=FAIL
			echo "(no verdict in ${DEADLINE}s; the console's last BUG lines:)"
			grep -aE -A4 'kernel BUG|BUG:|soft lockup' "$VM_LOG" | tail -12 ;;
		esac
		vm_kill
		if [ "${EXPECT_FAIL:-0}" = 1 ]; then
			[ $v = FAIL ] && summary+="$fs $c: FAIL, as it must without the fix\n" ||
				{ summary+="$fs $c: $v -- the control did not fail\n"; rc=1; }
		else
			summary+="$fs $c: $v\n"
			[ $v = PASS ] || rc=1
		fi
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
