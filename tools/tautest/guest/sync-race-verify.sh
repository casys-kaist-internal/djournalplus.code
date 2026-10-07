#!/bin/bash
# Check the two files that were made durable before the crash.
#
#   usage: sync-race-verify.sh <xfs|ext4>
#
# r_fsync is the control. Read the two lines together:
#
#   fsync PASS, sync FAIL  -> a sync(2)-specific durability hole
#   both FAIL              -> not about sync(2); the aggressive commit age is
#                             exposing something in the commit/checkpoint path
#   both PASS              -> this round simply missed the window

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"
SZ=${SZ:-$((256 * MB))}

echo "== recovery mount ($FS) =="
mount_tau "$FS"

ONLY=${ONLY:-both}
rc=0

# A bare md5 mismatch does not say what went wrong. Report the size and where
# the content first diverges: a short file means the size was not logged, a
# correct prefix followed by zeros means the extents came back unwritten, and
# a correct prefix followed by stale bytes means the in-place copy was partial.
diagnose() {	# diagnose <path> <expected-byte>
	local f=$1 want=$2 sz first
	sudo test -e "$f" || { echo "      (file missing)"; return; }
	sz=$(sudo stat -c %s "$f")
	echo "      size=$sz (expected $SZ)"
	first=$(sudo cmp <(sudo cat "$f") \
		<(python3 -c "import sys;sys.stdout.buffer.write(bytes([$want])*$SZ)") 2>&1 |
		head -1)
	echo "      ${first:-identical}"
	if [ "$sz" -gt 0 ]; then
		echo "      byte histogram: $(sudo od -An -tu1 -v "$f" | tr -s " " "\n" |
			grep -v "^$" | sort | uniq -c | sort -rn | head -3 | tr "\n" " ")"
	fi
}
if [ "$ONLY" != sync ]; then
	expect_md5 "r_fsync (control, fsync)" \
		"$TAU_MNT/r_fsync" "$(md5_of_repeat 188 "$SZ")" || { rc=1; diagnose "$TAU_MNT/r_fsync" 188; }
fi
if [ "$ONLY" != fsync ]; then
	expect_md5 "r_sync  (subject, sync(2))" \
		"$TAU_MNT/r_sync"  "$(md5_of_repeat 199 "$SZ")" || { rc=1; diagnose "$TAU_MNT/r_sync" 199; }
fi

echo "== tau recovery log =="
# Grep every TAU line, not a fixed list: the epoch gate reports with
# "not durable in host journal, stopping replay", and a narrower pattern
# silently hides the one line that says why a replay was refused.
sudo dmesg | grep -E 'TAU[: ]|tau' | tail -14

faults=$(kernel_faults)
echo "== kernel faults: $faults =="
if [ "$faults" != "0" ]; then
	show_kernel_faults
	rc=1
fi

sudo umount "$TAU_MNT" && echo "unmounted cleanly" || rc=1

[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
