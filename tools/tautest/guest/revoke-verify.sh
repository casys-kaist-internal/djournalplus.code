#!/bin/bash
# After the crash revoke-write.sh armed: mount (tau recovery runs here) and
# check that every fsync-acknowledged byte came back.
#
#   gap, gap-ctl        block 0 = 0x42 (the rewrite fsync acked), rest 0x41
#   stale, stale-ctl    all 4 MiB = 0x43
#
#   usage: revoke-verify.sh <xfs|ext4> <gap|gap-ctl|stale|stale-ctl>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
CASE=${2:-}
F=$TAU_MNT/revoke

case "$CASE" in
gap|gap-ctl)     B0=0x42; REST=0x41 ;;
stale|stale-ctl) B0=0x43; REST=0x43 ;;
*) die "usage: $0 <xfs|ext4> <gap|gap-ctl|stale|stale-ctl>" ;;
esac
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> <case>"

sudo umount "$TAU_MNT" 2>/dev/null || true
echo "== recovery mount ($FS) =="
mount_tau "$FS"
[ -f "$F" ] || die "$F missing after recovery"

# What recovery says it did: per-inode replay/revoke counts.
sudo dmesg | grep -E 'TAU: (replay done|found revoke block)' | tail -5 | sed 's/^/  /'

read -r rc report <<EOF
$(sudo python3 - "$F" "$B0" "$REST" <<'PY'
import collections, sys
path, b0, rest = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
with open(path, 'rb') as f:
    data = f.read()
def hist(buf):
    return " ".join("%#04x:%d" % kv for kv in sorted(collections.Counter(buf).items()))
if len(data) != 4 << 20:
    print("1 size %d, want %d" % (len(data), 4 << 20)); sys.exit()
blk0, tail = data[:4096], data[4096:]
bad = []
if set(blk0) != {b0}:
    bad.append("block0 want %#04x got [%s]" % (b0, hist(blk0)))
if set(tail) != {rest}:
    bad.append("rest want %#04x got [%s]" % (rest, hist(tail)))
print(("1 " + "; ".join(bad)) if bad else "0 block0=%#04x rest=%#04x" % (b0, rest))
PY
)
EOF

rc2=0
if [ "$rc" = "0" ]; then
	echo "RESULT: PASS ($report)"
else
	echo "RESULT: FAIL ($report)"
	rc2=1
fi

if [ "$(kernel_faults)" != "0" ]; then
	echo "kernel complained during recovery:"
	show_kernel_faults
	rc2=1
fi

sudo umount "$TAU_MNT" || { echo "RESULT: FAIL (umount)"; rc2=1; }
exit $rc2
