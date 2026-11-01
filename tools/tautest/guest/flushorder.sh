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
#   mapsplit   2 MiB segments and a 1 GiB journal, two segment map blocks: file
#              1 takes entry 0 with three page writes and 254 small files one
#              entry each, then one 4.3 MiB overwrite of file 1 needs two new
#              segments -- entries 255 and 256, one in each map block (kernel
#              plan.md §15.1 b); the writes before it must stay, and it whole or
#              absent.  No single-drop states unless FO_DROP=1
#   maplog     the mapsplit geometry with the segment map log cut to 8 blocks
#              (tau_maplog_len): 255 small files rewritten through tau take
#              entries 0-254 first, then each fsync is one more file's first
#              tau rewrite, a new segment each -- the log wraps and the map
#              blocks are written during the run, by a commit that finds the
#              log full (the first half) and by journald (the second, with the
#              pause); every fsync'd rewrite must stay (kernel plan.md §15)
#   fsmapsplit mapsplit with the big write fsync(2)'d: its record goes without
#              a flush -- the inode logged after it carries one -- and vouches
#              for both claims
#   mapappend  mapsplit, but the big write is a 4.3 MiB append past file 1's
#              EOF, journaled (tau_home 0): an allocating commit, its record
#              without a flush, its blocks converted only after it -- it whole
#              or absent, the writes before it kept
#   logappend  maplog, but each round four threads append a block to four new
#              files, fdatasync each, journaled (tau_home 0): allocating
#              commits, records without a flush, a new segment each -- the
#              map blocks are written while other commits' claims wait for
#              their host commits; every fsync'd append must stay
#   inoreuse   file 1's twenty 128 KiB writes, never checkpointed, then it is
#              unlinked; file 2, created after it with its ino, is given its
#              segment and writes ten 128 KiB pages the same way: file 1's txs
#              stay right behind file 2's (kernel plan.md §16, bug.md #72) --
#              file 2 must keep every fsync'd write, each whole, and file 1, if
#              it comes back, all twenty
#
# Needs ~/tautest/dm-log-writes.ko built for the running kernel.  Loop devices
# on /dev/shm only: no real disk is touched.  RECORD_FUA_ONLY=1 is the control
# (tau_record_fua_only: records durable before their data) -- overwrite must
# then FAIL.  SEGMAP_FUA_ONLY=1 (tau_segmap_fua_only: a freed segment map entry
# durable before the home writes) must FAIL during the unmount, and in reuse
# before it: the run writes no map blocks there, so a free block alone goes
# out ahead of its txs' home writes (bug.md #53).
# REUSE_FLUSH_ONLY=1 (tau_reuse_flush_only: a freed segment reused while the disk
# map still names it) must FAIL in the single-drop states of reuse.  With the
# segment map log the new owner's claim goes out with its first writes and hides
# the old owner's, unless another file's flush lands between them: reuse sets
# tau_claim_flush (a flush there) in both runs, and the control keeps the free
# off the log until the reuse.
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
# its record still without a flush) must FAIL in fsoverwrite.  MAPLOG_SPLIT=1
# (tau_maplog_split: a commit's claims one per log block, its record vouching
# for the last) must FAIL in mapsplit, fsmapsplit and mapappend;
# MAPLOG_EARLY_BASE=1 (tau_maplog_early_base: the superblock's base moved before
# the map blocks are written) must FAIL in maplog and logappend.
# SERIAL_IGNORE=1 (tau_serial_ignore: recovery
# does not tell apart the files a mount gave one ino) must FAIL in inoreuse; it
# acts on the recovery of the rebuilt disks.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}; CASE=${2:-}; N=${3:-24}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <ext4|xfs> <case> [fsyncs]" ;; esac
case "$CASE" in append|falloc|subappend|overwrite|reuse|unlink|truncate|cpappend|cpsub|fsoverwrite|fscpover|mapsplit|fsmapsplit|mapappend|maplog|logappend|inoreuse) ;; *) die "unknown case '$CASE'" ;; esac
case "$CASE" in	# a journal of two map blocks: one big write, or the log wrapping
mapsplit|fsmapsplit|mapappend) GEOM=split ;;
maplog|logappend) GEOM=log ;;
*) GEOM= ;;
esac
[ "$GEOM" = split ] && N=1
[ "$CASE" = inoreuse ] && N=10	# file 1 writes twenty
W=/dev/shm/flushorder
SIZE=${FO_SIZE:-4G}
[ -n "$GEOM" ] && SIZE=${FO_SIZE:-8G}	# ext4: a tenth of it is two map blocks
DROP=${FO_DROP:-1}
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
if [ -e $P/tau_serial_ignore ]; then
	echo 0 | sudo tee $P/tau_serial_ignore >/dev/null
