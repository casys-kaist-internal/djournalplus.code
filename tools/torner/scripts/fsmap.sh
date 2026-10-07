# SPDX-License-Identifier: GPL-2.0
#
# One place to say how each configuration is formatted, mounted, and checked.
# capture.sh and explore.sh both source this: a mount option that drifts between
# capture and replay silently changes what is being tested.
#
# fs_setup <fs> <dev>   formats <dev>, and sets:
#     FS_MOUNT_OPTS   options for mount
#     FS_UNTORN       "--untorn" when the workload has to opt into tauJournal
# fs_mount_opts <fs>   sets FS_MOUNT_OPTS / FS_UNTORN without formatting
# fs_fsck <fs> <dev>   read-only integrity check (P3); returns non-zero on dirt

# FS_REPLAY_OPTS: extra options needed only when mounting a REBUILT state.
#
# explore.sh has several states mounted at once, and they are all copies of one
# filesystem.  XFS refuses the second one outright -- "Filesystem has duplicate
# UUID - can't mount" -- which arrives as a mount failure and reads like a
# crash state the file system could not recover.  It is neither; it is the
# harness colliding with itself.  -o nouuid is the standard answer.
fs_mount_opts() {
	FS_MOUNT_OPTS=""
	FS_REPLAY_OPTS=""
	FS_UNTORN=""
	case "$1" in
	ext4)		;;
	ext4-data)	FS_MOUNT_OPTS="-o data=journal" ;;
	xfs)		FS_REPLAY_OPTS="-o nouuid" ;;
	btrfs)		;;
	f2fs)		;;
	# -o tjournal turns tauJournal on, but files still opt in one by one.
	# Without O_TAU_UNTORN the run journals nothing and every tau invariant
	# passes vacuously -- dmesg ends with "But no transaction to commit".
	tau-ext4)	FS_MOUNT_OPTS="-o tjournal"; FS_UNTORN="--untorn" ;;
	tau-xfs)	FS_MOUNT_OPTS="-o tjournal"; FS_REPLAY_OPTS="-o nouuid"
			FS_UNTORN="--untorn" ;;
	# ZFS is not mounted from a device: the pool owns the vdev and its
	# dataset appears at a path.  fs_is_zfs() marks the configurations that
	# need the pool import/export path instead of mount/umount.
	# recordsize is the CoW unit, and it decides whether an application's
	# atomic write can be split at all.  At the 128K default a 16 KiB
	# overwrite is read-modify-written into one record and re-allocated as a
	# single unit, so it cannot tear no matter what the device does.  Below
	# the application unit it spans several records.  bench/scripts/common.sh
	# benchmarks 4k/8k/16k, so those are the interesting ones.
	zfs|zfs-4k|zfs-8k|zfs-16k|zfs-16k-lz4|zfs-recordsize-16k)	;;
	*) echo "fsmap: unknown fs '$1'" >&2; return 1 ;;
	esac
	return 0
}

fs_is_zfs() {
	case "$1" in zfs|zfs-4k|zfs-8k|zfs-16k|zfs-16k-lz4|zfs-recordsize-16k) return 0 ;;
	*) return 1 ;; esac
}

# recordsize for a configuration; empty means leave the ZFS default (128K).
fs_zfs_recordsize() {
	case "$1" in
	zfs-4k)				echo 4k ;;
	zfs-8k)				echo 8k ;;
	zfs-16k|zfs-16k-lz4|zfs-recordsize-16k)	echo 16k ;;
	*)				echo "" ;;
	esac
}

TORNER_ZPOOL="${TORNER_ZPOOL:-torner_pool}"

# CRASH_TODO §7 item 4 is still open: ZFS is out of tree, and whether it will
# take a dm-log-writes device as a vdev has not been confirmed on this kernel.
# If it refuses, ZFS drops out of T2b and that limitation gets documented --
# do not paper over it here.
# The pool keeps its default mountpoint /<pool>.  Passing -m explicitly fails
# with "'mountpoint' cannot be set while dataset 'zoned' property is set", and
# the default is what `zpool import -R` then relocates anyway.
fs_zfs_create() {
	local fs="$1" dev="$2"

	local rs

	# Compression is off by default so that recordsize is the only variable
	# under test -- lz4 changes the physical size of a record and therefore
	# what a partial write can straddle.  zfs-16k-lz4 turns it back on to
	# match bench/scripts/common.sh, which benchmarks recordsize=16k with
	# lz4.
	local comp=off
	case "$fs" in zfs-16k-lz4) comp=lz4 ;; esac

	zpool create -f -o ashift=12 -O compression="$comp" -O checksum=on \
		"$TORNER_ZPOOL" "$dev" || return 1
	rs="$(fs_zfs_recordsize "$fs")"
	if [ -n "$rs" ]; then
		# must be set before the file is created; it applies to new files
		zfs set recordsize="$rs" "$TORNER_ZPOOL" || return 1
	fi
	return 0
}

# Where the workload's file lives.  ZFS is the odd one out: `zpool import -R`
# relocates the pool under an alternate root, so the dataset appears one level
# down at <altroot>/<pool>, not at <altroot>.
fs_data_dir() {
	if fs_is_zfs "$1"; then
		echo "$2/$TORNER_ZPOOL"
	else
		echo "$2"
	fi
}

# Import a replayed image: this is where ZFS runs its recovery, the way mount
# does for ext4/xfs.  -d takes the loop device directly; pointing it at a
# directory makes it scan every device there.
fs_zfs_import() {
	local dev="$1" mnt="$2"

	zpool import -f -d "$dev" -R "$mnt" "$TORNER_ZPOOL" 2>&1
}

