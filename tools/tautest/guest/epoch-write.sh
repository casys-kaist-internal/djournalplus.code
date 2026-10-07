#!/bin/bash
# Arm one host-ordering case (README) and power-cut inside the commit.
#   usage: epoch-write.sh <xfs|ext4> <case> [hold-s]
#
# The host metadata an allocating commit depends on must not reach the disk
# before the tau record (ext4: the jbd2 tx is held in its finish hook), and one
# commit's allocations must land in one host transaction (#49, #50):
#
#   convert  write into a fallocate'd extent (pass 1 converts it on ext4).  A
#            delay after pass 1, a host log force from another file during it,
#            then the power cut.  The conversion must not be durable without
#            the record: the extent reads as zero, never as the salt.
#   split    two delalloc runs in one commit.  A delay between the runs with a
#            host log force during it, so the second run would land in the next
#            jbd2 tx, then a delay after the record.  After the cut the commit
#            is replayed whole or not at all, and no block shows the salt.
#   gate     one write over a durable block and two new ones; the cut comes
#            after the record, before the host commits the allocation.  The
#            recovery gate must refuse the commit (#51: jbd2 recovery leaves
#            j_commit_sequence one past the last committed tid).  On XFS this
#            is #44 until recovery re-publishes the conversion.
#   publish  gate, with another file's fsync during the delay: the allocation
#            is durable, the conversion is not (XFS #44: recovery rolls the tx
#            back; ext4: the jbd2 tx commits whole).
#   partial  XFS: holes at blocks 4 and 8 of a 64 KiB file, one tx writing
#            blocks 3-4 and 8; the cut comes between the two conversions of
#            pass 2, after another file's fsync made the first durable.  The tx
#            is rolled back and the block converted without its data is zeroed.
# Size only (no allocation: the EOF moves inside the written last block, #45):
#   append         100 B + fsync, 100 B appended + fsync, cut: size 200
#   append-umount  the same, then a clean umount + mount before the cut
#   append-torn    50 B at offset 80 of a 100 B file (20 overwrite, 30 append),
#                  no fsync, cut after the record: all old or all new
#   isize          the commit of an append is held after its record while the
#                  next append grows the same block, then the first commit
#                  finishes and the power is cut: the size is the first one's
#                  (#46: not the live i_size, which would show zeros)
# An append into the TauRedo block EOF sits in (design.md §20.3, bug.md #52).
# F = 4 KiB of A + 100 B of B, a clean remount, 10 B of b over block 1 + fsync
# with tau_cp_small_tx 0: block 1 stays TauRedo, block 0 is no longer tau's.
#   undo-bg      100 B appended in block 1, block 0 overwritten, no fsync; the
#                background commit (it takes no revoke tags) runs, then the cut:
#                the append whole or not at all
#   undo-wb      100 B appended in block 1, block 1 written back by plain
#                writeback (sync_file_range WRITE), another file's fsync, cut
#   undo-sparse  10 B rewritten in block 1, a block written past EOF, block 1
#                written back, another file's fsync, cut: the size stays put
#
# Free space is salted with 0xEE first, so a block made visible without its
# data shows it.  WARNING: runs mkfs on $TAU_DEV.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
CASE=${2:-}
HOLD=${3:-120}
STATUS_FILE=${STATUS_FILE:-$HOME/epoch-status}
DELAY_MS=${DELAY_MS:-15000}
P=/sys/module/tau_journal/parameters
F=$TAU_MNT/epoch

case "$CASE" in
convert|split|gate|publish|partial|append|append-umount|append-torn|isize) ;;
undo-bg|undo-wb|undo-sparse) ;;
*) die "usage: $0 <xfs|ext4> <case> [hold-seconds]" ;;
esac
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> <case> [hold-seconds]"
[ -r "$P/tau_inject_delay" ] ||
	die "no tau_inject_delay: this test needs CONFIG_TAU_PROBE_TORN=y"

rm -f "$STATUS_FILE"
status() { echo "$*" > "$STATUS_FILE"; sync "$STATUS_FILE" 2>/dev/null; echo "== $* =="; }
inconclusive() { setparam tau_inject_delay 0; status "INCONCLUSIVE $*"; exit 0; }
setparam() { echo "$2" | sudo tee "$P/$1" >/dev/null || die "cannot set $1"; }

# wait_delay <site> <seconds>: the commit sleeps at <site>
wait_delay() {
	local i
	for i in $(seq 1 $(($2 * 5))); do
		sudo dmesg | grep -q "injected delay at site $1," && return 0
		sleep 0.2
	done
	return 1
}

# F = 100 B of A, fsync'd, then a clean remount: the block is no longer tau's,
# so the next write to it is journaled, not written in place
setup_a100() {
	sudo python3 - "$F" <<-'EOF' || die "setup failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
		os.pwrite(fd, b"A" * 100, 0)
		os.fsync(fd)
		os.close(fd)
	EOF
	sudo umount "$TAU_MNT" || die "umount failed"
	mount_tau "$FS"
	sudo dmesg -C
}