elif [ -n "${SERIAL_IGNORE:-}" ]; then
	die "no tau_serial_ignore in this kernel"
fi
if [ -e $P/tau_maplog_len ]; then
	echo "${MAPLOG_SPLIT:-0}" | sudo tee $P/tau_maplog_split >/dev/null
	echo "${MAPLOG_EARLY_BASE:-0}" | sudo tee $P/tau_maplog_early_base >/dev/null
	mllen=$(cat $P/tau_maplog_len)
	[ "$GEOM" = log ] && echo 8 | sudo tee $P/tau_maplog_len >/dev/null
elif [ "$GEOM" = log ] || [ -n "${MAPLOG_SPLIT:-}${MAPLOG_EARLY_BASE:-}" ]; then
	die "no segment map log in this kernel"
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
	[ -e $P/tau_claim_flush ] && echo 1 | sudo tee $P/tau_claim_flush >/dev/null
fi
if [ -n "$GEOM" ]; then
	# 512 segments of 2 MiB, two map blocks
	TAU_MKE2FS_OPTS="$TAU_MKE2FS_OPTS,tau_segsize=2m"
	TAU_MKFS_XFS_OPTS="$TAU_MKFS_XFS_OPTS -l tjsegsize=2m,tjmaxsize=1G"
	export TAU_MOUNT_OPTS=tjournal,tjournal_size=1
	DROP=${FO_DROP:-0}
fi
if [ "$CASE" = unlink ] || [ "$CASE" = truncate ] || [ -n "$GEOM" ] || [ "$CASE" = inoreuse ]; then
	# file 1's copies stay in the journal only: never checkpointed
	small_tx=$(cat $P/tau_cp_small_tx); tx_age=$(cat $P/tau_max_transaction_age)
	echo 0 | sudo tee $P/tau_cp_small_tx >/dev/null
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
fi
case "$CASE" in reuse|unlink|truncate|cpappend|inoreuse|mapappend|logappend)	# file 1 journaled, not written home
	home=$(cat $P/tau_home 2>/dev/null || echo 1); tau_home 0 ;;
esac
sudo sh -c "echo 0 > $P/tau_probe_seg_reuse_flush" 2>/dev/null
sudo sh -c "echo 0 > $P/tau_probe_seg_reused" 2>/dev/null
sudo sh -c "echo 0 > $P/tau_probe_maplog_wait" 2>/dev/null
sudo sh -c "echo 0 > $P/tau_probe_maplog_snapshot" 2>/dev/null
sudo sh -c "echo 0 > $P/tau_probe_jwrite_record; echo 0 > $P/tau_probe_record_noflush" 2>/dev/null
MNT_DEV=/dev/mapper/fo
TAU_DEV=$MNT_DEV mkfs_mount "$FS"

cat > /tmp/fo-work.py <<'EOF'
import os, struct, subprocess, sys, time
path, case, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
gap = float(sys.argv[4]) if case in ('cpappend', 'cpsub', 'fscpover', 'maplog', 'logappend') else 0
sync = os.fsync if case.startswith('fs') else os.fdatasync
pre = case == 'fsoverwrite'
grow = case == 'mapappend'
fan = 4 if case == 'logappend' else 1	# files appended at once a round
case = {'cpappend': 'append', 'cpsub': 'subappend', 'fsoverwrite': 'overwrite',
        'fscpover': 'overwrite', 'fsmapsplit': 'mapsplit', 'mapappend': 'mapsplit',
        'logappend': 'maplog'}.get(case, case)
