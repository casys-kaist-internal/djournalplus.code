#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the root file system killtest boots: a minimal Ubuntu 24.04 (noble)
# with the distro's own -- stock -- mkfs tools, and the init stub
# (guest/init) that hands each boot to the run's tools disk.
#
# Why a rootfs of its own:
#   - the host's /usr/sbin/mke2fs and mkfs.xfs are the tau forks (a tau
#     journal in every ext4), and so are those in the perf VM image
#     (mkfs.xfs 6.15.0).  Baselines have to be made with the distro binaries,
#     as in the SOSP round's VM (debootstrap noble + apt);
#   - every trial boots it read only, so a SIGKILL never leaves it to repair,
#     and no other VM's image is opened -- QEMU would lock it.
#
# One time.  Needs sudo (debootstrap, and reading the root-owned tree into
# the image) and an Ubuntu mirror.  Writes:
#   $WORK/rootfs.img            ext4 image, sparse
#   $WORK/rootfs-packages.txt   the versions baselines are formatted with
#
#   WORK=...       [tools/killtest/work]
#   MIRROR=...     [http://kr.archive.ubuntu.com/ubuntu/]
#   WITH_ZFS=1     also install zfsutils-linux, and udev: zpool create waits
#                  for udev to settle the partitions it makes (--fs zfs-16k)
#   WITH_DB=1      also what `killtest.py db` needs: sysbench, the shared
#                  libraries of this tree's PostgreSQL and MySQL builds (which
#                  come on the tools disk), iproute2 for the loopback, and an
#                  unprivileged user (ktdb) -- PostgreSQL refuses to run as root
#   FORCE=1        rebuild an existing image

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${WORK:-$HERE/work}"
SUITE="${SUITE:-noble}"
MIRROR="${MIRROR:-http://kr.archive.ubuntu.com/ubuntu/}"
SIZE="${SIZE:-2G}"
STOCK="$ROOT/bench/workspace/stock"

PKGS="mount,util-linux,kmod,procps,e2fsprogs,xfsprogs,btrfs-progs,f2fs-tools"
[ "${WITH_ZFS:-0}" = 1 ] && PKGS="$PKGS,zfsutils-linux,udev"
[ "${WITH_DB:-0}" = 1 ] &&
	PKGS="$PKGS,sysbench,libicu74,libnuma1,libaio1t64,libreadline8t64,libssl3t64,iproute2"

die() { echo "mkrootfs: $*" >&2; exit 1; }

# The image is written with the stock mke2fs: the system one would add a
# tau journal to the guest's root file system.
[ -x "$STOCK/usr/sbin/mke2fs" ] ||
	die "no stock mke2fs in $STOCK (bench/scripts/install_stock_mkfs.sh)"
command -v debootstrap >/dev/null || die "debootstrap is not installed"

IMG="$WORK/rootfs.img"
TREE="$WORK/rootfs.tree"
if [ -e "$IMG" ] && [ "${FORCE:-0}" != 1 ]; then
	die "$IMG exists (FORCE=1 rebuilds it)"
fi
mkdir -p "$WORK"
sudo rm -rf "$TREE"
trap 'sudo rm -rf "$TREE"' EXIT

echo "mkrootfs: debootstrap $SUITE from $MIRROR" >&2
sudo debootstrap --variant=minbase --components=main,universe \
	--include="$PKGS" "$SUITE" "$TREE" "$MIRROR"

sudo install -D -m 0755 "$HERE/guest/init" "$TREE/opt/killtest/init"
sudo mkdir -p "$TREE/kt" "$TREE/mnt/test" "$TREE/usr/lib/modules"
if [ "${WITH_DB:-0}" = 1 ]; then
	sudo chroot "$TREE" useradd -m -u 2000 -s /bin/sh ktdb
	printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n' | sudo tee "$TREE/etc/hosts" >/dev/null
fi

{
	echo "# mkrootfs WITH_ZFS=${WITH_ZFS:-0} WITH_DB=${WITH_DB:-0} $SUITE $MIRROR"
	dpkg-query --admindir="$TREE/var/lib/dpkg" -W \
		-f='${Package}\t${Version}\n' $(echo "$PKGS" | tr ',' ' ')
} > "$WORK/rootfs-packages.txt"

rm -f "$IMG.tmp"
truncate -s "$SIZE" "$IMG.tmp"
sudo env MKE2FS_CONFIG="$STOCK/etc/mke2fs.conf" "$STOCK/usr/sbin/mke2fs" \
	-q -F -t ext4 -L ktroot -d "$TREE" "$IMG.tmp"
mv "$IMG.tmp" "$IMG"

echo "mkrootfs: $IMG ($(du -h "$IMG" | cut -f1) used of $SIZE)" >&2
cat "$WORK/rootfs-packages.txt"
