#!/bin/bash
# Mount the filesystem after a crash and check that every fsync-acked file came
# back exactly as written. Run this after rebooting into the crashed image.
#
#   usage: matrix-verify.sh <xfs|ext4>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"

echo "== recovery mount ($FS) =="
mount_tau "$FS"

D=$TAU_MNT
rc=0

echo "== expected contents =="
# fD is two regions with a hole; fE starts at offset 512. Compute those here
# rather than hardcoding digests, so changing the matrix sizes still works.
FD_MD5=$(python3 -c "
import hashlib
MB=1024*1024
d=bytes([55])*3*MB + bytes([0])*5*MB + bytes([66])*3*MB
print(hashlib.md5(d).hexdigest())")
FE_MD5=$(python3 -c "
import hashlib
print(hashlib.md5(bytes([0])*512 + bytes([77])*5000).hexdigest())")

expect_md5 fA   "$D/fA"   "$(md5_of_repeat 11 $((3 * MB)))"   || rc=1
expect_md5 fB   "$D/fB"   "$(md5_of_repeat 22 $((200 * MB)))" || rc=1
expect_md5 fC   "$D/fC"   "$(md5_of_repeat 44 $((3 * MB)))"   || rc=1
expect_md5 fD   "$D/fD"   "$FD_MD5"                           || rc=1
expect_md5 fE   "$D/fE"   "$FE_MD5"                           || rc=1
expect_md5 fG   "$D/fG"   "$(md5_of_repeat 93 $((2 * MB)))"   || rc=1
if ! expect_md5 race "$D/race" "$(md5_of_repeat 42 $((1 * MB)))"; then
	rc=1
	# which 4 KiB blocks are wrong, and with what
	sudo python3 - "$D/race" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read(); K = 4096
bad = [(i, collections.Counter(d[i*K:(i+1)*K]).most_common(2))
       for i in range(len(d) // K) if d[i*K:(i+1)*K] != bytes([0x2a]) * K]
print("  race: size %d, %d bad blocks" % (len(d), len(bad)))
for i, c in bad[:32]:
    print("    lblk %3d %s" % (i, [(hex(b), n) for b, n in c]))
PY
	echo "  race ino $(stat -c %i "$D/race")"
fi
# fF was never fsynced: any content is acceptable, it must just not blow up.

echo "== tau recovery log =="
sudo dmesg | grep -E 'TAU: (replay done|found revoke|no valid|invalid|ino [0-9]+: replaying|ino [0-9]+: tail|no more segment|found valid descriptor)' | tail -24

faults=$(kernel_faults)
echo "== kernel faults: $faults =="
if [ "$faults" != "0" ]; then
	show_kernel_faults
	rc=1
fi

sudo umount "$TAU_MNT" && echo "unmounted cleanly" || rc=1

if [ $rc -eq 0 ]; then
	echo "RESULT: PASS"
else
	echo "RESULT: FAIL"
fi
exit $rc
