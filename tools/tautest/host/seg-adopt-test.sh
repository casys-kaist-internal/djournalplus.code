#!/bin/bash
# Journal segments a crashed mount left mapped past a hole come back to a full
# filesystem while the next mount runs (#37).
#   usage: seg-adopt-test.sh [xfs]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

[ "${1:-xfs}" = xfs ] || { echo "usage: $0 [xfs]" >&2; exit 2; }

vm_boot_tested || exit 1
vm_sync_tests || exit 1
vm_ssh "~/tautest/guest/seg-adopt.sh xfs arm" || { echo "arm failed"; vm_crash; exit 1; }
vm_crash || exit 1
vm_boot || exit 1
vm_ssh "~/tautest/guest/seg-adopt.sh xfs check"
rc=$?
case $rc in
0) echo "RESULT: PASS" ;;
3) echo "RESULT: INCONCLUSIVE" ;;
*) echo "RESULT: FAIL"; vm_console_faults ;;
esac
exit $rc
