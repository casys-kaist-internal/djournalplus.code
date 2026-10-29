#!/bin/bash
# Flush order (taudocs/plan.md §10).  A qemu kill never loses the device's
# write cache, so the crash tests cannot see a missing flush.  This logs every
# write of a tau workload through dm-log-writes -- which logs a plain write
# only once a later flush has made it durable, and a FUA write when it
# completes -- then rebuilds the disk at every flush, FUA and mark in the log,
# mounts it (tau recovery) and checks the file, through the unmount's final
# checkpoint and segment map write as well.  At every flush it also checks each
# state with one of that flush's plain writes lost (a volatile cache may lose any
# of them; FO_DROP=0 skips these):
#   - every write whole or absent, and in order: a write after an fsync'd one
#     is never there without it
#   - every write an fsync returned for is there (a mark after each fsync)
#
#   usage: flushorder.sh <ext4|xfs> <case> [fsyncs]
#
# Each write is followed by fdatasync, except in the fs* cases: fsync(2), whose
# commit logs the inode after the record (kernel taudocs/plan.md §14.3.4).
#   append     8 KiB pages appended, fdatasync each (allocating commits)
#   falloc     8 KiB pages into a fallocate'd file (conversions)
#   subappend  100 B appends inside the last block (size-only commits)
#   overwrite  8 KiB pages rewritten in place (no host log force)
#   cpappend   append, journaled (tau_home 0), with a pause after each fsync: the
#              previous tx is checkpointed before the next commit, whose record
#              moves the tail past its home writes (bug.md #56)
#   cpsub      subappend with the same pause
#   fsoverwrite  overwrite, fsync(2), the timestamps logged and committed first
#              (utime, then another file's fsync): no host tx runs when the
#              record goes out; only the inode logged after it carries its flush
#   fscpover   overwrite, fsync(2), with the pause: the record without a flush
#              moves the tail past the previous tx's home writes
#   reuse      2 MiB segments: file 1 fills its first segment and goes idle, its
#              txs age out and are checkpointed, and file 2 is given that segment
#              (32 KiB appends); file 1 must keep all twenty 128 KiB writes
#   unlink     file 1's twenty 128 KiB writes, never checkpointed, then it is
#              unlinked; file 2, written before without tau, is rewritten through
#              tau (32 KiB, fsync each): it publishes a segment while the host has
#              not logged the unlink -- wherever file 1 comes back, it must hold
#              all twenty
#   truncate   file 1's twenty 128 KiB writes, the first ten aged out and
#              checkpointed, then it is truncated to ten; a background commit
#              of a rewrite of its block 0 moves its tail, and file 2 is
#              rewritten through tau as in unlink -- file 1 must hold all twenty
#              (the truncate lost) or the first ten (kernel plan.md §12.4)
#
# Needs ~/tautest/dm-log-writes.ko built for the running kernel.  Loop devices
# on /dev/shm only: no real disk is touched.  RECORD_FUA_ONLY=1 is the control
# (tau_record_fua_only: records durable before their data) -- overwrite must
# then FAIL.  SEGMAP_FUA_ONLY=1 (tau_segmap_fua_only: a freed segment map entry
# durable before the home writes) must FAIL during the unmount.
# REUSE_FLUSH_ONLY=1 (tau_reuse_flush_only: a freed segment reused while the disk
# map still names it) must FAIL in the single-drop states of reuse.
# DEAD_NOGATE=1 (tau_dead_nogate: an unlinked file's segments given back at the
# eviction) must FAIL in unlink.  FREE_UNCOND=1 (tau_free_uncond: the truncate's
# revoke tags unconditional) and FREE_NOHOLD=1 (tau_free_nohold: its txs not held
# for the host) must FAIL in truncate.  NOFLUSH_OLD_EPOCH=1
# (tau_noflush_old_epoch: a record without a flush keeps the allocation epoch,
# not the host tx running at the record) and GATE_TAIL=1 (tau_gate_tail:
# recovery takes the tail of a record its gate refuses) must FAIL in cpsub;
# GATE_FLOOR=1 (tau_gate_floor: a refused orphan commit sets a floor) must FAIL
# in reuse.  The GATE_* knobs act on the recovery of the rebuilt disks.
# FSYNC_NOINODE=1 (tau_fsync_noinode: an fsync(2) commit leaves the inode out,
# its record still without a flush) must FAIL in fsoverwrite.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}; CASE=${2:-}; N=${3:-24}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <ext4|xfs> <case> [fsyncs]" ;; esac
case "$CASE" in append|falloc|subappend|overwrite|reuse|unlink|truncate|cpappend|cpsub|fsoverwrite|fscpover) ;; *) die "unknown case '$CASE'" ;; esac
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
if [ -e $P/tau_segmap_fua_only ]; then
	echo "${SEGMAP_FUA_ONLY:-0}" | sudo tee $P/tau_segmap_fua_only >/dev/null
