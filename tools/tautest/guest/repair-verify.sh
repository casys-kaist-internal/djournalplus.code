#!/bin/bash
# Tear the in-place copy on purpose, then mount and see whether recovery puts
# the journaled generation back.
#
# This is the claim being tested, from tau_do_checkpoint()'s in-place flush:
# "the older committed copy is still in the journal and this path stamps no
# revoke, so recovery replays it over whatever tore". Instead of waiting for a
# crash to land inside that window, we write the damage ourselves.
#
#   usage: repair-verify.sh <xfs|ext4>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
EXTENT_FILE=${EXTENT_FILE:-$HOME/repair-extent.txt}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"
[ -s "$EXTENT_FILE" ] || die "no extent map at $EXTENT_FILE (setup did not land)"

sudo umount "$TAU_MNT" 2>/dev/null || true

echo "== tearing the in-place copy (0xff over the recorded blocks) =="
torn=0
while read -r first last; do
	[ -n "$first" ] && [ -n "$last" ] || continue
	count=$((last - first + 1))
	echo "  blocks $first..$last ($count)"
	sudo dd if=/dev/zero bs=4096 count="$count" 2>/dev/null |
		tr '\0' '\377' |
		sudo dd of="$TAU_DEV" bs=4096 seek="$first" count="$count" \
			conv=notrunc oflag=direct 2>/dev/null || die "dd failed"
	torn=$((torn + count))
done < "$EXTENT_FILE"
sync
echo "  torn $torn block(s)"
[ "$torn" -gt 0 ] || die "nothing was torn - the test would prove nothing"

echo "== recovery mount ($FS) =="
mount_tau "$FS"

F=$TAU_MNT/repair
[ -f "$F" ] || die "$F missing after recovery"

read -r rc report <<EOF
$(sudo python3 - "$F" <<'PY'
import collections, sys
counts = collections.Counter()
with open(sys.argv[1], 'rb') as f:
    while True:
        chunk = f.read(1 << 20)
        if not chunk:
            break
        counts.update(chunk)
detail = " ".join("%#04x:%d" % (b, n) for b, n in sorted(counts.items()))
names = {0x41: "A(journaled, repaired)", 0x42: "B(later commit)",
         0xff: "TORN-NOT-REPAIRED"}
if len(counts) == 1:
    b = next(iter(counts))
    ok = b in (0x41, 0x42)
    print(("0" if ok else "1") + " uniform " + names.get(b, "UNKNOWN") + " " + detail)
else:
    print("1 MIXED across %d values: %s" % (len(counts), detail))
PY
)
EOF

echo "  $report"

rc2=0
if [ "$rc" != "0" ]; then
	echo "RESULT: FAIL ($report)"
	rc2=1
else
	echo "RESULT: PASS"
fi

if [ "$(kernel_faults)" != "0" ]; then
	echo "kernel complained during recovery:"
	show_kernel_faults
	rc2=1
fi

sudo umount "$TAU_MNT" || { echo "RESULT: FAIL (umount)"; rc2=1; }
exit $rc2