# F = 4 KiB of A + 100 B of B, a clean remount, then 10 B of b over block 1 +
# fsync: block 1 (EOF inside) is TauRedo, block 0 is not tau's.  A tx under
# tau_cp_small_tx blocks is checkpointed at once, which would make block 1
# clean again: keep it.
setup_undo() {
	sudo python3 - "$F" <<-'EOF' || die "setup failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
		os.pwrite(fd, b"A" * 4096 + b"B" * 100, 0)
		os.fsync(fd)
		os.close(fd)
	EOF
	sudo umount "$TAU_MNT" || die "umount failed"
	mount_tau "$FS"
	setparam tau_cp_small_tx 0
	sudo python3 - "$F" <<-'EOF' || die "setup failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, b"b" * 10, 4096)
		os.fsync(fd)
		os.close(fd)
	EOF
	sudo dmesg -C
}

# a plain file's fsync: forces the host log (jbd2 commit / XFS log force)
logforce() {
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x")
os.fsync(fd)
os.close(fd)' "$TAU_MNT/logforce-$1"
}

[ "$CASE" = partial ] && [ "$FS" != xfs ] &&
	{ status "INCONCLUSIVE ext4 has no pass 2"; exit 0; }

# 4 GB, and salted to ENOSPC: whatever the allocator hands out holds 0xEE
export TAU_FS_SIZE=${TAU_FS_SIZE:-4g}
# ext4: no timed jbd2 commit inside the window
[ "$FS" = ext4 ] && export TAU_MOUNT_OPTS=${TAU_MOUNT_OPTS:-tjournal,commit=600}
echo "== preparing $FS (fs size $TAU_FS_SIZE, mount ${TAU_MOUNT_OPTS:-tjournal}) =="
mkfs_mount "$FS"
sudo python3 - "$TAU_MNT/salt" <<-'EOF'
	import sys
	buf = bytes([0xEE]) * (1 << 20)
	n = 0
	try:
	    with open(sys.argv[1], "wb") as f:
	        while True:
	            f.write(buf)
	            n += 1
	except OSError:
	    pass
	print("  salted %d MB" % n)
EOF
sync
sudo rm -f "$TAU_MNT/salt"
sync

setparam tau_inject_delay_ms "$DELAY_MS"
sudo dmesg -C

case "$CASE" in
convert)
	sudo fallocate -l $((1 * MB)) "$F" || die "fallocate"
	sync
	setparam tau_inject_delay $((1 << 2))	# TAU_DELAY_MAPPED
	sudo python3 - "$F" <<-'EOF' || die "write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, bytes([0x43]) * 8192, 0)
		os.close(fd)
	EOF
	echo "== 8 KiB of 0x43 into the unwritten extent, no fsync; waiting for the commit =="
	wait_delay 2 20 || inconclusive "no allocating commit reached the delay"
	echo "== in the commit after pass 1: forcing the host log =="
	logforce 1 &
	sleep 2
	;;
split)
	setparam tau_inject_delay $(((1 << 1) | (1 << 3)))	# MAP_RUN, RECORDED
	sudo python3 - "$F" <<-'EOF' || die "write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
		os.pwrite(fd, bytes([0x41]) * 4096, 0)
		os.pwrite(fd, bytes([0x42]) * 4096, 16 * 4096)
		os.close(fd)
	EOF
	echo "== blocks 0 and 16 written (two delalloc runs), no fsync; waiting for the commit =="
	wait_delay 1 20 || inconclusive "pass 1 never reached a second run"
	echo "== between the runs: forcing the host log =="
	logforce 1 &
	wait_delay 3 $((DELAY_MS / 1000 + 20)) ||
		inconclusive "the commit never reached the record"
	echo "== record durable: waiting for the forced host commit =="
	for i in $(seq 1 25); do
		jobs -r | grep -q . || break
		sleep 0.2
	done
	jobs -r | grep -q . && echo "  (the host log force has not returned)"
	;;
gate|publish)
	sudo python3 - "$F" <<-'EOF' || die "setup write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
		os.pwrite(fd, bytes([0x30]) * 8192, 0)
		os.fsync(fd)
		os.close(fd)
	EOF
	setparam tau_inject_delay $((1 << 3))	# RECORDED
	sudo python3 - "$F" <<-'EOF' || die "write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, bytes([0x44]) * 12288, 4096)
		os.close(fd)
	EOF
	echo "== blocks 0-1 fsync'd; 12 KiB of 0x44 over block 1 and new 2-3, no fsync =="
	wait_delay 3 20 || inconclusive "the commit never reached the record"
	if [ "$CASE" = publish ]; then
		echo "== after the record: forcing the host log =="
		logforce 1 &
		sleep 2
	fi
	;;
append|append-umount)
	setup_a100
	sudo python3 - "$F" <<-'EOF' || die "write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, b"B" * 100, 100)
		os.fsync(fd)
		os.close(fd)
	EOF
	echo "== 100 B + fsync, 100 B appended + fsync: size $(stat -c %s "$F") =="
	if [ "$CASE" = append-umount ]; then
		sudo umount "$TAU_MNT" || die "umount failed"
		mount_tau "$FS"
		echo "== after a clean umount + mount: size $(stat -c %s "$F") =="
	fi
	;;