elif [ "${SEGMAP_FUA_ONLY:-0}" = 1 ]; then
	die "no tau_segmap_fua_only in this kernel"
fi
if [ -e $P/tau_reuse_flush_only ]; then
	echo "${REUSE_FLUSH_ONLY:-0}" | sudo tee $P/tau_reuse_flush_only >/dev/null
elif [ "${REUSE_FLUSH_ONLY:-0}" = 1 ]; then
	die "no tau_reuse_flush_only in this kernel"
fi
if [ -e $P/tau_dead_nogate ]; then
	echo "${DEAD_NOGATE:-0}" | sudo tee $P/tau_dead_nogate >/dev/null
elif [ "$CASE" = unlink ]; then
	die "no tau_dead_nogate in this kernel"
fi
if [ -e $P/tau_free_uncond ]; then
	echo "${FREE_UNCOND:-0}" | sudo tee $P/tau_free_uncond >/dev/null
	echo "${FREE_NOHOLD:-0}" | sudo tee $P/tau_free_nohold >/dev/null
elif [ "$CASE" = truncate ]; then
	die "no tau_free_uncond in this kernel"
fi
if [ -e $P/tau_noflush_old_epoch ]; then
	echo "${NOFLUSH_OLD_EPOCH:-0}" | sudo tee $P/tau_noflush_old_epoch >/dev/null
	echo "${NOFLUSH_NOMARK:-0}" | sudo tee $P/tau_noflush_nomark >/dev/null
	echo 0 | sudo tee $P/tau_gate_tail $P/tau_gate_floor >/dev/null
elif [ -n "${NOFLUSH_OLD_EPOCH:-}${NOFLUSH_NOMARK:-}${GATE_TAIL:-}${GATE_FLOOR:-}" ]; then
	die "no tau_noflush_old_epoch in this kernel"
fi
if [ -e $P/tau_fsync_noinode ]; then
	echo "${FSYNC_NOINODE:-0}" | sudo tee $P/tau_fsync_noinode >/dev/null
elif [ "${FSYNC_NOINODE:-0}" = 1 ]; then
	die "no tau_fsync_noinode in this kernel"
fi
# no discards, no background inode-table zeroing in the log
export TAU_MKE2FS_OPTS="-E nodiscard,lazy_itable_init=0,lazy_journal_init=0"
export TAU_MKFS_XFS_OPTS="-K"
if [ "$CASE" = reuse ]; then
	TAU_MKE2FS_OPTS="$TAU_MKE2FS_OPTS,tau_segsize=2m"
	TAU_MKFS_XFS_OPTS="$TAU_MKFS_XFS_OPTS -l tjsegsize=2m"
	# txs stay on the checkpoint list until they age out, two seconds after commit
	small_tx=$(cat $P/tau_cp_small_tx); tx_age=$(cat $P/tau_max_transaction_age)
	echo 0 | sudo tee $P/tau_cp_small_tx >/dev/null
	echo 2 | sudo tee $P/tau_max_transaction_age >/dev/null
fi
if [ "$CASE" = unlink ] || [ "$CASE" = truncate ]; then
	# file 1's copies stay in the journal only: never checkpointed
	small_tx=$(cat $P/tau_cp_small_tx); tx_age=$(cat $P/tau_max_transaction_age)
	echo 0 | sudo tee $P/tau_cp_small_tx >/dev/null
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
fi
case "$CASE" in reuse|unlink|truncate|cpappend)	# file 1 journaled, not written home
	home=$(cat $P/tau_home 2>/dev/null || echo 1); tau_home 0 ;;
esac
sudo sh -c "echo 0 > $P/tau_probe_seg_reuse_flush" 2>/dev/null
sudo sh -c "echo 0 > $P/tau_probe_jwrite_record; echo 0 > $P/tau_probe_record_noflush" 2>/dev/null
MNT_DEV=/dev/mapper/fo
TAU_DEV=$MNT_DEV mkfs_mount "$FS"

