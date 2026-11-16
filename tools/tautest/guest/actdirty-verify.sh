#!/bin/bash
# After the cut: every block of A reads 0x55 or zero, never X's 0xAA (#68); A with its
# size must be there (the directory fsync and the host commit made them durable).
#   usage: actdirty-verify.sh <xfs|ext4>
cd "$(dirname "$0")" || exit 1
. ./common.sh
FS=${1:-}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <xfs|ext4>" ;; esac
mount_tau "$FS"
# exit 3: A or its size not durable, so no block was checked
[ -f "$TAU_MNT/a" ] || { echo "  A missing after recovery: nothing checked"; exit 3; }
sudo python3 - "$TAU_MNT/a" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
n = {'55': 0, 'zero': 0, 'aa': 0, 'other': 0}
for i in range(0, len(d), 4096):
    b = d[i:i + 4096]
    if b == b'\x55' * len(b): n['55'] += 1
    elif b == b'\0' * len(b): n['zero'] += 1
    elif b'\xaa' in b: n['aa'] += 1
    else: n['other'] += 1
print('  size', len(d), 'blocks', n)
sys.exit(1 if n['aa'] or n['other'] else 3 if not d else 0)
PY
