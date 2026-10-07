#!/bin/bash
# Shared settings and helpers for the guest-side tau tests.
# Source this, do not execute it.

set -u

# --- knobs (override from the environment) ----------------------------------
TAU_DEV=${TAU_DEV:-/dev/nvme0n1}
TAU_MNT=${TAU_MNT:-/mnt/test}
TAU_BIN=${TAU_BIN:-$HOME/tautest}
TAU_SRCTREE=${TAU_SRCTREE:-$HOME/djournalplus.code}

# Patched mkfs binaries. Stock mkfs cannot create the tau journal.
MKFS_XFS=${MKFS_XFS:-$TAU_SRCTREE/xfsprogs-dev/mkfs/mkfs.xfs}
MKE2FS=${MKE2FS:-$TAU_SRCTREE/e2fsprogs/misc/mke2fs}

TAUWRITE=$TAU_BIN/tauwrite
TAUWRITE_NOFSYNC=$TAU_BIN/tauwrite_nofsync
TAURACE=$TAU_BIN/taurace

MB=$((1024 * 1024))

die() { echo "ERROR: $*" >&2; exit 1; }

check_tools() {
	for b in "$TAUWRITE" "$TAUWRITE_NOFSYNC" "$TAURACE"; do
		[ -x "$b" ] || die "missing $b (build with tools/tautest/Makefile)"
	done
}

# mkfs_mount <xfs|ext4>
mkfs_mount() {
	local fs=$1
	local tries=0

	sudo umount "$TAU_MNT" 2>/dev/null || true
	# mke2fs on a still-mounted device fails with a message that reads like a
	# tool problem; wait for whoever is holding it to let go, then say so.
	while mount | grep -q " $TAU_MNT "; do
		tries=$((tries + 1))
		[ "$tries" -gt 10 ] && die "$TAU_MNT is still mounted; something is holding it"
		sleep 2
		sudo umount "$TAU_MNT" 2>/dev/null || true
	done
	case "$fs" in
	xfs)
		[ -x "$MKFS_XFS" ] || die "missing patched mkfs.xfs at $MKFS_XFS"
		# TAU_MKFS_XFS_OPTS exists because the journal segment size is an
		# on-disk parameter: mkfs defaults to 128MB (proto.c) and must be
		# told to match the kernel's TAU_SEGMENT_SIZE when that changes.
		# TAU_FS_SIZE formats only part of the device (e.g. "40g"), which is
		# how a test gets free space small enough to fill on purpose.
		sudo "$MKFS_XFS" -f ${TAU_FS_SIZE:+-d size=$TAU_FS_SIZE} \
			${TAU_MKFS_XFS_OPTS:-} "$TAU_DEV" >/dev/null 2>&1 ||
			die "mkfs.xfs ${TAU_FS_SIZE:+-d size=$TAU_FS_SIZE} ${TAU_MKFS_XFS_OPTS:-} failed"
		;;
	ext4)
		[ -x "$MKE2FS" ] || die "missing patched mke2fs at $MKE2FS"
		# TAU_MKE2FS_OPTS: e.g. "-E tau_segsize=4m", as TAU_MKFS_XFS_OPTS
		sudo "$MKE2FS" -t ext4 -F ${TAU_MKE2FS_OPTS:-} "$TAU_DEV" ${TAU_FS_SIZE:-} >/dev/null 2>&1 ||
			die "mke2fs ${TAU_MKE2FS_OPTS:-} ${TAU_FS_SIZE:-} failed"
		;;
	*)
		die "unknown fs '$fs' (want xfs or ext4)"
		;;
	esac
	sudo mkdir -p "$TAU_MNT"
	mount_tau "$fs"
}

# mount_tau <xfs|ext4>
mount_tau() {
	local fs=$1

	sudo mkdir -p "$TAU_MNT"
	# TAU_MOUNT_OPTS lets a run shrink the journal (tjournal_size=N, in GB) so
	# the segment pool actually runs dry - the reserve-failure path only runs
	# when it does, and on a default-sized journal that takes hours.
	sudo mount -t "$fs" -o "${TAU_MOUNT_OPTS:-tjournal}" "$TAU_DEV" "$TAU_MNT" ||
		die "mount -t $fs -o ${TAU_MOUNT_OPTS:-tjournal} failed"
}

# md5_of_repeat <byte> <count> -> md5 of <count> copies of <byte>
md5_of_repeat() {
	python3 -c "import hashlib,sys; print(hashlib.md5(bytes([int(sys.argv[1])])*int(sys.argv[2])).hexdigest())" "$1" "$2"
}

# md5_of_file <path>
md5_of_file() { sudo md5sum "$1" | awk '{print $1}'; }

# expect_md5 <name> <path> <expected>
expect_md5() {
	local name=$1 path=$2 want=$3 got

	got=$(md5_of_file "$path")
	if [ "$got" = "$want" ]; then
		printf '  PASS %-6s %s\n' "$name" "$got"
		return 0
	fi
	printf '  FAIL %-6s got=%s want=%s\n' "$name" "$got" "$want"
	return 1
}

# Count kernel complaints since boot. Anything above zero is a failure.
# tau's own: a checkpoint that stopped moving, and a BH_TauOnWrite left set
# (bug.md #6; CONFIG_TAU_PROBE_ONWRITE names who set it)
FAULTS='kernel BUG|invalid opcode|soft lockup|blocked for more than|checkpoint stalled|checkpoint drain stuck|stale BH_TauOnWrite'

kernel_faults() {
	sudo dmesg | grep -icE "$FAULTS" || true
}

show_kernel_faults() {
	sudo dmesg | grep -E "$FAULTS" -A3 | head -20
}
