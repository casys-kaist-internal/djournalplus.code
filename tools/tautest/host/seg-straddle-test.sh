#!/bin/bash
# Bug #27: after the newest tx straddled two segments and was checkpointed,
#   recovery must not replay the older txs of the same file that the second
#   segment still holds.  See guest/seg-straddle.sh for the layout.
#
#   usage: seg-straddle-test.sh [xfs|ext4]
#
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FS=${1:-xfs}
case "$FS" in
xfs)	MKOPTS="TAU_MKFS_XFS_OPTS='-l tjsegsize=4m'" ;;
ext4)	MKOPTS="TAU_MKE2FS_OPTS='-E tau_segsize=4m'" ;;
*)	echo "usage: $0 [xfs|ext4]" >&2; exit 2 ;;
esac

vm_boot_tested || exit 1
vm_sync_tests || exit 1
vm_ssh "$MKOPTS ~/tautest/guest/seg-straddle.sh $FS write" || exit 1
vm_crash || exit 1
vm_boot || exit 1
vm_ssh "~/tautest/guest/seg-straddle.sh $FS verify"