def mark(name):
    subprocess.run(['dmsetup', 'message', 'fo', '0', 'mark', name], check=True)
def ready():		# the map blocks the setup wrote are not the run's
    try:
        with open('/sys/module/tau_journal/parameters/tau_probe_maplog_snapshot', 'w') as f:
            f.write('0')
    except OSError:
        pass
    mark('ready')
def page(k, v):
    return struct.pack('<II', k, v) * 1024
if case == 'mapsplit':
    def blk(k, tag):
        return struct.pack('<II', k, tag) * 512
    # written without tau first: the setup only overwrites, so no record waits
    # on a host epoch; the big write's does in fsmapsplit and mapappend
    for name, n_, tag in [(path, 256 if grow else 2048, 0xE0)] + [('%s.f%03d' % (path, i), 1, 0xE1) for i in range(1, 255)]:
        with open(name, 'wb') as f:
            f.write(b''.join(blk(k, tag) for k in range(n_)))
            f.flush()
            os.fsync(f.fileno())
    fd = os.open(path, os.O_RDWR | 0o40000000)
    for k in range(3):		# entry 0, most of it left
        os.pwrite(fd, blk(k, 0xA1), k * 4096)
        os.fdatasync(fd)
    for i in range(1, 255):	# entries 1-254
        g = os.open('%s.f%03d' % (path, i), os.O_RDWR | 0o40000000)
        os.pwrite(g, blk(0, 0xA2), 0)
        os.fdatasync(g)
        os.close(g)
    os.sync()
    ready()
    # past the rest of entry 0 and one more segment: entries 255 and 256
    os.pwrite(fd, b''.join(blk(k, 0xB2) for k in range(256, 1356)), 256 * 4096)
    sync(fd)
    mark('fsync-1')
    mark('end')
    os.close(fd)
    sys.exit()
