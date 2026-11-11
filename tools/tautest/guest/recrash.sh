#!/bin/bash
# A crash inside the one write that frees every journal segment at once must
# leave a disk the next mount recovers right (kernel taudocs/bug.md #78).  Two
# places write it: the end of recovery, which clears the segment map, and the
# unmount, whose snapshot writes the map with every segment free.  With more
# than one map block that is several block writes in flight together, so any
# subset of them can be on the disk; up to kernel #398 the mount's generation
# stayed current through it, so the crashed mount's records still counted.
#
# Geometry: 512 segments of 2 MiB (two map blocks), the segment map log cut to
# 8 blocks (tau_maplog_len), nothing checkpointed during the run.  255 files
# take entries 0-254 with one tau rewrite each; file A then rewrites the two
# halves of its first 32 blocks, each in a write of its own (the second from
# its second rewrite on), and one block of its own, fdatasync each.  A half
# goes to the journal and in place by turns, so every tx journals one half and
# revokes the other's older copies, and the block of its own keeps each tx in
# the journal.  Its txs run from
# entry 255 (map block 0) into a segment on map block 1; then other files
# take new segments until the map blocks are written, which leaves A's segments
# on the map blocks and not on the log past their base.
#   recover  the crash state after the last fdatasync is mounted through a
#            second dm-log-writes; its recovery's writes are rebuilt over the
#            crash state at every flush, FUA and mark, and with every subset of
#            each group of map block writes, and each state is mounted again
#   umount   the unmount is logged; its states are rebuilt the same way, from
#            the mark before it to the one after
# In every state A must read its last fdatasync'd version, and the other files
# theirs.  Up to kernel #398 both modes FAIL in the state with map block 1
# written and map block 0 not: A's newest segment is gone from the map, its
# older one is still there, and its older txs replay over the newer data.
#
#   usage: recrash.sh <ext4|xfs> <recover|umount> [rewrites of A]
#
# Needs ~/tautest/dm-log-writes.ko built for the running kernel and the
# segment map log (tau_maplog_len).  Loop devices on /dev/shm only.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}; MODE=${2:-}; N=${3:-40}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <ext4|xfs> <recover|umount> [rewrites]" ;; esac
case "$MODE" in recover|umount) ;; *) die "unknown mode '$MODE'" ;; esac
[ "$N" -ge 36 ] || die "A needs at least 36 rewrites to reach its second segment"
W=/dev/shm/recrash
P=/sys/module/tau_journal/parameters
F=$TAU_MNT/rc.dat

cleanup() {
	sudo umount "$TAU_MNT" 2>/dev/null
	sudo dmsetup remove rc 2>/dev/null
	sudo dmsetup remove rc2 2>/dev/null
	for f in data log crash rec log2 work scratch; do
		for l in $(losetup -j "$W/$f.img" 2>/dev/null | cut -d: -f1); do
			sudo losetup -d "$l"
		done
	done
	sudo rm -rf "$W"
}
params_set() {
	mllen=$(cat $P/tau_maplog_len); small_tx=$(cat $P/tau_cp_small_tx)
	tx_age=$(cat $P/tau_max_transaction_age)
	echo 8 | sudo tee $P/tau_maplog_len >/dev/null
	echo 0 | sudo tee $P/tau_cp_small_tx >/dev/null
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
}
params_restore() {
	echo "$mllen" | sudo tee $P/tau_maplog_len >/dev/null
	echo "$small_tx" | sudo tee $P/tau_cp_small_tx >/dev/null
	echo "$tx_age" | sudo tee $P/tau_max_transaction_age >/dev/null
}
[ -e $P/tau_maplog_len ] || die "no segment map log in this kernel"
cleanup
sudo mkdir -p "$W"
sudo truncate -s 8G "$W/data.img" "$W/log.img"
DATA=$(sudo losetup -f --show "$W/data.img") || die "losetup data"
LOG=$(sudo losetup -f --show "$W/log.img") || die "losetup log"
lsmod | grep -q '^dm_log_writes' || sudo insmod ~/tautest/dm-log-writes.ko ||
	die "cannot load ~/tautest/dm-log-writes.ko"