fs_zfs_export() {
	zpool export -f "$TORNER_ZPOOL" 2>/dev/null
}

# Measured: a second copy of the same pool cannot be imported while the first
# is up -- "a pool with that name already exists", and importing under a new
# name fails too because the pool GUID is the identity.  So ZFS states have to
# be explored one at a time.
# btrfs keys on the filesystem fsid and rejects a second mount of a clone, just
# as XFS does on UUID -- but it has no -o nouuid equivalent, so clones have to
# be mounted one at a time.  Changing the fsid with btrfstune would rewrite the
# image under test, which is not acceptable here.
fs_max_jobs() {
	case "$1" in
	btrfs)	echo 1 ;;
	*)	if fs_is_zfs "$1"; then echo 1; else echo "$2"; fi ;;
	esac
}

fs_setup() {
	local fs="$1" dev="$2"

	fs_mount_opts "$fs" || return 1
	case "$fs" in
	ext4|ext4-data)	mkfs.ext4 -q -F "$dev" ;;
	# the tau superblock check requires 4 KiB blocks
	tau-ext4)	mkfs.ext4 -q -F -b 4096 "$dev" ;;
	xfs|tau-xfs)	mkfs.xfs -f -q "$dev" ;;
	btrfs)		mkfs.btrfs -f -q "$dev" ;;
	f2fs)		mkfs.f2fs -f -q "$dev" ;;
	zfs|zfs-4k|zfs-8k|zfs-16k|zfs-16k-lz4|zfs-recordsize-16k)	fs_zfs_create "$fs" "$dev" ;;
	esac
}

fs_fsck() {
	local fs="$1" dev="$2"

	case "$fs" in
	ext4|ext4-data|tau-ext4)	e2fsck -f -n "$dev" >/dev/null 2>&1 ;;
	xfs|tau-xfs)			xfs_repair -n "$dev" >/dev/null 2>&1 ;;
	btrfs)				btrfs check --readonly "$dev" >/dev/null 2>&1 ;;
	f2fs)				fsck.f2fs --dry-run "$dev" >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# fs_fsck_report <fs> <dev>
#
# Normalised list of what fsck complains about, for comparing a recovered state
# against a pristine one.  The exit code on its own is not usable as P3:
#
#   the tau-aware mke2fs allocates the tau journal at reserved inode 9, and
#   e2fsck calls that "Reserved inode 9 has invalid mode" -- on an image that
#   was just formatted and never mounted.  Judging P3 by exit code therefore
#   reports every single state as dirty, which reads like a catastrophic
#   finding and is really a property of mkfs.
#
# So capture.sh records this report for the freshly formatted device, and
# explore.sh fails P3 only when a state's report says something the baseline
# did not.
fs_fsck_report() {
	local fs="$1" dev="$2"

	case "$fs" in
	ext4|ext4-data|tau-ext4)	e2fsck -f -n "$dev" 2>&1 ;;
	xfs|tau-xfs)			xfs_repair -n "$dev" 2>&1 ;;
	btrfs)				btrfs check --readonly "$dev" 2>&1 ;;
	f2fs)				fsck.f2fs --dry-run "$dev" 2>&1 ;;
	zfs|zfs-4k|zfs-8k|zfs-16k|zfs-16k-lz4|zfs-recordsize-16k)
		zpool scrub -w "$TORNER_ZPOOL" >/dev/null 2>&1
		zpool status -v "$TORNER_ZPOOL" 2>&1 | sed -n '/errors:/,$p'
		;;
	*) echo "unknown fs $fs" ;;
	esac | sed \
		-e "s|$dev||g" \
		`# banners and tool versions` \
		-e '/^e2fsck [0-9]/d' \
		-e '/^xfs_repair version/d' \
		-e '/^Info: /d' \
		-e '/Linux version /d' \
		`# progress chatter: it says what was inspected, not what was wrong` \
		-e '/^Pass [0-9]/d' \
		-e '/^Phase [0-9]/d' \
		-e '/^ *- /d' \
		-e '/^\[[0-9]*\/[0-9]*\] checking/d' \
		-e '/^\[FSCK\] .*\[Ok\.\.\]/d' \
		-e '/^Opening filesystem/d' \
		-e '/^Checking filesystem/d' \
		-e '/^UUID:/d' \
		-e '/^No modify flag set/d' \
		`# timings and space accounting vary with the state without being a` \
		`# fault: btrfs prints a stats block, f2fs prints how long it took.` \
		-e '/^Done: /d' \
		-e '/^total [a-z ]*bytes: /d' \
		-e '/^btree space waste bytes: /d' \
		-e '/^file data blocks allocated: /d' \
		-e '/^ *referenced [0-9]/d' \
		-e '/files (.*% non-contiguous)/d' \
		-e '/^$/d' \
	| sed -e 's/[0-9][0-9]*/N/g' \
	| sort -u
}

# NOTE ON THE NUMBER STRIPPING ABOVE.  Every surviving line has its digits
# collapsed to N before comparison.  Without it, a report differs from the
# pristine baseline for reasons that are not faults -- free-block counts, an
# inode number, a byte total -- and P3 fails on every single state.  That is
# not hypothetical: btrfs and f2fs both reported 100% dirty until this was
# added, purely on "btree space waste bytes" and "Done: 0.022505 secs".
#
# The cost is precision: two different real faults can collapse to the same
# text.  They still differ from the baseline, so P3 still fails -- only the
# detail line is less specific.  The full unnormalised report is what to read
# when a state does fail.

