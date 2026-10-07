#!/bin/bash
# Mount after the cut: the commit came back whole or not at all, no salt.
#   usage: epoch-verify.sh <xfs|ext4> <case>

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
CASE=${2:-}
F=$TAU_MNT/epoch

case "$CASE" in
convert) BLKS="0 1";  OK="43,43 00,00" ;;
split)   BLKS="0 16"; OK="41,42 -,- 00,00" ;;
gate|publish) BLKS="0 1 2 3"; OK="30,30,-,- 30,44,44,44" ;;
partial) BLKS="3 4 8"; OK="30,00,00 45,45,46" ;;
append|append-umount|append-torn|isize|undo-bg|undo-wb|undo-sparse) BLKS="" ;;
*) die "usage: $0 <xfs|ext4> <case>" ;;
esac
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> <case>"

sudo umount "$TAU_MNT" 2>/dev/null || true
# NOROLLBACK=1: recovery skips its rollback check (TAU_FAULT_NOROLLBACK) --
# what the cases look like without it
[ -n "${NOROLLBACK:-}" ] &&
	echo 8 | sudo tee /sys/module/tau_journal/parameters/tau_inject_fault >/dev/null
echo "== recovery mount ($FS)${NOROLLBACK:+, rollback off} =="
mount_tau "$FS"
[ -f "$F" ] || die "$F missing after recovery"
sudo dmesg | grep -E 'TAU: (replay done|ino .*replaying|.*not durable|.*rolled back)' | tail -5 | sed 's/^/  /'
echo "  size $(sudo stat -c %s "$F")"

# size-only cases: the whole content against the outcomes allowed
if [ -z "$BLKS" ]; then
	got=$(sudo python3 - "$F" "$CASE" <<'PY'
import itertools, sys
data = open(sys.argv[1], 'rb').read()
a4, b1, b1e = b'A' * 4096, b'b' * 10 + b'B' * 90, b'b' * 4 + b'e' * 10 + b'B' * 86
past = b'\0' * (3 * 4096 - 4196) + b'S' * 4096
ok = {
    'undo-bg': [b'D' * 4096 + b1, b'D' * 4096 + b1 + b'C' * 100],
    'undo-wb': [a4 + b1, a4 + b1 + b'C' * 100],
    'undo-sparse': [a4 + t + p for t in (b1, b1e) for p in (b'', past)],
    'append': [b'A' * 100 + b'B' * 100],
    'append-umount': [b'A' * 100 + b'B' * 100],
    'append-torn': [b'A' * 100, b'A' * 80 + b'C' * 50],
    'isize': [b'A' * 100 + b'B' * 100, b'A' * 100 + b'B' * 100 + b'C' * 100],
}[sys.argv[2]]
runs = [(c, len(list(g))) for c, g in itertools.groupby(data)]
desc = "size %d: %s" % (len(data), " ".join(
    "%s*%d" % (chr(c) if 32 < c < 127 else "0x%02x" % c, n) for c, n in runs))
print(("OK " if data in ok else "BAD ") + desc)
PY
)
	case "$got" in
	OK*)  echo "RESULT: PASS (${got#OK })"; rc=0 ;;
	*)    echo "RESULT: FAIL (${got#BAD })"; rc=1 ;;
	esac
	if [ "$(kernel_faults)" != "0" ]; then
		show_kernel_faults
		rc=1
	fi
	sudo umount "$TAU_MNT" || rc=1
	exit $rc
fi

# each block in $BLKS as its byte, "-" past EOF, or mixed; and the salt count
got=$(sudo python3 - "$F" $BLKS <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
out = []
for b in map(int, sys.argv[2:]):
    blk = data[b * 4096:(b + 1) * 4096]
    if not blk:
        out.append("-")
    elif len(blk) == 4096 and blk.count(blk[0]) == 4096:
        out.append("%02x" % blk[0])
    else:
        out.append("mixed(%d)" % len(blk))
print(",".join(out), data.count(0xEE))
PY
)
blocks=${got% *}
salt=${got#* }

rc=1
for want in $OK; do
	[ "$blocks" = "$want" ] && rc=0
done
[ "$salt" = 0 ] || rc=1
if [ $rc -eq 0 ]; then
	echo "RESULT: PASS (blocks $blocks, no salt)"
else
	echo "RESULT: FAIL (blocks $blocks, $salt salt bytes; want one of: $OK)"
	sudo filefrag -v "$F" | sed 's/^/  /'
fi

if [ "$(kernel_faults)" != "0" ]; then
	echo "kernel complained during recovery:"
	show_kernel_faults
	rc=1
fi

sudo umount "$TAU_MNT" || { echo "RESULT: FAIL (umount)"; rc=1; }
exit $rc