echo "0 $(sudo blockdev --getsz "$DATA") log-writes $DATA $LOG" | sudo dmsetup create rc ||
	die "dmsetup create"

params_set
# no discards and no background inode-table zeroing in the log; two map blocks
export TAU_MKE2FS_OPTS="-E nodiscard,lazy_itable_init=0,lazy_journal_init=0,tau_segsize=2m"
export TAU_MKFS_XFS_OPTS="-K -l tjsegsize=2m,tjmaxsize=1G"
export TAU_MOUNT_OPTS=tjournal,tjournal_size=1
TAU_DEV=/dev/mapper/rc mkfs_mount "$FS"

# the tau superblock: jbd2 magic and a 2 MiB segment size; its byte offset
cat > /tmp/rc-findsb.py <<'EOF'
import struct, sys
f = open(sys.argv[1], 'rb')
pos = 0
while True:
    buf = f.read(64 << 20)
    if not buf:
        sys.exit(1)
    for off in range(0, len(buf), 4096):
        if buf[off:off + 4] == b'\xc0\x3b\x39\x98' and \
           struct.unpack('>I', buf[off + 0x5c:off + 0x60])[0] == 2 << 20:
            print(pos + off)
            sys.exit(0)
    pos += len(buf)
EOF
SB=$(sudo python3 /tmp/rc-findsb.py /dev/mapper/rc) || { params_restore; cleanup; die "no tau superblock"; }

cat > /tmp/rc-work.py <<'EOF'
import mmap, os, struct, subprocess, sys, time
path, n, dev, sboff = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
TAU = 0o40000000
def mark(name):
    subprocess.run(['dmsetup', 'message', 'rc', '0', 'mark', name], check=True)
def blk(k, tag):
    return struct.pack('<II', k, tag) * 512
buf = mmap.mmap(-1, 4096)
def base():		# s_maplog_base on the disk
    fd = os.open(dev, os.O_RDONLY | os.O_DIRECT)
    os.preadv(fd, [buf], sboff)
    os.close(fd)
    return struct.unpack('>Q', buf[0x68:0x70])[0]
fills = ['%s.f%03d' % (path, i) for i in range(255)]
extra = ['%s.x%03d' % (path, i) for i in range(64)]
for name in fills + extra:	# not tau first: no record waits on a host epoch
    with open(name, 'wb') as f:
        f.write(blk(0, 0xE1))
        f.flush()
        os.fsync(f.fileno())
with open(path, 'wb') as f:
    f.write(b''.join(blk(k, 0xE0) for k in range(32 + n)))
    f.flush()
    os.fsync(f.fileno())
os.sync()
mark('ready')
def rewrite(name, tag):
    g = os.open(name, os.O_RDWR | TAU)
    os.pwrite(g, blk(0, tag), 0)
    os.fdatasync(g)
    os.close(g)
for name in fills:		# entries 0-254
    rewrite(name, 0xA2)
fd = os.open(path, os.O_RDWR | TAU)
for v in range(1, n + 1):	# about 20 blocks a tx: 25 fill entry 255, the rest go on
    os.pwrite(fd, b''.join(blk(k, v) for k in range(16)), 0)
    if v > 1:		# a write of its own: one atoz, its own turn
        os.pwrite(fd, b''.join(blk(k, v) for k in range(16, 32)), 16 * 4096)
    os.pwrite(fd, blk(31 + v, v), (31 + v) * 4096)
    os.fdatasync(fd)
    mark('fsync-%d' % v)
b0, used = base(), 0
for name in extra:		# new segments until the map blocks are written
    rewrite(name, 0xA3)
    used += 1
    for _ in range(30):
        if base() != b0:
            break
        time.sleep(0.1)
    else:
        continue
    break
