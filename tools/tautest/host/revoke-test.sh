#!/bin/bash
# Does an fsync that relied on a revoke tag survive a crash?  Cases: README.
# A case whose setup did not land reports INCONCLUSIVE, never PASS.
#
#   usage: revoke-test.sh [xfs|ext4|both] [gap|gap-ctl|stale|stale-ctl|all] [rounds]
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-all}
ROUNDS=${3:-1}
ARM_DEADLINE=${ARM_DEADLINE:-90}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [case|all] [rounds]" >&2; exit 2 ;;
esac
[ "$CASES" = all ] && CASES="gap-ctl gap stale-ctl stale"

rc=0
summary=""

for fs in $FSLIST; do
	for c in $CASES; do
		for round in $(seq 1 "$ROUNDS"); do
			tag="$fs $c round $round/$ROUNDS"
			echo
			echo "############ $tag ############"

			vm_boot_tested || { rc=1; break 3; }
			vm_sync_tests || { rc=1; break 3; }

			vm_ssh "~/tautest/guest/revoke-write.sh $fs $c 600" &
			writer=$!

			# Poll for the verdict of the setup rather than waiting on
			# the guest: a wedged guest ignores SIGKILL.
			st=""
			waited=0
			while [ "$waited" -lt "$ARM_DEADLINE" ]; do
				sleep 2
				waited=$((waited + 2))
				st=$(vm_ssh 'cat ~/revoke-status 2>/dev/null')
				[ -n "$st" ] && break
			done

			case "$st" in
			ARMED) ;;
			INCONCLUSIVE*)
				echo "RESULT[$tag]: $st"
				summary+="$tag: ${st%% *}\n"
				kill $writer 2>/dev/null; vm_crash
				continue ;;
			*)
				echo "RESULT[$tag]: SKIP (not armed within ${ARM_DEADLINE}s)"
				summary+="$tag: SKIP\n"
				kill $writer 2>/dev/null; vm_crash
				continue ;;
			esac

			vm_crash || { rc=1; break 3; }
			kill $writer 2>/dev/null

			vm_boot_tested || { rc=1; break 3; }
			if vm_ssh "~/tautest/guest/revoke-verify.sh $fs $c"; then
				echo "RESULT[$tag]: PASS"
				summary+="$tag: PASS\n"
			else
				echo "RESULT[$tag]: FAIL"
				summary+="$tag: FAIL\n"
				vm_console_faults
				rc=1
			fi
		done
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
