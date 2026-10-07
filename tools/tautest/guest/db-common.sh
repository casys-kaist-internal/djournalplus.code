#!/bin/bash
# Shared helpers for the database tests. Source after common.sh; expects $FS,
# $MNT, $MYSQL_BUILD and $SOCK (mysql only) to be set by the caller.

# Filesystem names and options follow bench/scripts/common.sh.
tau_mkfs_mount() {
	sudo umount "$MNT" 2>/dev/null || true
	case "$FS" in
	ext4-tau)
		[ -x "$MKE2FS" ] || die "missing patched mke2fs at $MKE2FS"
		sudo "$MKE2FS" -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 \
			-F "$TAU_DEV" >/dev/null 2>&1 || die "mke2fs failed"
		sudo mkdir -p "$MNT"
		sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$MNT" ||
			die "mount ext4 -o tjournal failed"
		;;
	xfs-tau)
		[ -x "$MKFS_XFS" ] || die "missing patched mkfs.xfs at $MKFS_XFS"
		sudo "$MKFS_XFS" "$TAU_DEV" -f -l tjmaxsize=1G >/dev/null 2>&1 ||
			die "mkfs.xfs failed"
		sudo mkdir -p "$MNT"
		sudo mount -t xfs -o tjournal "$TAU_DEV" "$MNT" ||
			die "mount xfs -o tjournal failed"
		;;
	*)
		die "unknown fs '$FS' (want ext4-tau or xfs-tau)"
		;;
	esac
	echo "[+] $FS mounted on $MNT"
}

# Mount an existing filesystem (after a crash) without touching its contents.
tau_mount_only() {
	sudo mkdir -p "$MNT"
	case "$FS" in
	ext4-tau) sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$MNT" ;;
	xfs-tau)  sudo mount -t xfs -o tjournal "$TAU_DEV" "$MNT" ;;
	*)        die "unknown fs '$FS'" ;;
	esac || die "recovery mount failed"
	echo "[+] $FS mounted (recovery)"
}

mysql_wait_ready() {
	local waited=0
	while [ $waited -lt 120 ]; do
		"$MYSQL_BUILD/bin/mysqladmin" --socket="$SOCK" -u root ping >/dev/null 2>&1 && return 0
		sleep 2; waited=$((waited + 2))
	done
	return 1
}