mark('crash')
print('%d %d %d %d' % (os.stat(path).st_ino, used, b0, base()))
os.close(fd)
EOF
out=$(sudo python3 /tmp/rc-work.py "$F" "$N" /dev/mapper/rc "$SB") || { params_restore; cleanup; die "workload failed"; }
read -r AINO EXTRAS B0 B1 <<< "$out"
if [ "$MODE" = umount ]; then
	sudo dmsetup message rc 0 mark pre-umount
	sudo umount "$TAU_MNT" || die "umount"
	sudo dmsetup message rc 0 mark umounted
else
	sudo umount "$TAU_MNT"
fi
params_restore
sudo dmsetup remove rc || die "dmsetup remove"
echo "== $FS $MODE: A (ino $AINO) rewritten $N times, $EXTRAS other files took a segment after it, base $B0 -> $B1 =="

# rebuild: <log> <base image or -> <out image> <stop mark>
cat > /tmp/rc-rebuild.py <<'EOF'
import os, struct, subprocess, sys
log, base, out, stop = sys.argv[1:5]
if base == '-':
    subprocess.run(['truncate', '-s', '8G', out], check=True)
else:
    subprocess.run(['cp', '--sparse=always', base, out], check=True)
lf = open(log, 'rb')
magic, version, nr, secsz = struct.unpack('<QQQI', lf.read(28))
assert magic == 0x6a736677736872, "not a log-writes log"
of = os.open(out, os.O_RDWR)
pos = secsz
for i in range(nr):
    lf.seek(pos)
    hdr = lf.read(secsz)
    sector, nsec, flags, dlen = struct.unpack('<QQQQ', hdr[:32])
    pos += secsz
    if flags & 8:
        if hdr[32:32 + dlen].decode() == stop:
            sys.exit(0)
    elif flags & 4:
        if nsec:
            subprocess.run(['fallocate', '-p', '-o', str(sector * secsz),
                            '-l', str(nsec * secsz), out], check=True)
    elif nsec:
        lf.seek(pos)
        os.pwrite(of, lf.read(nsec * secsz), sector * secsz)
        pos += nsec * secsz
sys.exit(1)
EOF
sudo python3 /tmp/rc-rebuild.py "$LOG" - "$W/crash.img" crash || die "no crash mark in the log"

# the layout the test needs, on the crash state: A's segments on both map
# blocks, and none of its entries on the log past the base
layout=$(sudo python3 - "$W/crash.img" "$SB" "$AINO" <<'EOF'
import struct, sys
img, sb, ino = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
f = open(img, 'rb')
f.seek(sb)
s = f.read(4096)
lpba, lbase, llen = struct.unpack('>QQI', s[0x60:0x74])
f.seek(sb + 4096)
m = f.read(8192)
own = [struct.unpack('>QQ', m[e * 16:e * 16 + 16])[1] for e in range(512)]
mine = [e for e in range(512) if own[e] == ino]
past, touch = 0, set()
for i in range(llen if lpba else 0):
    f.seek((lpba + i) * 4096)
    b = f.read(4096)
    magic, kind_, seq = struct.unpack('>IIQ', b[:16])
    if magic == 0xc03b3998 and kind_ == 6 and seq > lbase:
        past += 1
        for k in range(struct.unpack('>H', b[22:24])[0]):
            idx = struct.unpack('>I', b[32 + k * 24:36 + k * 24])[0]
            if idx in mine:
                touch.add(idx)
blocks = sorted({e // 256 for e in mine})
print('A on map entries %s (map blocks %s); log past base %d: %d blocks, on those entries: %s' %
      (mine or 'none', blocks, lbase, past, sorted(touch) or 'none'))
EOF
)
echo "== layout: $layout =="
case "$layout" in
*"(map blocks [0, 1])"*"on those entries: none"*) ;;
*)	echo "RESULT: INCONCLUSIVE (A's segments are not on both map blocks, or the log past the base names them)"
	cleanup
	exit 3 ;;