if case == 'maplog':
    import threading
    def blk(k, tag):
        return struct.pack('<II', k, tag) * 512
    names = ['%s.f%03d' % (path, i) for i in range(255 + n * fan)]
    for name in names:		# not tau first: no record waits on a host epoch
        with open(name, 'wb') as f:
            f.write(blk(0, 0xE1))
            f.flush()
            os.fsync(f.fileno())
    def rewrite(name, tag):
        g = os.open(name, os.O_RDWR | 0o40000000)
        os.pwrite(g, blk(0, tag), 0)
        os.fdatasync(g)
        os.close(g)
    errs = []
    def append(name, tag):	# allocating: its record goes without a flush
        try:
            g = os.open(name, os.O_RDWR | 0o40000000)
            os.pwrite(g, blk(1, tag), 4096)
            os.fdatasync(g)
            os.close(g)
        except OSError as e:
            errs.append(e)
    for name in names[:255]:	# entries 0-254
        rewrite(name, 0xA2)
    os.sync()
    ready()
    for k in range(1, n + 1):	# one new segment each, from entry 255
        if fan == 1:
            rewrite(names[254 + k], 0xA3)
        else:		# the commits overlap: a full log waits for their claims
            ts = [threading.Thread(target=append, args=(names[255 + (k - 1) * fan + t], 0xA3))
                  for t in range(fan)]
            for t in ts:
                t.start()
            for t in ts:
                t.join()
            if errs:
                raise errs[0]
        mark('fsync-%d' % k)
        if k > n // 2:
            time.sleep(gap)	# journald's round writes the map blocks
    mark('end')
    sys.exit()
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
ready()
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
if case == 'inoreuse':
    import time
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    for k in range(1, 21):
        os.pwrite(fd, blk(k, 0xF1, 131072), (k - 1) * 131072)
        sync(fd)
    ino = os.fstat(fd).st_ino
    os.close(fd)
    mark('f1-done')
    os.unlink(path)		# evicted here: its txs stay in its segment
    time.sleep(2)		# XFS frees the inode in the background
    fd2 = os.open(path + '2', os.O_RDWR | os.O_CREAT | os.O_EXCL | 0o40000000, 0o644)
    with open('/tmp/fo-inoreuse', 'w') as f:
        f.write('%d %d\n' % (ino, os.fstat(fd2).st_ino))
    for k in range(1, n + 1):	# the same shape: its txs line up with file 1's
        os.pwrite(fd2, blk(k, 0xF2, 131072), (k - 1) * 131072)
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
if [ "$GEOM" = split ]; then
	# the disk map after the big write: the tau superblock (jbd2 magic, a 2 MiB
	# segment size), the two map blocks after it, and the map log's blocks past
	# its base, if there is a log
	split=$(sudo python3 - "$MNT_DEV" "$(stat -c %i "$F")" <<'EOF'
import struct, sys
dev, ino = sys.argv[1], int(sys.argv[2])
f = open(dev, 'rb')
pos, sb = 0, None
while sb is None:
    buf = f.read(64 << 20)
    if not buf:
        break
    for off in range(0, len(buf), 4096):
        if buf[off:off + 4] == b'\xc0\x3b\x39\x98' and \
           struct.unpack('>I', buf[off + 0x5c:off + 0x60])[0] == 2 << 20:
            sb = pos + off
            break
    pos += len(buf)
if sb is None:
    print('no tau superblock found'); sys.exit()
f.seek(sb)
lpba, lbase, llen = struct.unpack('>QQI', f.read(4096)[0x60:0x74])
f.seek(sb + 4096)
m = f.read(8192)
own = [struct.unpack('>QQ', m[e * 16:e * 16 + 16])[1] for e in range(512)]
log = []
for i in range(llen if lpba else 0):
    f.seek((lpba + i) * 4096)
    b = f.read(4096)
    magic, kind_, seq = struct.unpack('>IIQ', b[:16])
    if magic == 0xc03b3998 and kind_ == 6 and seq > lbase:
        log.append((seq, b))
for seq, b in sorted(log):
    kind, nr = struct.unpack('>HH', b[20:24])
    for k in range(nr):
        idx, _, pba, eino = struct.unpack('>IIQQ', b[32 + k * 24:56 + k * 24])
        if idx < 512:
            own[idx] = eino if kind == 1 else 0
print('entries 0-254 owned %d, 255 %s, 256 %s' % (sum(1 for o in own[:255] if o),
      'file 1' if own[255] == ino else own[255], 'file 1' if own[256] == ino else own[256]))
EOF
)
	echo "== mapsplit: $split =="
fi
reuse_wait=$(cat $P/tau_probe_seg_reuse_flush 2>/dev/null)
# before the map log a reuse always waited for its free
reused=$(cat $P/tau_probe_seg_reused 2>/dev/null || echo "$reuse_wait")
snaps=$(cat $P/tau_probe_maplog_snapshot 2>/dev/null)
mlwait=$(cat $P/tau_probe_maplog_wait 2>/dev/null)
records=$(cat $P/tau_probe_jwrite_record 2>/dev/null)
noflush=$(cat $P/tau_probe_record_noflush 2>/dev/null)
sudo umount "$TAU_MNT"
sudo dmsetup remove fo || die "dmsetup remove"
echo 0 | sudo tee $P/tau_record_fua_only >/dev/null
[ -e $P/tau_segmap_fua_only ] && echo 0 | sudo tee $P/tau_segmap_fua_only >/dev/null
[ -e $P/tau_reuse_flush_only ] && echo 0 | sudo tee $P/tau_reuse_flush_only >/dev/null
[ -e $P/tau_claim_flush ] && echo 0 | sudo tee $P/tau_claim_flush >/dev/null
[ -e $P/tau_dead_nogate ] && echo 0 | sudo tee $P/tau_dead_nogate >/dev/null
[ -e $P/tau_free_uncond ] && echo 0 | sudo tee $P/tau_free_uncond $P/tau_free_nohold >/dev/null
[ -e $P/tau_noflush_old_epoch ] && echo 0 | sudo tee $P/tau_noflush_old_epoch $P/tau_noflush_nomark >/dev/null
[ -e $P/tau_fsync_noinode ] && echo 0 | sudo tee $P/tau_fsync_noinode >/dev/null
if [ -e $P/tau_maplog_len ]; then
	echo 0 | sudo tee $P/tau_maplog_split $P/tau_maplog_early_base >/dev/null
	echo "$mllen" | sudo tee $P/tau_maplog_len >/dev/null
