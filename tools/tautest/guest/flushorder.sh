#!/bin/bash
# Flush order (taudocs/plan.md §10).  A qemu kill never loses the device's
# write cache, so the crash tests cannot see a missing flush.  This logs every
# write of a tau workload through dm-log-writes -- which logs a plain write
# only once a later flush has made it durable, and a FUA write when it
# completes -- then rebuilds the disk at every flush, FUA and mark in the log,
# mounts it (tau recovery) and checks the file:
#   - every write whole or absent, and in order: a write after an fsync'd one
#     is never there without it
#   - every write an fsync returned for is there (a mark after each fsync)
#
#   usage: flushorder.sh <ext4|xfs> <append|falloc|subappend|overwrite> [fsyncs]
#
#   append     8 KiB pages appended, fsync each (allocating commits)
#   falloc     8 KiB pages into a fallocate'd file (conversions)
#   subappend  100 B appends inside the last block (size-only commits)
#   overwrite  8 KiB pages rewritten in place (no host log force)
#
# Needs ~/tautest/dm-log-writes.ko built for the running kernel.  Loop devices
# on /dev/shm only: no real disk is touched.  RECORD_FUA_ONLY=1 is the control
# (tau_record_fua_only: records durable before their data) -- overwrite must
# then FAIL.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}; CASE=${2:-}; N=${3:-24}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <ext4|xfs> <case> [fsyncs]" ;; esac
case "$CASE" in append|falloc|subappend|overwrite) ;; *) die "unknown case '$CASE'" ;; esac
W=/dev/shm/flushorder
SIZE=${FO_SIZE:-4G}
P=/sys/module/tau_journal/parameters
F=$TAU_MNT/fo.dat

cleanup() {
	sudo umount "$TAU_MNT" 2>/dev/null
	sudo dmsetup remove fo 2>/dev/null
	for f in data log replay scratch; do
		for l in $(losetup -j "$W/$f.img" 2>/dev/null | cut -d: -f1); do
			sudo losetup -d "$l"
		done
	done
	sudo rm -rf "$W"
}
cleanup
sudo mkdir -p "$W"
sudo truncate -s "$SIZE" "$W/data.img" "$W/replay.img"
sudo truncate -s 8G "$W/log.img"
DATA=$(sudo losetup -f --show "$W/data.img") || die "losetup data"
LOG=$(sudo losetup -f --show "$W/log.img") || die "losetup log"
lsmod | grep -q '^dm_log_writes' || sudo insmod ~/tautest/dm-log-writes.ko ||
	die "cannot load ~/tautest/dm-log-writes.ko"
echo "0 $(sudo blockdev --getsz "$DATA") log-writes $DATA $LOG" | sudo dmsetup create fo ||
	die "dmsetup create"

echo "${RECORD_FUA_ONLY:-0}" | sudo tee $P/tau_record_fua_only >/dev/null ||
	die "no tau_record_fua_only: needs CONFIG_TAU_PROBE_TORN=y"
sudo sh -c "echo 0 > $P/tau_probe_record_noflush" 2>/dev/null
# no discards, no background inode-table zeroing in the log
export TAU_MKE2FS_OPTS="-E nodiscard,lazy_itable_init=0,lazy_journal_init=0"
export TAU_MKFS_XFS_OPTS="-K"
MNT_DEV=/dev/mapper/fo
TAU_DEV=$MNT_DEV mkfs_mount "$FS"

cat > /tmp/fo-work.py <<'EOF'
import os, struct, subprocess, sys
path, case, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
def mark(name):
    subprocess.run(['dmsetup', 'message', 'fo', '0', 'mark', name], check=True)
def page(k, v):
    return struct.pack('<II', k, v) * 1024
