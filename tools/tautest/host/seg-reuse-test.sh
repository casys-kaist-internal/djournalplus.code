#!/bin/bash
# Bug #25: recovery must not replay stale transactions left behind in a
#   segment the same file got back.  See guest/seg-reuse.sh for the layout.
#
#   usage: seg-reuse-test.sh [xfs] (ext4: no small-segment mkfs option yet)
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FS=${1:-xfs}
[ "$FS" = xfs ] || { echo "usage: $0 [xfs]" >&2; exit 2; }

vm_boot_tested || exit 1
vm_sync_tests || exit 1
vm_ssh "TAU_MKFS_XFS_OPTS='-l tjsegsize=4m' ~/tautest/guest/seg-reuse.sh $FS write" || exit 1
vm_crash || exit 1
vm_boot || exit 1
vm_ssh "~/tautest/guest/seg-reuse.sh $FS verify"
