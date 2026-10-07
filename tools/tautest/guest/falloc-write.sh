#!/bin/bash
# Lay out the fallocate/unwritten crash matrix.
#
# Writing into a fallocate'd (unwritten) extent is its own tau path: the blocks
# are already backed, so commit pass 1 has nothing to allocate and pass 2 does
# the unwritten->written conversion on its own (design doc §15).  On XFS that
# conversion now runs *after* the commit record is durable (§17); on ext4 it
# happens inside jcommit_map, ordered by the jbd2 finish-hook.  Either way two
# things must hold after a crash:
#
#   1. every fsync-acked byte comes back,
#   2. every byte of the fallocate'd range that was never written reads as
#      ZERO -- never as whatever the blocks held before.
#
# (2) is the reason this file first fills the device with a recognisable salt
# (0xEE) and deletes it: an unwritten extent handed out over those blocks and
# converted too early would show the salt.  Without the salt a fresh device
# reads zero anyway and the check proves nothing.
#
#   usage: falloc-write.sh <xfs|ext4>
#
# WARNING: runs mkfs on $TAU_DEV.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4>"
check_tools

# Format only part of the device: the salt below has to FILL the free space,
# otherwise the allocator just hands out untouched blocks and the stale-data
# check proves nothing (measured: on the full 327GB device the fallocate'd
# extents landed ~95GB in, nowhere near a 2GB salt file).
TAU_FS_SIZE=${TAU_FS_SIZE:-40g}
export TAU_FS_SIZE
SALT_CAP_MB=${SALT_CAP_MB:-16384}

echo "== preparing $FS on $TAU_DEV (fs size $TAU_FS_SIZE) =="
mkfs_mount "$FS"

D=$TAU_MNT

# Salt: plain (non-tau) writes, so this is ordinary data sitting in blocks the
# allocator is then free to hand back out.  Fill to ENOSPC on purpose -- that is
# what forces the fallocate'd extents below onto salted blocks.  0xEE never
# appears in any expected pattern.
echo "== salting free space with 0xEE (fill to ENOSPC, cap ${SALT_CAP_MB}MB) =="
sudo python3 - "$D/salt" "$SALT_CAP_MB" <<-'EOF'
	import sys
	buf = bytes([0xEE]) * (1 << 20)
	path, cap = sys.argv[1], int(sys.argv[2])
	n = 0
	try:
	    with open(path, "wb") as f:
	        while n < cap:
	            f.write(buf)
	            n += 1
	        f.flush()
	except OSError as e:
	    pass                       # ENOSPC is the goal
	print("  salted %d MB" % n)
EOF
sync
sudo rm -f "$D/salt"
sync
df -h "$D" | tail -1

sudo dmesg -C

echo "== writing fallocate matrix =="

# pA: fallocate, then write the whole range.  Plain full conversion.
sudo fallocate -l $((8 * MB)) "$D/pA" || die "fallocate pA"
sudo "$TAUWRITE" "$D/pA" $((8 * MB)) 101

# pB: fallocate, write only the head.  The tail must read as zeroes.
sudo fallocate -l $((8 * MB)) "$D/pB" || die "fallocate pB"
sudo "$TAUWRITE" "$D/pB" $((3 * MB)) 102

# pC: unaligned partial write inside an unwritten extent.  iomap zero-fills the
#     rest of the folio rather than reading the physical block, so the result
#     must be zeroes on both sides of the data (§15).
sudo fallocate -l $((8 * MB)) "$D/pC" || die "fallocate pC"
sudo "$TAUWRITE" "$D/pC" 5000 103 512

# pD: convert, then overwrite part of it.  Exercises the revoke path over an
#     extent that pass 2 had already made written.
sudo fallocate -l $((8 * MB)) "$D/pD" || die "fallocate pD"
sudo "$TAUWRITE" "$D/pD" $((8 * MB)) 104
sudo "$TAUWRITE" "$D/pD" $((2 * MB)) 105

# pE: mixed transaction -- a fallocate'd (unwritten) region and a hole that
#     needs a real delalloc allocation, both written before a SINGLE fsync so
#     they land in one commit.  That is the case where the epoch has to cover
#     the fallocate and the fresh allocation at once; two tauwrite runs would
#     make two transactions and miss it.
sudo fallocate -l $((4 * MB)) "$D/pE" || die "fallocate pE"
sudo truncate -s $((12 * MB)) "$D/pE"
sudo python3 - "$D/pE" <<-'EOF' || die "pE write failed"
	import os, sys
	MB = 1024 * 1024
	O_TAU_UNTORN = 0o40000000
	fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | O_TAU_UNTORN, 0o644)
	os.pwrite(fd, bytes([106]) * 2 * MB, 0)          # into the unwritten extent
	os.pwrite(fd, bytes([107]) * 2 * MB, 8 * MB)     # into the hole -> delalloc
	os.fsync(fd)
	os.close(fd)
	print("OK pE mixed unwritten+delalloc, one fsync")
EOF

# pF: large fallocate spanning several journal segments, half written.
sudo fallocate -l $((300 * MB)) "$D/pF" || die "fallocate pF"
sudo "$TAUWRITE" "$D/pF" $((150 * MB)) 108

# pG: never fsynced.  Content is not predictable, but it must not contain the
#     salt: an unwritten extent must never publish stale blocks.
sudo fallocate -l $((8 * MB)) "$D/pG" || die "fallocate pG"
sudo "$TAUWRITE_NOFSYNC" "$D/pG" $((3 * MB)) 109

# pressure: push the journal into checkpointing so segments recycle underneath
# everything above.
for i in 1 2; do
	sudo "$TAUWRITE" "$D/big$i" $((120 * MB)) $((50 + i))
done

echo "== matrix ready =="
echo "Now crash the VM, reboot, and run: falloc-verify.sh $FS"
