#!/bin/bash
# A block-aligned free -- truncate, punch, zero range -- of a tau file whose
# pending revoke tags a background commit left behind (kernel taudocs/bug.md
# #79).  The free's first transaction start reserved no descriptor block, and
# its stop charged one for the tags: BUG_ON(unused < 0) under t_list_lock, up
# to kernel #399, and journald spun on that lock after it.
#   block 0 journaled (fsync), rewritten in place (a revoke tag pending), block
#   1 written on its own (journaled); the running tx ages out and a background
#   commit takes it but not the tags; then the free of blocks 1-15.  skip:
#   a truncate once the checkpoint has drained the file, so the free finds no
#   copy of the range and stops at once (the path libra09 hit).  keep: a
#   truncate with the tx kept on the checkpoint list (tau_cp_small_tx 0), so
#   the free finds a copy and its first stop is the one in its loop
# Block 0 must read its rewrite, and the freed blocks zero or gone, before and
# after a remount, with no BUG or WARNING in the kernel log.
#   usage: freetags.sh <ext4|xfs> <truncate|punch|zero|skip|keep>
cd ~/tautest/guest || exit 1
. ./common.sh
FS=${1:-}; CASE=${2:-}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <ext4|xfs> <truncate|punch|zero|skip|keep>" ;; esac
case "$CASE" in truncate|punch|zero|skip|keep) ;; *) die "unknown case '$CASE'" ;; esac
F=$TAU_MNT/ft.dat
P=/sys/module/tau_journal/parameters

mkfs_mount "$FS"
sudo dmesg -C
age=$(cat $P/tau_max_transaction_age); small=$(cat $P/tau_cp_small_tx)
[ "$CASE" = skip ] && echo 1 | sudo tee $P/tau_max_transaction_age >/dev/null
[ "$CASE" = keep ] && echo 0 | sudo tee $P/tau_cp_small_tx >/dev/null
skip0=$(cat $P/tau_probe_free_skip 2>/dev/null || echo 0)
cat > /tmp/ft-check.py <<'EOF'
import os, struct, sys
path, case = sys.argv[1:3]
def blk(k, v):
    return struct.pack('<II', k, v) * 512
with open(path, 'rb') as f:
    d = f.read()
want = blk(0, 2) + (b'' if case in ('truncate', 'skip', 'keep') else b'\0' * 4096 * 15)
if d == want:
    print('OK')
else:
    print('BAD size %d, block 0 %s' % (len(d), struct.unpack('<II', d[:8]) if len(d) >= 8 else 'gone'))
EOF
out=$(sudo python3 - "$F" "$CASE" "$P" <<'EOF'
import ctypes, os, struct, sys, time
path, case, P = sys.argv[1:4]
def blk(k, v):
    return struct.pack('<II', k, v) * 512
def probe(n):
    try:
        return int(open('%s/tau_probe_%s' % (P, n)).read())
    except OSError:
        return -1
with open(path, 'wb') as f:		# not tau first: the blocks exist
    f.write(b''.join(blk(k, 0) for k in range(16)))
    f.flush()
    os.fsync(f.fileno())
fd = os.open(path, os.O_RDWR | 0o40000000)
os.pwrite(fd, blk(0, 1), 0)		# journaled: TauRedo
os.fdatasync(fd)
os.pwrite(fd, blk(0, 2), 0)		# in place: a revoke tag pending
os.pwrite(fd, blk(1, 2), 4096)		# a write of its own, journaled
c0 = probe('cmq_expired')
for _ in range(150):			# the running tx ages out: a background commit
    time.sleep(0.1)
    if probe('cmq_expired') > c0:
        break
else:
    print('INCONCLUSIVE no background commit')
    sys.exit()
time.sleep(4 if case == 'skip' else 1)	# skip: the checkpoint drains the file
if case in ('truncate', 'skip', 'keep'):
    os.ftruncate(fd, 4096)
else:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
    mode = 3 if case == 'punch' else 0x10	# PUNCH_HOLE | KEEP_SIZE, ZERO_RANGE
    if libc.fallocate(fd, mode, 4096, 15 * 4096):
        print('ERROR fallocate errno %d' % ctypes.get_errno())
        sys.exit()
os.fdatasync(fd)
os.close(fd)
print('FREED')
EOF
)
echo "== $FS $CASE: $out =="
echo "$age" | sudo tee $P/tau_max_transaction_age >/dev/null
echo "$small" | sudo tee $P/tau_cp_small_tx >/dev/null
skip1=$(cat $P/tau_probe_free_skip 2>/dev/null || echo 0)
bug=$(sudo dmesg | grep -cE 'kernel BUG|BUG:|WARNING:|Oops')
case "$out" in
*INCONCLUSIVE*) echo "RESULT: INCONCLUSIVE (${out#INCONCLUSIVE })"; exit 3 ;;
*FREED*) ;;
*)	echo "RESULT: FAIL (the free did not return: $bug BUG/WARNING lines)"
	sudo dmesg | grep -E -A3 'kernel BUG|BUG:|WARNING:' | head -12
	exit 1 ;;
esac
v1=$(sudo python3 /tmp/ft-check.py "$F" "$CASE")
sudo umount "$TAU_MNT" || die "umount"
sudo mount -t "$FS" -o "${TAU_MOUNT_OPTS:-tjournal}" "$TAU_DEV" "$TAU_MNT" || die "mount"
v2=$(sudo python3 /tmp/ft-check.py "$F" "$CASE")
bug=$(sudo dmesg | grep -cE 'kernel BUG|BUG:|WARNING:|Oops')
echo "== before the remount: $v1; after: $v2; BUG/WARNING lines: $bug; frees that found no copy: $((skip1 - skip0)) =="
sudo umount "$TAU_MNT"
if [ "$v1" = OK ] && [ "$v2" = OK ] && [ "$bug" = 0 ]; then
	if [ "$CASE" = skip ] && [ $((skip1 - skip0)) -lt 1 ]; then
		echo "RESULT: INCONCLUSIVE (the truncate still found a copy of the range)"; exit 3
	fi
	if [ "$CASE" = keep ] && [ $((skip1 - skip0)) -gt 0 ]; then
		echo "RESULT: INCONCLUSIVE (the truncate found no copy of the range)"; exit 3
	fi
	echo "RESULT: PASS"; exit 0
fi
echo "RESULT: FAIL"
exit 1
