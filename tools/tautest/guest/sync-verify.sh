#!/bin/bash
# Check which durability barriers survived the crash.
#
#   usage: sync-verify.sh <xfs|ext4>
#
# s_fsync must pass -- it is the control. s_none may hold anything. The rest
# are the question: POSIX says sync(2)/syncfs(2) make the data durable, so
# s_sync, s_syncfs and s_sync2 must come back exactly as written.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"

echo "== recovery mount ($FS) =="
mount_tau "$FS"

D=$TAU_MNT
SZ=$((3 * MB))
rc=0

expect_md5 "s_fsync  (control)" "$D/s_fsync"  "$(md5_of_repeat 111 "$SZ")" || rc=1
expect_md5 "s_sync   sync(2)"   "$D/s_sync"   "$(md5_of_repeat 122 "$SZ")" || rc=1
expect_md5 "s_syncfs syncfs(2)" "$D/s_syncfs" "$(md5_of_repeat 133 "$SZ")" || rc=1
expect_md5 "s_sync2  overwrite+sync(2)" "$D/s_sync2" "$(md5_of_repeat 177 "$SZ")" || rc=1

# sync_file_range(2) is explicitly not a durability barrier -- it writes no
# metadata and issues no cache flush -- so this one is reported, not asserted.
# It still says something: on a plain filesystem the data reaches the device
# and survives a qemu SIGKILL (the drive keeps power), so "empty" here means
# tau wrote nothing at all rather than merely skipping the flush.
if [ "$(sudo md5sum "$D/s_sfr" 2>/dev/null | cut -d' ' -f1)" = "$(md5_of_repeat 144 "$SZ")" ]; then
	echo "   NOTE s_sfr    sync_file_range: data reached the device"
else
	echo "   NOTE s_sfr    sync_file_range: data did NOT reach the device (allowed)"
fi
# s_none was never made durable; any content is fine.
echo "   NOTE s_none   (no barrier): $(sudo md5sum "$D/s_none" 2>&1 | cut -c1-32)"

echo "== tau recovery log =="
sudo dmesg | grep -E 'TAU: (replay done|found revoke|no valid|invalid)' | tail -8

faults=$(kernel_faults)
echo "== kernel faults: $faults =="
if [ "$faults" != "0" ]; then
	show_kernel_faults
	rc=1
fi

sudo umount "$TAU_MNT" && echo "unmounted cleanly" || rc=1

[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