cat > /tmp/fo-work.py <<'EOF'
import os, struct, subprocess, sys, time
path, case, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
gap = float(sys.argv[4]) if case in ('cpappend', 'cpsub', 'fscpover') else 0
sync = os.fsync if case.startswith('fs') else os.fdatasync
pre = case == 'fsoverwrite'
case = {'cpappend': 'append', 'cpsub': 'subappend', 'fsoverwrite': 'overwrite',
        'fscpover': 'overwrite'}.get(case, case)
def mark(name):
    subprocess.run(['dmsetup', 'message', 'fo', '0', 'mark', name], check=True)
def page(k, v):
    return struct.pack('<II', k, v) * 1024
fd = os.open(path, os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
if pre:		# not tau: its fsync commits the host's running tx
    pfd = os.open(path + '.plain', os.O_RDWR | os.O_CREAT, 0o644)
if case == 'falloc':
    os.posix_fallocate(fd, 0, 32 * 8192)
elif case == 'overwrite':
    for j in range(32):
        os.pwrite(fd, page(j + 1, 0), j * 8192)
elif case == 'subappend':
    os.pwrite(fd, b'A' * 100, 0)
elif case in ('unlink', 'truncate'):
    # not tau, and fsync'd once more after the close: XFS logs the EOF trim
    for _ in range(2):
        fd2 = os.open(path + '2', os.O_RDWR | os.O_CREAT, 0o644)
        if _ == 0:
            for k in range(1, n + 1):
                os.pwrite(fd2, struct.pack('<II', k, 0xE2) * 4096, (k - 1) * 32768)
        os.fsync(fd2)
        os.close(fd2)
sync(fd)
os.sync()			# the setup is durable before the first check
mark('ready')
if case == 'reuse':
    import time
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    for k in range(1, 21):	# 680 journal blocks: the first segment fills
        os.pwrite(fd, blk(k, 0xF1, 131072), (k - 1) * 131072)
        sync(fd)
    mark('f1-done')
    time.sleep(15)		# aged out and checkpointed: the segment is free again
    fd2 = os.open(path + '2', os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
    for k in range(1, n + 1):
        os.pwrite(fd2, blk(k, 0xF2, 32768), (k - 1) * 32768)
        sync(fd2)
        mark('fsync-%d' % k)
    mark('end')
    sys.exit()
if case == 'unlink':
    import time
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    for k in range(1, 21):
        os.pwrite(fd, blk(k, 0xF1, 131072), (k - 1) * 131072)
        sync(fd)
    os.close(fd)
    mark('f1-done')
    os.unlink(path)		# evicted here: its segments wait for the host
    fd2 = os.open(path + '2', os.O_RDWR | 0o40000000)
    for k in range(1, n + 1):
        os.pwrite(fd2, blk(k, 0xF2, 32768), (k - 1) * 32768)
        sync(fd2)
        mark('fsync-%d' % k)
    mark('end')
    sys.exit()
if case == 'truncate':
    import time
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    def age(s):
        with open('/sys/module/tau_journal/parameters/tau_max_transaction_age', 'w') as f:
            f.write(str(s))
    age(2)			# the first ten go home and leave the journal
    for k in range(1, 21):
        if k == 11:
            age(120)	# the last ten stay in the journal only
        os.pwrite(fd, blk(k, 0xF1, 131072), (k - 1) * 131072)
        sync(fd)
    time.sleep(8)
    mark('f1-done')
    os.ftruncate(fd, 10 * 131072)
    # a background commit, no host log force: the tail passes what it dropped
    os.pwrite(fd, blk(1, 0xF3, 4096), 0)
    time.sleep(7)
    fd2 = os.open(path + '2', os.O_RDWR | 0o40000000)
    for k in range(1, n + 1):
        os.pwrite(fd2, blk(k, 0xF2, 32768), (k - 1) * 32768)
        sync(fd2)
        mark('fsync-%d' % k)
    mark('end')
    sys.exit()
for k in range(1, n + 1):
    if case == 'subappend':
        os.pwrite(fd, bytes([0x40 + k % 60]) * 100, 100 * k)
    else:
        os.pwrite(fd, page(k, 1), (k - 1) * 8192)
    if pre:
        os.utime(path)		# the timestamps logged now ...
        os.pwrite(pfd, page(k, 2), 0)
        os.fsync(pfd)		# ... and committed: no host tx at the record
    sync(fd)
    mark('fsync-%d' % k)
    if gap:
        time.sleep(gap)		# checkpointed before the next commit
mark('end')
os.close(fd)
EOF
sudo python3 /tmp/fo-work.py "$F" "$CASE" "$N" "${FO_GAP:-0.3}" || die "workload failed"
reused=$(cat $P/tau_probe_seg_reuse_flush 2>/dev/null)
records=$(cat $P/tau_probe_jwrite_record 2>/dev/null)
noflush=$(cat $P/tau_probe_record_noflush 2>/dev/null)
sudo umount "$TAU_MNT"
sudo dmsetup remove fo || die "dmsetup remove"
echo 0 | sudo tee $P/tau_record_fua_only >/dev/null
[ -e $P/tau_segmap_fua_only ] && echo 0 | sudo tee $P/tau_segmap_fua_only >/dev/null
[ -e $P/tau_reuse_flush_only ] && echo 0 | sudo tee $P/tau_reuse_flush_only >/dev/null
[ -e $P/tau_dead_nogate ] && echo 0 | sudo tee $P/tau_dead_nogate >/dev/null
[ -e $P/tau_free_uncond ] && echo 0 | sudo tee $P/tau_free_uncond $P/tau_free_nohold >/dev/null
[ -e $P/tau_noflush_old_epoch ] && echo 0 | sudo tee $P/tau_noflush_old_epoch $P/tau_noflush_nomark >/dev/null
[ -e $P/tau_fsync_noinode ] && echo 0 | sudo tee $P/tau_fsync_noinode >/dev/null
case "$CASE" in reuse|unlink|truncate|cpappend) tau_home "$home" ;; esac
if [ "$CASE" = unlink ] || [ "$CASE" = truncate ]; then
	echo "$small_tx" | sudo tee $P/tau_cp_small_tx >/dev/null
	echo "$tx_age" | sudo tee $P/tau_max_transaction_age >/dev/null
fi
if [ "$CASE" = reuse ]; then
	echo "$small_tx" | sudo tee $P/tau_cp_small_tx >/dev/null
	echo "$tx_age" | sudo tee $P/tau_max_transaction_age >/dev/null
	echo "== reuse: device flushes before a freed segment was reused: ${reused:-?} =="
	if [ "${reused:-0}" = 0 ]; then
		echo "RESULT: INCONCLUSIVE (no freed segment was reused)"
		cleanup
		exit 3
	fi
fi
echo "== $FS $CASE: $N fsyncs logged${RECORD_FUA_ONLY:+ (control: records FUA only)}${SEGMAP_FUA_ONLY:+ (control: segment map FUA only)}${REUSE_FLUSH_ONLY:+ (control: reuse without the map write)}${DEAD_NOGATE:+ (control: dead segments back at once)}${FREE_UNCOND:+ (control: unconditional free tags)}${FREE_NOHOLD:+ (control: free not held)}${NOFLUSH_OLD_EPOCH:+ (control: allocation epoch on records without a flush)}${NOFLUSH_NOMARK:+ (control: iclog not marked)}${GATE_TAIL:+ (control: recovery takes the tail of a refused record)}${GATE_FLOOR:+ (control: a refused orphan sets a floor)}${FSYNC_NOINODE:+ (control: fsync(2) without the inode)} =="
echo "== records: ${records:-?}, of them without a flush: ${noflush:-?} =="
# recovery-side controls: the mounts below recover the rebuilt disks
[ -e $P/tau_gate_tail ] && echo "${GATE_TAIL:-0}" | sudo tee $P/tau_gate_tail >/dev/null
[ -e $P/tau_gate_floor ] && echo "${GATE_FLOOR:-0}" | sudo tee $P/tau_gate_floor >/dev/null

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
path, case, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
case = {'cpappend': 'append', 'cpsub': 'subappend', 'fsoverwrite': 'overwrite',
        'fscpover': 'overwrite'}.get(case, case)
durable, f1done = (int(x) for x in sys.argv[4].split(':'))
def page(k, v):
    return struct.pack('<II', k, v) * 1024
if case == 'reuse':
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    def whole(data, tag, size):
        m = len(data) // size
        bad = [i + 1 for i in range(m) if data[i*size:(i+1)*size] != blk(i + 1, tag, size)]
        return m, len(data) % size == 0 and not bad, bad
    try:
        d1 = open(path, 'rb').read()
    except FileNotFoundError:
        print("BAD file 1 missing"); sys.exit()
    try:
        d2 = open(path + '2', 'rb').read()
    except FileNotFoundError:
        d2 = b''
    m1, ok1, bad1 = whole(d1, 0xF1, 131072)
    m2, ok2, bad2 = whole(d2, 0xF2, 32768)
    if not ok1 or (f1done and m1 != 20):
        foreign = [i for i in bad1 if struct.pack('<I', 0xF2) in d1[(i-1)*131072:i*131072]]
        print("BAD file 1: size %d, writes %s wrong%s" % (len(d1), bad1,
              ", %s hold file 2's data" % foreign if foreign else ""))
    elif not ok2:
        print("BAD file 2: size %d, not a whole prefix" % len(d2))
    elif m2 < durable:
        print("BAD file 2: %d of %d fsync'd writes there" % (m2, durable))
    else:
        print("OK file 1 %d, file 2 %d writes (durable %d)" % (m1, m2, durable))
    sys.exit()
if case == 'truncate':
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    try:
        d1 = open(path, 'rb').read()
    except FileNotFoundError:
        print("BAD file 1 missing"); sys.exit()
    m1 = len(d1) // 131072
    # block 0 may hold its rewrite
    bad1 = [k for k in range(1, m1 + 1)
            if d1[(k-1)*131072:k*131072] != blk(k, 0xF1, 131072) and
               not (k == 1 and d1[:4096] == blk(1, 0xF3, 4096) and
                    d1[4096:131072] == blk(1, 0xF1, 131072)[4096:])]
    if len(d1) % 131072 or bad1 or (f1done and m1 not in (10, 20)):
        print("BAD file 1: size %d, writes %s wrong" % (len(d1), bad1)); sys.exit()
    try:
        d2 = open(path + '2', 'rb').read()
    except FileNotFoundError:
        print("BAD file 2 missing"); sys.exit()
    m2, ok2 = 0, len(d2) == n * 32768
    for j in range(n if ok2 else 0):
        b = d2[j*32768:(j+1)*32768]
        if b == blk(j + 1, 0xF2, 32768) and m2 == j:
            m2 = j + 1
        elif b != blk(j + 1, 0xE2, 32768):
            ok2 = False
    if not ok2:
        print("BAD file 2: size %d, its rewrites not a whole prefix" % len(d2))
    elif m2 < durable:
        print("BAD file 2: %d of %d fsync'd rewrites there" % (m2, durable))
    else:
        print("OK file 1 %d writes, file 2 %d rewrites (durable %d)" % (m1, m2, durable))
    sys.exit()
if case == 'unlink':
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    def whole(data, tag, size):
        m = len(data) // size
        bad = [i + 1 for i in range(m) if data[i*size:(i+1)*size] != blk(i + 1, tag, size)]
        return m, len(data) % size == 0 and not bad, bad
    try:
        d1 = open(path, 'rb').read()
    except FileNotFoundError:
        d1 = None
    d2 = open(path + '2', 'rb').read()
    m2, ok2 = 0, len(d2) == n * 32768
    for j in range(n if ok2 else 0):
        b = d2[j*32768:(j+1)*32768]
        if b == blk(j + 1, 0xF2, 32768) and m2 == j:
            m2 = j + 1
        elif b != blk(j + 1, 0xE2, 32768):
            ok2 = False
    if d1 is None:
        if not f1done:
            print("BAD file 1 missing before its unlink"); sys.exit()
        m1 = -1
    else:
        m1, ok1, bad1 = whole(d1, 0xF1, 131072)
        if not ok1 or (f1done and m1 != 20):
            print("BAD file 1 back: size %d, writes %s wrong" % (len(d1), bad1)); sys.exit()
    if not ok2:
        print("BAD file 2: size %d, its rewrites not a whole prefix" % len(d2))
    elif m2 < durable:
        print("BAD file 2: %d of %d fsync'd rewrites there" % (m2, durable))
    else:
        print("OK file 1 %s, file 2 %d rewrites (durable %d)" %
              ("gone" if m1 < 0 else "%d" % m1, m2, durable))
    sys.exit()
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

# replay the log entry by entry; check at every flush / FUA / mark from "ready"
# to the end of the log: the run, then the unmount.  Before each flush, also
# check each state that lost one plain write logged since the last flush.
sudo python3 - "$LOG" "$W/replay.img" "$W/scratch.img" <<'EOF'
import os, shutil, struct, subprocess, sys
log, replay, scratch = sys.argv[1:4]
FLUSH, FUA, DISCARD, MARK = 1, 2, 4, 8
lf = open(log, 'rb')
magic, version, nr, secsz = struct.unpack('<QQQI', lf.read(28))
assert magic == 0x6a736677736872, "not a log-writes log"
rf = os.open(replay, os.O_RDWR)
pos, state, durable, checks, bad, seen = secsz, None, 0, 0, 0, {}
f1done = 0
phase = {'run': 0, 'umount': 0}
DROP = os.environ.get('FO_DROP', '1') == '1'
pending = []	# plain writes since the last flush: (entry, offset, bytes before it)
dchecks, dbad, dseen = 0, 0, {}
def judge():
    return subprocess.run(['/tmp/fo-check.sh', '%d:%d' % (durable, f1done)], capture_output=True, text=True).stdout.strip()
for i in range(nr):
    lf.seek(pos)
    hdr = lf.read(secsz)
    sector, nsec, flags, dlen = struct.unpack('<QQQQ', hdr[:32])
    pos += secsz
    if flags & FLUSH:
        for k, (e, off, old) in enumerate(pending if DROP and state else []):
            if any(o < off + len(old) and off < o + len(b) for _, o, b in pending[k + 1:]):
                continue	# a later write covers it
            subprocess.run(['cp', '--sparse=always', replay, scratch], check=True)
            sf = os.open(scratch, os.O_RDWR)
            os.pwrite(sf, old, off)
            os.close(sf)
            out = judge()
            dchecks += 1
            verdict = out.split()[0] if out else 'NO-OUTPUT'
            dseen[verdict] = dseen.get(verdict, 0) + 1
            if verdict != 'OK':
                dbad += 1
                if dbad <= 5:
                    print("  flush at entry %d without entry %d (%s), %d fsyncs returned: %s" %
                          (i, e, state, durable, out))
        pending = []
    if flags & MARK:
        name = hdr[32:32 + dlen].decode()
        if name == 'ready':
            state = 'run'
        elif name == 'end':
            state = 'umount'
        elif name.startswith('fsync-'):
            durable = int(name[6:])
        elif name == 'f1-done':
            f1done = 1
    elif flags & DISCARD:
        if nsec:
            subprocess.run(['fallocate', '-p', '-o', str(sector * secsz),
                            '-l', str(nsec * secsz), replay], check=True)
    elif nsec:
        lf.seek(pos)
        data = lf.read(nsec * secsz)
        if not flags & (FLUSH | FUA):
            pending.append((i, sector * secsz, os.pread(rf, len(data), sector * secsz)))
        os.pwrite(rf, data, sector * secsz)
        pos += nsec * secsz
    if state is None or not (flags & (FLUSH | FUA | MARK)):
        continue
    subprocess.run(['cp', '--sparse=always', replay, scratch], check=True)
    out = judge()
    checks += 1
    phase[state] += 1
    verdict = out.split()[0] if out else 'NO-OUTPUT'
    seen[verdict] = seen.get(verdict, 0) + 1
    if verdict != 'OK':
        bad += 1
        if bad <= 5:
            kind = 'mark' if flags & MARK else ('FUA' if flags & FUA else 'flush')
            print("  entry %d (%s, %s), %d fsyncs returned: %s" % (i, kind, state, durable, out))
print("  %d crash states checked (%d in the run, %d during the unmount): %s" %
      (checks, phase['run'], phase['umount'], ", ".join("%s %d" % kv for kv in sorted(seen.items()))))
if DROP:
    print("  %d single-drop states: %s" % (dchecks, ", ".join("%s %d" % kv for kv in sorted(dseen.items()))))
ok = checks and not bad and not dbad
print("RESULT: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
EOF
rc=$?
[ -e $P/tau_gate_tail ] && echo 0 | sudo tee $P/tau_gate_tail $P/tau_gate_floor >/dev/null
# FO_KEEP=1 keeps the log for a look at the entries a failure names
[ "${FO_KEEP:-0}" = 1 ] && sudo cp --sparse=always "$W/log.img" /dev/shm/fo-keep-log.img
cleanup
exit $rc
