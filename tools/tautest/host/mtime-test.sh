#!/bin/bash
# A tau file's timestamps are lazytime and fsync is datasync-level: mtime moves
# on a write, survives a clean umount and a sync + power cut, and 200 fsyncs
# cost no host journal commit each (#24).
#   usage: mtime-test.sh [xfs|ext4|both] [live|crash|all]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-all}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [live|crash|all]" >&2; exit 2 ;;
esac
[ "$CASES" = all ] && CASES="live crash"

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		tag="$fs $c"
		echo
		echo "############ $tag ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		if [ "$c" = live ]; then
			vm_ssh "~/tautest/guest/mtime.sh $fs live"
			case $? in
			0) summary+="$tag: PASS\n" ;;
			*) summary+="$tag: FAIL\n"; vm_console_faults; rc=1 ;;
			esac
			continue
		fi
		if ! vm_ssh "~/tautest/guest/mtime.sh $fs write"; then
			summary+="$tag: FAIL (before the power cut)\n"
			vm_console_faults
			rc=1
			vm_crash
			continue
		fi
		vm_crash || { rc=1; break 2; }
		vm_boot || { rc=1; break 2; }
		vm_ssh "~/tautest/guest/mtime.sh $fs verify"
		case $? in
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
