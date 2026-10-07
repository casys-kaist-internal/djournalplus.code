#!/bin/bash
# Mount after the power cut and check the target file.
#
# Generation B was fsync-acked; C was not. So B (rolled back) and C (a later
# transaction that happened to commit) are both legal outcomes. What is NOT
# legal is a mix: that means an fsync-acked generation was torn, which is
# exactly the guarantee tau exists to provide.
#
# A is also a failure: B's revoke says the in-place copy superseded the
# journaled A, so recovery must never put A back.
#
#   usage: cp-race-verify.sh <xfs|ext4>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"

echo "== recovery mount ($FS) =="
mount_tau "$FS"

F=$TAU_MNT/cprace
[ -f "$F" ] || die "$F is missing after recovery"

# Byte histogram: one entry means uniform, more than one means torn.
read -r rc report <<EOF
$(sudo python3 - "$F" <<'PY'
import collections, sys
BS = 4096
counts = collections.Counter()
# Per-block value, so a torn result says WHERE it tore: contiguous runs point at
# a writeback unit, scattered singles at something else.
runs = []      # (value, first_block, nblocks); "?" if the block is not uniform
with open(sys.argv[1], 'rb') as f:
    idx = 0
    while True:
        blk = f.read(BS)
        if not blk:
            break
        counts.update(blk)
        v = blk[0] if len(set(blk)) == 1 else -1
        if runs and runs[-1][0] == v:
            runs[-1][2] += 1
        else:
            runs.append([v, idx, 1])
        idx += 1
detail = " ".join("%#04x:%d" % (b, n) for b, n in sorted(counts.items()))
names = {0x41: "A(stale-must-not-happen)", 0x42: "B(acked)", 0x43: "C(later-commit)"}
if len(counts) == 1:
    b = next(iter(counts))
    # Only B (last acked) and C (a later commit) are legal. A means a committed
    # revoke was ignored; anything else - zeroes, garbage - is data loss. An
    # earlier version passed everything except A, so an all-zero file scored a
    # PASS.
    print(("0" if b in (0x42, 0x43) else "1") + " uniform " +
          names.get(b, "UNEXPECTED %#04x" % b) + " " + detail)
else:
    layout = " ".join("%s@%d+%d" % ("mixed" if v < 0 else names.get(v, hex(v))[0], s, n)
                      for v, s, n in runs[:12])
    if len(runs) > 12:
        layout += " ...(%d runs)" % len(runs)
    print("1 TORN %s | blocks: %s" % (detail, layout))
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
