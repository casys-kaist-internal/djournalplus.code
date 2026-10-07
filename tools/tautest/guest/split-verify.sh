#!/bin/bash
# Mount after the crash: the last write came back whole or not at all.
#   usage: split-verify.sh <xfs|ext4> <split|split-ctl|extend|inplace>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
CASE=${2:-}
F=$TAU_MNT/split

NBLK=2
case "$CASE" in
split)     OK="40,42 43,43" ;;
split-ctl) OK="43,43" ;;
extend)    OK="41,41,00 44,44,44"; NBLK=3 ;;
inplace)   OK="41,41 43,43" ;;
*) die "usage: $0 <xfs|ext4> <split|split-ctl|extend|inplace>" ;;
esac
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> <case>"

sudo umount "$TAU_MNT" 2>/dev/null || true
echo "== recovery mount ($FS) =="
mount_tau "$FS"
[ -f "$F" ] || die "$F missing after recovery"

sudo dmesg | grep -E 'TAU: (replay done|found revoke block)' | tail -5 | sed 's/^/  /'

# each of the first NBLK blocks as the byte it is made of, or "mixed"
got=$(sudo python3 - "$F" "$NBLK" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read(4096 * int(sys.argv[2]))
out = []
for i in range(0, 4096 * int(sys.argv[2]), 4096):
    blk = data[i:i + 4096]
    out.append("%02x" % blk[0] if len(blk) == 4096 and blk.count(blk[0]) == 4096
               else "mixed(%d)" % len(blk))
print(",".join(out))
PY
)

rc=1
for want in $OK; do
	[ "$got" = "$want" ] && rc=0
done
if [ $rc -eq 0 ]; then
	echo "RESULT: PASS (blocks $got)"
else
	echo "RESULT: FAIL (blocks $got, want one of: $OK)"
fi

if [ "$(kernel_faults)" != "0" ]; then
	echo "kernel complained during recovery:"
	show_kernel_faults
	rc=1
fi

sudo umount "$TAU_MNT" || { echo "RESULT: FAIL (umount)"; rc=1; }
exit $rc