fi
case "$CASE" in reuse|unlink|truncate|cpappend|inoreuse|mapappend|logappend) tau_home "$home" ;; esac
if [ "$CASE" = unlink ] || [ "$CASE" = truncate ] || [ -n "$GEOM" ] || [ "$CASE" = inoreuse ]; then
	echo "$small_tx" | sudo tee $P/tau_cp_small_tx >/dev/null
	echo "$tx_age" | sudo tee $P/tau_max_transaction_age >/dev/null
fi
if [ "$GEOM" = split ]; then
	case "$split" in
	*"255 file 1, 256 file 1"*) ;;
	*)	echo "RESULT: INCONCLUSIVE (the big write did not take entries 255 and 256)"
		cleanup
		exit 3 ;;
	esac
fi
case "$CASE" in fsmapsplit|mapappend)
	if [ "${noflush:-0}" -lt 1 ]; then
		echo "RESULT: INCONCLUSIVE (the big write's record went with a flush)"
		cleanup
		exit 3
	fi ;;
esac
if [ "$CASE" = inoreuse ]; then
	read -r ino1 ino2 < /tmp/fo-inoreuse
	echo "== inoreuse: file 1 was ino $ino1, file 2 is ino $ino2 =="
	if [ "$ino1" != "$ino2" ]; then
		echo "RESULT: INCONCLUSIVE (file 2 did not get file 1's ino)"
		cleanup
		exit 3
	fi
fi
if [ "$GEOM" = log ]; then
	echo "== $CASE: map blocks written in the run: ${snaps:-?}, commits that waited for them: ${mlwait:-?} =="
	if [ "${snaps:-0}" -lt 2 ]; then
		echo "RESULT: INCONCLUSIVE (the run wrote the map blocks fewer than twice)"
		cleanup
		exit 3
	fi
	if [ "$CASE" = logappend ] && [ "${noflush:-0}" -lt $((N * 4)) ]; then
		echo "RESULT: INCONCLUSIVE (${noflush:-?} records without a flush, the run's appends $((N * 4)))"
		cleanup
		exit 3
	fi
fi
if [ "$CASE" = reuse ]; then
	echo "$small_tx" | sudo tee $P/tau_cp_small_tx >/dev/null
	echo "$tx_age" | sudo tee $P/tau_max_transaction_age >/dev/null
	echo "== reuse: freed segments given out again: ${reused:-?}, of them waiting for their free: ${reuse_wait:-?}, map blocks written in the run: ${snaps:-?} =="
	if [ "${reused:-0}" = 0 ]; then
		echo "RESULT: INCONCLUSIVE (no freed segment was reused)"
		cleanup
		exit 3
	fi
fi
echo "== $FS $CASE: $N fsyncs logged${RECORD_FUA_ONLY:+ (control: records FUA only)}${SEGMAP_FUA_ONLY:+ (control: segment map FUA only)}${REUSE_FLUSH_ONLY:+ (control: reuse without the map write)}${DEAD_NOGATE:+ (control: dead segments back at once)}${FREE_UNCOND:+ (control: unconditional free tags)}${FREE_NOHOLD:+ (control: free not held)}${NOFLUSH_OLD_EPOCH:+ (control: allocation epoch on records without a flush)}${NOFLUSH_NOMARK:+ (control: iclog not marked)}${GATE_TAIL:+ (control: recovery takes the tail of a refused record)}${GATE_FLOOR:+ (control: a refused orphan sets a floor)}${FSYNC_NOINODE:+ (control: fsync(2) without the inode)}${MAPLOG_SPLIT:+ (control: claims split over log blocks)}${MAPLOG_EARLY_BASE:+ (control: the base before the map blocks)}${SERIAL_IGNORE:+ (control: files of one ino not told apart)} =="
echo "== records: ${records:-?}, of them without a flush: ${noflush:-?} =="
# recovery-side controls: the mounts below recover the rebuilt disks
[ -e $P/tau_gate_tail ] && echo "${GATE_TAIL:-0}" | sudo tee $P/tau_gate_tail >/dev/null
[ -e $P/tau_gate_floor ] && echo "${GATE_FLOOR:-0}" | sudo tee $P/tau_gate_floor >/dev/null
[ -e $P/tau_serial_ignore ] && echo "${SERIAL_IGNORE:-0}" | sudo tee $P/tau_serial_ignore >/dev/null

