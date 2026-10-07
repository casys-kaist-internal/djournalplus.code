#!/bin/bash
# truncate / punch hole racing writes and fsync (locking.md F1, S3).
#   usage: trunc-race-test.sh [ext4|xfs|both] [seconds]
# WARNING: runs mkfs on $TAU_DEV inside the guest.
set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh
WHICH=${1:-both}; SECS=${2:-60}
case $WHICH in both) FSES="ext4 xfs";; *) FSES=$WHICH;; esac
vm_boot_tested || exit 1
vm_sync_tests || exit 1
rc=0
for fs in $FSES; do
	echo "############ $fs ############"
	vm_ssh "~/tautest/guest/trunc-race.sh $fs $SECS" || rc=1
done
[ $rc = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $rc