esac

if [ "$MODE" = recover ]; then
	# the first recovery, logged
	sudo cp --sparse=always "$W/crash.img" "$W/rec.img"
	sudo truncate -s 8G "$W/log2.img"
	REC=$(sudo losetup -f --show "$W/rec.img") || die "losetup rec"
	LOG2=$(sudo losetup -f --show "$W/log2.img") || die "losetup log2"
	echo "0 $(sudo blockdev --getsz "$REC") log-writes $REC $LOG2" | sudo dmsetup create rc2 ||
		die "dmsetup create rc2"
	n0=$(sudo dmesg | wc -l)
	sudo mount -t "$FS" -o "$TAU_MOUNT_OPTS" /dev/mapper/rc2 "$TAU_MNT" || die "the first recovery's mount failed"
	sudo dmesg | tail -n +$((n0 + 1)) | grep -m1 "ino $AINO: replaying" | sed 's/^.*TAU: /== first recovery: /; s/$/ ==/'
	sudo dmsetup message rc2 0 mark mounted
	sudo umount "$TAU_MNT"
	sudo dmsetup remove rc2 || die "dmsetup remove rc2"
	RLOG=$LOG2 RBASE=$W/crash.img START=- STOP=mounted
else
	RLOG=$LOG RBASE=- START=pre-umount STOP=umounted
fi

# check one rebuilt disk: mount it (recovery) and judge the files
cat > /tmp/rc-check.sh <<EOF
#!/bin/bash
dev=\$(losetup -f --show "$W/scratch.img") || exit 3
dmesg -C
if ! mount -t $FS -o "$TAU_MOUNT_OPTS" \$dev "$TAU_MNT" 2>/dev/null; then
	losetup -d \$dev; echo "MOUNT-FAILED"; exit 0
fi
python3 /tmp/rc-judge.py "$F" "$N" "$EXTRAS"
dmesg | grep -E "ino $AINO\\b|segment map log" | head -8 | sed 's/^.*TAU: /    /'
umount "$TAU_MNT"; losetup -d \$dev
EOF
chmod +x /tmp/rc-check.sh

cat > /tmp/rc-judge.py <<'EOF'
import struct, sys
path, n, used = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def blk(k, tag):
    return struct.pack('<II', k, tag) * 512
def read(name, size):
    with open(name, 'rb') as f:
        return f.read(size)