# check one rebuilt disk: mount it (tau recovery runs) and judge the file
cat > /tmp/fo-check.sh <<EOF
#!/bin/bash
dev=\$(losetup -f --show "$W/scratch.img") || exit 3
n0=\$(dmesg | wc -l)
if ! mount -t $FS -o "${TAU_MOUNT_OPTS:-tjournal}" \$dev "$TAU_MNT" 2>/dev/null; then
	losetup -d \$dev; echo "MOUNT-FAILED"; exit 0
fi
python3 /tmp/fo-judge.py "$F" "$CASE" "$N" "\$1"
[ "$GEOM" = split ] && dmesg | tail -n +\$((n0 + 1)) |
	grep -m3 -E 'orphan commit|not in the journal|checkpointed through' | sed 's/^/    /'
umount "$TAU_MNT"; losetup -d \$dev
EOF
chmod +x /tmp/fo-check.sh

cat > /tmp/fo-judge.py <<'EOF'
import struct, sys
path, case, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
grow = case == 'mapappend'
fan = 4 if case == 'logappend' else 1
case = {'cpappend': 'append', 'cpsub': 'subappend', 'fsoverwrite': 'overwrite',
        'fscpover': 'overwrite', 'fsmapsplit': 'mapsplit', 'mapappend': 'mapsplit',
        'logappend': 'maplog'}.get(case, case)
durable, f1done = (int(x) for x in sys.argv[4].split(':'))
def page(k, v):
    return struct.pack('<II', k, v) * 1024
if case == 'mapsplit':
    def blk(k, tag):
        return struct.pack('<II', k, tag) * 512
    try:
        d = open(path, 'rb').read()
    except FileNotFoundError:
        print("BAD file 1 missing"); sys.exit()
    nb = len(d) // 4096		# mapappend: the append there or not
    if len(d) % 4096 or nb not in ((256, 1356) if grow else (2048,)):
        print("BAD file 1: size %d" % len(d)); sys.exit()
    b = lambda k: d[k * 4096:(k + 1) * 4096]
    big = range(256, min(nb, 1356))
    lost = [k for k in range(3) if b(k) != blk(k, 0xA1)]
    new = sum(b(k) == blk(k, 0xB2) for k in big)
    old = 0 if grow else sum(b(k) == blk(k, 0xE0) for k in big)
    rest = [k for k in list(range(3, 256)) + list(range(1356, nb)) if b(k) != blk(k, 0xE0)]
    small = [i for i in range(1, 255)
             if open('%s.f%03d' % (path, i), 'rb').read() != blk(0, 0xA2)]
    if lost:
        print("BAD file 1: the fsync'd page writes %s before the big write are gone" % lost)
    elif new + old != len(big) or (new and old):
        print("BAD the big write torn: %d of %d blocks new, %d old" % (new, len(big), old))
    elif durable and not new:
        print("BAD the big write's fsync returned and it is not there")
    elif rest or small:
        print("BAD other blocks changed: file 1 %s, small files %s" % (rest[:8], small[:8]))
    else:
        print("OK the big write %s (durable %d)" % ("there" if new else "not there", durable))
    sys.exit()
