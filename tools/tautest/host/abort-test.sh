#!/bin/bash
# Inject a fault at each abort-path site and check the journal stops cleanly
# and umount + mount recovers every fsync (#22, #7).
#   usage: abort-test.sh [xfs|ext4|both] [sites, default "1 2 3 4 5 6"]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
SITES=${2:-1 2 3 4 5 6}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [sites]" >&2; exit 2 ;;
esac

rc=0
summary=""
fresh=1
for fs in $FSLIST; do
	for s in $SITES; do
		tag="$fs site $s"
		echo
		echo "############ $tag ############"
		if [ $fresh -eq 1 ]; then
			vm_boot_tested || { rc=1; break 2; }
			vm_sync_tests || { rc=1; break 2; }
			fresh=0
		fi
		vm_ssh "~/tautest/guest/abort.sh $fs $s"
		case $? in
		0) summary+="$tag: PASS\n" ;;
		3) summary+="$tag: INCONCLUSIVE\n" ;;
		*) summary+="$tag: FAIL\n"; vm_console_faults; rc=1; fresh=1 ;;
		esac
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