bad = []
a = read(path, (32 + n) * 4096)
vers = sorted({struct.unpack('<II', a[k * 4096:k * 4096 + 8])[1] for k in range(min(32, len(a) // 4096))})
if a[:32 * 4096] != b''.join(blk(k, n) for k in range(32)):
    bad.append('A holds versions %s, not %d' % (vers, n))
if a[32 * 4096:] != b''.join(blk(31 + v, v) for v in range(1, n + 1)):
    bad.append('A lost blocks of its own')
for i in range(255):
    if read('%s.f%03d' % (path, i), 4096) != blk(0, 0xA2):
        bad.append('file f%03d' % i)
        break
for i in range(64):
    if read('%s.x%03d' % (path, i), 4096) != blk(0, 0xA3 if i < used else 0xE1):
        bad.append('file x%03d' % i)
        break
print('BAD ' + '; '.join(bad) if bad else 'OK A at version %d' % n)
EOF

# rebuild the logged writes from START to STOP over RBASE; judge every flush,
# FUA and mark, and every subset of each group of map block writes (the map
# blocks are in flight together; a group ends at the next write elsewhere)
sudo python3 - "$RLOG" "$RBASE" "$W/work.img" "$W/scratch.img" "$START" "$STOP" "$SB" "${RC_VERBOSE:-0}" <<'EOF'
import itertools, os, struct, subprocess, sys
log, base, work, scratch, start, stop, sb, verbose = sys.argv[1:9]
FLUSH, FUA, DISCARD, MARK = 1, 2, 4, 8
if base == '-':
    subprocess.run(['truncate', '-s', '8G', work], check=True)
else:
    subprocess.run(['cp', '--sparse=always', base, work], check=True)
mapsec = {(int(sb) + 4096 * b) // 512 for b in (1, 2)}
sbsec = int(sb) // 512
lf = open(log, 'rb')
magic, version, nr, secsz = struct.unpack('<QQQI', lf.read(28))
assert magic == 0x6a736677736872, "not a log-writes log"
wf = os.open(work, os.O_RDWR)
pos, on, checks, nsub, bad, seen, group = secsz, start == '-', 0, 0, 0, {}, []
def judge(label, extra=()):
    global checks, bad
    subprocess.run(['cp', '--sparse=always', work, scratch], check=True)
    if extra:
        sf = os.open(scratch, os.O_RDWR)
        for off, data in extra:
            os.pwrite(sf, data, off)
        os.close(sf)
    out = subprocess.run(['/tmp/rc-check.sh'], capture_output=True, text=True).stdout.strip()
    checks += 1
    v = out.split()[0] if out else 'NO-OUTPUT'
    seen[v] = seen.get(v, 0) + 1
    if v != 'OK':
        bad += 1
    if (v != 'OK' and bad <= 6) or verbose == '1':
        print('  %s: %s' % (label, out.replace('\n', ' |')))
def close_group():
    global group, nsub
    if not group:
        return
    ents = [e for e, _, _ in group]
    for k in range(len(group) + 1):
        for sub in itertools.combinations(group, k):
            nsub += 1
            judge('map writes %s, these on the disk: %s' % (ents, [e for e, _, _ in sub]),
                  [(off, data) for _, off, data in sub])
    for _, off, data in group:
        os.pwrite(wf, data, off)
    group = []
done = False
for i in range(nr):
    lf.seek(pos)
    hdr = lf.read(secsz)
    sector, nsec, flags, dlen = struct.unpack('<QQQQ', hdr[:32])
    pos += secsz
    if flags & MARK:
        name = hdr[32:32 + dlen].decode()
        close_group()
        if name == start:
            on = True
        if on:
            judge('mark %s (entry %d)' % (name, i))
        if name == stop:
            done = True
            break
        continue
    if flags & DISCARD:
        close_group()
        if nsec:
            subprocess.run(['fallocate', '-p', '-o', str(sector * secsz),
                            '-l', str(nsec * secsz), work], check=True)
        continue
    data = b''
    if nsec:
        lf.seek(pos)
        data = lf.read(nsec * secsz)
        pos += nsec * secsz
    if on and verbose == '1' and (flags & (FLUSH | FUA) or sbsec - 8 <= sector < sbsec + 24):
        print('  log entry %d: sector %d, %d sectors, flags %#x' % (i, sector, nsec, flags))
    if on and nsec == 8 and sector in mapsec:
        group.append((i, sector * secsz, data))
        continue
    if nsec:
        close_group()
        os.pwrite(wf, data, sector * secsz)
    if on and flags & (FLUSH | FUA) and not group:
        judge('entry %d (%s)' % (i, 'FUA' if flags & FUA else 'flush'))
close_group()
print('  %d states checked, %d of them subsets of map block writes: %s' %
      (checks, nsub, ', '.join('%s %d' % kv for kv in sorted(seen.items()))))
if not done:
    print('RESULT: INCONCLUSIVE (no %s mark)' % stop)
    sys.exit(3)
if not nsub:
    print('RESULT: INCONCLUSIVE (no map block writes between %s and %s)' % (start, stop))
    sys.exit(3)
print('RESULT: %s' % ('FAIL' if bad else 'PASS'))
sys.exit(1 if bad else 0)
EOF
rc=$?
[ "${RC_KEEP:-0}" = 1 ] && sudo cp --sparse=always "$W/crash.img" /dev/shm/rc-keep-crash.img
cleanup
exit $rc