append-torn)
	setup_a100
	setparam tau_inject_delay $((1 << 3))	# RECORDED
	sudo python3 - "$F" <<-'EOF' || die "write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, b"C" * 50, 80)
		os.close(fd)
	EOF
	echo "== 50 B at offset 80 (20 overwritten, 30 appended), no fsync =="
	wait_delay 3 20 || inconclusive "the commit never reached the record"
	;;
isize)
	setup_a100
	AGE=$(cat "$P/tau_max_commmit_age")
	setparam tau_max_commmit_age 600	# the second append must not commit
	setparam tau_inject_delay $((1 << 3))	# RECORDED
	sudo python3 - "$F" <<-'EOF' &
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, b"B" * 100, 100)
		os.fsync(fd)
		os.close(fd)
	EOF
	wait_delay 3 20 || { setparam tau_max_commmit_age "$AGE"; inconclusive "the fsync never reached the record"; }
	echo "== first append's commit held after its record: appending 100 B more =="
	sudo python3 - "$F" <<-'EOF' || die "second write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, b"C" * 100, 200)
		os.close(fd)
	EOF
	echo "== waiting for the first commit (its fsync) to finish =="
	wait
	echo "  size now $(stat -c %s "$F") (in memory)"
	sleep 1
	;;
undo-bg)
	setup_undo
	setparam tau_inject_delay_ms 1000
	setparam tau_inject_delay $((1 << 3))	# RECORDED
	sudo python3 - "$F" <<-'EOF' || die "write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, b"C" * 100, 4196)
		os.pwrite(fd, b"D" * 4096, 0)
		os.close(fd)
	EOF
	echo "== 100 B appended in block 1, block 0 overwritten, no fsync; waiting for the background commit =="
	wait_delay 3 20 || inconclusive "no background commit reached the record"
	sleep 3		# it forces the host log and finishes
	echo "  size now $(stat -c %s "$F") (in memory)"
	;;
undo-wb|undo-sparse)
	setup_undo
	# undo-sparse: the write past EOF must not commit before the cut
	[ "$CASE" = undo-sparse ] && setparam tau_max_commmit_age 600
	sudo python3 - "$F" "$CASE" <<-'EOF' || die "write failed"
		import ctypes, os, sys
		libc = ctypes.CDLL("libc.so.6", use_errno=True)
		libc.sync_file_range.argtypes = [ctypes.c_int, ctypes.c_long,
						 ctypes.c_long, ctypes.c_uint]
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		if sys.argv[2] == "undo-wb":
		    os.pwrite(fd, b"C" * 100, 4196)
		else:
		    os.pwrite(fd, b"e" * 10, 4100)
		    os.pwrite(fd, b"S" * 4096, 3 * 4096)
		# WRITE alone is WB_SYNC_NONE: plain writeback, not a tau commit
		for flags in (2, 4):	# SYNC_FILE_RANGE_WRITE, then WAIT_AFTER
		    if libc.sync_file_range(fd, 4096, 4096, flags):
		        raise OSError(ctypes.get_errno(), "sync_file_range")
		os.close(fd)
	EOF
	echo "== block 1 written back in place, no fsync: size $(stat -c %s "$F"); forcing the host log =="
	logforce 1
	;;
partial)
	sudo python3 - "$F" <<-'EOF' || die "setup failed"
		import ctypes, os, sys
		libc = ctypes.CDLL("libc.so.6", use_errno=True)
		libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int,
					   ctypes.c_long, ctypes.c_long]
		fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | 0o40000000, 0o644)
		os.pwrite(fd, bytes([0x30]) * 65536, 0)
		os.fsync(fd)
		for off in (4 * 4096, 8 * 4096):	# PUNCH_HOLE | KEEP_SIZE
		    if libc.fallocate(fd, 3, off, 4096):
		        raise OSError(ctypes.get_errno(), "punch")
		os.fsync(fd)
		os.close(fd)
	EOF
	setparam tau_inject_delay $((1 << 4))	# PUBLISH_RUN
	sudo python3 - "$F" <<-'EOF' || die "write failed"
		import os, sys
		fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
		os.pwrite(fd, bytes([0x45]) * 8192, 3 * 4096)	# block 3 + hole 4
		os.pwrite(fd, bytes([0x46]) * 4096, 8 * 4096)	# hole 8
		os.close(fd)
	EOF
	echo "== blocks 3-4 and 8 written (holes 4, 8 new), no fsync; waiting for pass 2 =="
	wait_delay 4 20 || inconclusive "pass 2 never reached a second run"
	echo "== between the conversions: forcing the host log =="
	logforce 1 &
	sleep 2
	;;
esac

jobs -r | grep -q . && echo "  host log force still blocked" || echo "  host log force returned"
status ARMED
sleep "$HOLD"
echo "== hold expired =="
