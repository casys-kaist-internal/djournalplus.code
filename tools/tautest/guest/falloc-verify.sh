#!/bin/bash
# Verify the fallocate/unwritten matrix after a crash + recovery.
#
#   usage: falloc-verify.sh <xfs|ext4>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"

echo "== recovery mount ($FS) =="
mount_tau "$FS"

D=$TAU_MNT
rc=0

# md5 of a concatenation of (byte, count) pairs.
md5_of_runs() {
	python3 -c "
import hashlib, sys
h = hashlib.md5()
a = sys.argv[1:]
for i in range(0, len(a), 2):
    h.update(bytes([int(a[i])]) * int(a[i+1]))
print(h.hexdigest())" "$@"
}

echo "== expected contents =="
expect_md5 pA "$D/pA" "$(md5_of_repeat 101 $((8 * MB)))"                    || rc=1
expect_md5 pB "$D/pB" "$(md5_of_runs 102 $((3 * MB)) 0 $((5 * MB)))"        || rc=1
expect_md5 pC "$D/pC" "$(md5_of_runs 0 512 103 5000 0 $((8 * MB - 5512)))"  || rc=1
expect_md5 pD "$D/pD" "$(md5_of_runs 105 $((2 * MB)) 104 $((6 * MB)))"      || rc=1
expect_md5 pE "$D/pE" "$(md5_of_runs 106 $((2 * MB)) 0 $((6 * MB)) \
			 107 $((2 * MB)) 0 $((2 * MB)))"                    || rc=1
expect_md5 pF "$D/pF" "$(md5_of_runs 108 $((150 * MB)) 0 $((150 * MB)))"    || rc=1

# pG was never fsynced, so its data may or may not be there -- but no version of
# it may contain the salt.  This is the stale-data check: a byte of 0xEE means an
# unwritten extent was published over blocks tau had not written.
echo "== stale-data check (0xEE must not appear) =="
for f in pA pB pC pD pE pF pG; do
	n=$(sudo python3 -c "
import sys
n = 0
with open(sys.argv[1], 'rb') as fh:
    while True:
        b = fh.read(1 << 20)
        if not b:
            break
        n += b.count(0xEE)
print(n)" "$D/$f")
	if [ "$n" = "0" ]; then
		printf '  PASS %-4s no salt bytes\n' "$f"
	else
		printf '  FAIL %-4s %s salt bytes leaked\n' "$f" "$n"
		rc=1
	fi
done

echo "== tau recovery log =="
sudo dmesg | grep -E 'TAU: (replay done|found revoke|no valid|invalid|not durable)' | tail -10

faults=$(kernel_faults)
echo "== kernel faults: $faults =="
if [ "$faults" != "0" ]; then
	show_kernel_faults
	rc=1
fi

# Does the stale-data check above have any power?  It only means something if
# the blocks under a still-unwritten extent actually hold the salt.  Find one
# such extent, then read those blocks straight off the device once the
# filesystem is out of the way: salt there + zeroes in the file is the property
# under test, and it proves a leak would have been visible.
echo "== test power (are unwritten blocks really salted?) =="
# "  1:   768..  2047:  13113..  14392:  1280:   unwritten" -> 13113.  Field 3
# is a "start..end" range; keep the first half only, or the two numbers get
# concatenated into a nonsense block number.  (split(s, a, "..") does not work:
# awk reads a multi-char separator as a regex, and ".." matches anything.)
PBLK=$(sudo filefrag -e -b4096 "$D/pB" 2>/dev/null |
	awk -F: '/unwritten/ { p = $3; sub(/\.\..*/, "", p);
			       gsub(/[^0-9]/, "", p); print p; exit }')

sudo umount "$TAU_MNT" && echo "unmounted cleanly" || rc=1

if [ -n "${PBLK:-}" ]; then
	salted=$(sudo dd if="$TAU_DEV" bs=4096 skip="$PBLK" count=256 2>/dev/null |
		python3 -c "import sys; print(sys.stdin.buffer.read().count(0xEE))")
	if [ "${salted:-0}" -gt 0 ]; then
		echo "  CONFIRMED: unwritten extent at pblk $PBLK holds $salted salt bytes,"
		echo "             and the file read back as zeroes there -- a leak was possible."
	else
		echo "  INCONCLUSIVE: pblk $PBLK carries no salt (allocator did not reuse the"
		echo "                freed blocks); the stale-data check above proved nothing."
	fi
else
	echo "  INCONCLUSIVE: no unwritten extent found in pB (filefrag missing?)"
fi

if [ $rc -eq 0 ]; then
	echo "RESULT: PASS"
else
	echo "RESULT: FAIL"
fi
exit $rc