if case == 'maplog':
    def blk(k, tag):
        return struct.pack('<II', k, tag) * 512
    def read(i):
        try:
            return open('%s.f%03d' % (path, i), 'rb').read()
        except FileNotFoundError:
            return b''
    # logappend: a block appended to each of fan files a round
    new = blk(0, 0xE1) + blk(1, 0xA3) if fan > 1 else blk(0, 0xA3)
    what = 'appends' if fan > 1 else 'rewrites'
    before = [i for i in range(255) if read(i) != blk(0, 0xA2)]
    m, wrong, lost = 0, [], []
    for k in range(1, n + 1):
        for t in range(fan):
            i = 255 + (k - 1) * fan + t
            d = read(i)
            if d == new:
                m += 1
            elif d != blk(0, 0xE1):
                wrong.append(i)
            elif k <= durable:
                lost.append(i)
    if before:
        print("BAD %d of the 255 rewrites before the run gone: files %s" % (len(before), before[:8]))
    elif wrong:
        print("BAD %s to files %s neither old nor new" % (what, wrong[:8]))
    elif lost:
        print("BAD fsync'd %s to files %s gone (durable %d)" % (what, lost[:8], durable))
    else:
        print("OK %d of %d %s there (durable %d)" % (m, n * fan, what, durable))
    sys.exit()
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
if case == 'inoreuse':
    def blk(k, tag, size):
        return struct.pack('<II', k, tag) * (size // 8)
    def whole(data, tag, size):
        m = len(data) // size
        bad = [i + 1 for i in range(m) if data[i*size:(i+1)*size] != blk(i + 1, tag, size)]
        return m, len(data) % size == 0 and not bad, bad
    def read(p):
        try:
            return open(p, 'rb').read()
        except FileNotFoundError:
            return None
    d1, d2 = read(path), read(path + '2')
    if d1 is None:
        if not f1done:
            print("BAD file 1 missing before its unlink"); sys.exit()
        m1 = -1
    else:
        m1, ok1, bad1 = whole(d1, 0xF1, 131072)
        if not ok1 or (f1done and m1 != 20):
            print("BAD file 1 back: size %d, writes %s wrong" % (len(d1), bad1)); sys.exit()
    m2 = 0
    if d2 is not None:
        m2, ok2, bad2 = whole(d2, 0xF2, 131072)
        if not ok2:
            foreign = [i for i in bad2 if struct.pack('<I', 0xF1) in d2[(i-1)*131072:i*131072]]
            print("BAD file 2: size %d, writes %s wrong%s" % (len(d2), bad2,
                  ", %s hold file 1's data" % foreign if foreign else "")); sys.exit()
    if m2 < durable:
        print("BAD file 2: %d of %d fsync'd writes there" % (m2, durable))
    else:
        print("OK file 1 %s, file 2 %d writes (durable %d)" %
              ("gone" if m1 < 0 else "%d" % m1, m2, durable))
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
sudo python3 - "$LOG" "$W/replay.img" "$W/scratch.img" "$DROP" <<'EOF'
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
badat = {'run': 0, 'umount': 0}
DROP = sys.argv[4] == '1'
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
                badat[state] += 1
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
        badat[state] += 1
        if bad <= 5:
            kind = 'mark' if flags & MARK else ('FUA' if flags & FUA else 'flush')
            print("  entry %d (%s, %s), %d fsyncs returned: %s" % (i, kind, state, durable, out))
print("  %d crash states checked (%d in the run, %d during the unmount): %s" %
      (checks, phase['run'], phase['umount'], ", ".join("%s %d" % kv for kv in sorted(seen.items()))))
if DROP:
    print("  %d single-drop states: %s" % (dchecks, ", ".join("%s %d" % kv for kv in sorted(dseen.items()))))
if bad or dbad:
    print("  BAD states: %d in the run, %d during the unmount" % (badat['run'], badat['umount']))
ok = checks and not bad and not dbad
print("RESULT: %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
EOF
rc=$?
[ -e $P/tau_gate_tail ] && echo 0 | sudo tee $P/tau_gate_tail $P/tau_gate_floor >/dev/null
[ -e $P/tau_serial_ignore ] && echo 0 | sudo tee $P/tau_serial_ignore >/dev/null
# FO_KEEP=1 keeps the log for a look at the entries a failure names
[ "${FO_KEEP:-0}" = 1 ] && sudo cp --sparse=always "$W/log.img" /dev/shm/fo-keep-log.img
cleanup
exit $rc
