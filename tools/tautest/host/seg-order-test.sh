#!/bin/bash
# Bug #17: recovery must survive a transaction that drained before an older one.
#   T1 stays on the checkpoint list; T2 spans several (4 MiB) segments and is
#   emptied by a re-journal handoff into T3 (fsync'd); power cut.  Recovery must
#   replay through T3.  Before the fix it stopped at T1 ("no more segment").
#
#   usage: seg-order-test.sh [xfs] (ext4: no small-segment mkfs option yet)
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FS=${1:-xfs}
[ "$FS" = xfs ] || { echo "usage: $0 [xfs]" >&2; exit 2; }

vm_boot_tested || exit 1
vm_sync_tests || exit 1
vm_ssh "TAU_MKFS_XFS_OPTS='-l tjsegsize=4m' ~/tautest/guest/seg-order.sh $FS write" || exit 1
vm_crash || exit 1
vm_boot || exit 1
vm_ssh "~/tautest/guest/seg-order.sh $FS verify"