fd = os.open(path, os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
if case == 'falloc':
    os.posix_fallocate(fd, 0, 32 * 8192)
elif case == 'overwrite':
    for j in range(32):
        os.pwrite(fd, page(j + 1, 0), j * 8192)
elif case == 'subappend':
    os.pwrite(fd, b'A' * 100, 0)
os.fsync(fd)
os.sync()			# the setup is durable before the first check
mark('ready')
for k in range(1, n + 1):
    if case == 'subappend':
        os.pwrite(fd, bytes([0x40 + k % 60]) * 100, 100 * k)
    else:
        os.pwrite(fd, page(k, 1), (k - 1) * 8192)
    os.fsync(fd)
    mark('fsync-%d' % k)
mark('end')
os.close(fd)
EOF
sudo python3 /tmp/fo-work.py "$F" "$CASE" "$N" || die "workload failed"
noflush=$(cat $P/tau_probe_record_noflush 2>/dev/null)
sudo umount "$TAU_MNT"
sudo dmsetup remove fo || die "dmsetup remove"
echo 0 | sudo tee $P/tau_record_fua_only >/dev/null
echo "== $FS $CASE: $N fsyncs logged; records without a flush: ${noflush:-?}${RECORD_FUA_ONLY:+ (control: records FUA only)} =="

# check one rebuilt disk: mount it (tau recovery runs) and judge the file
cat > /tmp/fo-check.sh <<EOF
#!/bin/bash
dev=\$(losetup -f --show "$W/scratch.img") || exit 3
if ! mount -t $FS -o "${TAU_MOUNT_OPTS:-tjournal}" \$dev "$TAU_MNT" 2>/dev/null; then
	losetup -d \$dev; echo "MOUNT-FAILED"; exit 0
fi
python3 /tmp/fo-judge.py "$F" "$CASE" "$N" "\$1"
umount "$TAU_MNT"; losetup -d \$dev
EOF
chmod +x /tmp/fo-check.sh

cat > /tmp/fo-judge.py <<'EOF'
import struct, sys
path, case, n, durable = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def page(k, v):
    return struct.pack('<II', k, v) * 1024
try:
    data = open(path, 'rb').read()
except FileNotFoundError:
    print("BAD file missing (durable %d)" % durable); sys.exit()
P = 8192
if case == 'subappend':
    full = b'A' * 100 + b''.join(bytes([0x40 + k % 60]) * 100 for k in range(1, n + 1))
    m = (len(data) - 100) // 100
    ok = len(data) >= 100 and (len(data) - 100) % 100 == 0 and data == full[:len(data)]
elif case == 'append':
    m = len(data) // P
    ok = len(data) % P == 0 and all(data[i*P:(i+1)*P] == page(i + 1, 1) for i in range(m))
else:
    old = (lambda j: b'\0' * P) if case == 'falloc' else (lambda j: page(j + 1, 0))
    m, ok = 0, len(data) == 32 * P
    for j in range(32 if ok else 0):
        blk = data[j*P:(j+1)*P]
        if j < n and blk == page(j + 1, 1) and m == j:
            m = j + 1
        elif blk != old(j):
            ok = False
if not ok:
    print("BAD size %d, content not a whole prefix (durable %d)" % (len(data), durable))
elif m < durable:
    print("BAD %d of %d fsync'd writes there" % (m, durable))
else:
    print("OK %d writes (durable %d)" % (m, durable))
EOF

# replay the log entry by entry; check at every flush / FUA / mark between
# "ready" and "end"
sudo python3 - "$LOG" "$W/replay.img" "$W/scratch.img" <<'EOF'
import os, shutil, struct, subprocess, sys
log, replay, scratch = sys.argv[1:4]
FLUSH, FUA, DISCARD, MARK = 1, 2, 4, 8
lf = open(log, 'rb')
magic, version, nr, secsz = struct.unpack('<QQQI', lf.read(28))
assert magic == 0x6a736677736872, "not a log-writes log"
rf = os.open(replay, os.O_RDWR)
pos, state, durable, checks, bad, seen = secsz, None, 0, 0, 0, {}
for i in range(nr):
    lf.seek(pos)
    hdr = lf.read(secsz)
    sector, nsec, flags, dlen = struct.unpack('<QQQQ', hdr[:32])
    pos += secsz
    if flags & MARK:
        name = hdr[32:32 + dlen].decode()
        if name == 'ready':
            state = 'run'
        elif name == 'end':
            break
        elif name.startswith('fsync-'):
            durable = int(name[6:])
    elif flags & DISCARD:
        if nsec:
            subprocess.run(['fallocate', '-p', '-o', str(sector * secsz),
                            '-l', str(nsec * secsz), replay], check=True)
    elif nsec:
        lf.seek(pos)
        os.pwrite(rf, lf.read(nsec * secsz), sector * secsz)
        pos += nsec * secsz
    if state != 'run' or not (flags & (FLUSH | FUA | MARK)):
        continue
    subprocess.run(['cp', '--sparse=always', replay, scratch], check=True)
    out = subprocess.run(['/tmp/fo-check.sh', str(durable)], capture_output=True, text=True).stdout.strip()
    checks += 1
    verdict = out.split()[0] if out else 'NO-OUTPUT'
    seen[verdict] = seen.get(verdict, 0) + 1
    if verdict != 'OK':
        bad += 1
        if bad <= 5:
            kind = 'mark' if flags & MARK else ('FUA' if flags & FUA else 'flush')
            print("  entry %d (%s), %d fsyncs returned: %s" % (i, kind, durable, out))
print("  %d crash states checked: %s" % (checks, ", ".join("%s %d" % kv for kv in sorted(seen.items()))))
print("RESULT: %s" % ("PASS" if checks and not bad else "FAIL"))
sys.exit(0 if checks and not bad else 1)
EOF
rc=$?
cleanup
exit $rc
