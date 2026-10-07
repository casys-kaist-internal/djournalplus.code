#!/usr/bin/env bash
# Build the small ext4 image that carries the Torner sources into the guest.
#
# This qemu build has no virtio-9p-pci, so a host directory cannot be shared
# directly; a read-only disk is the next simplest thing and needs no guest
# credentials.  Re-run after editing Torner, then reboot the guest (or just
# re-mount /dev/vdb if the guest is still up and the image was swapped).
#
# Carries two things:
#   torner/   sources only; the guest builds its own binary
#   bin/      the tau-aware mkfs/fsck forks, which the guest rootfs does not
#             have.  Stock mke2fs cannot format a tau journal, so without these
#             capture.sh stops at mkfs for every tau configuration.  They only
#             need libblkid/libuuid/libinih/liburcu, all present in the guest.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/tools/torner"
E2FSPROGS="${TAUFS_E2FSPROGS:-$ROOT/codes/e2fsprogs}"     # the tau forks
XFSPROGS="${TAUFS_XFSPROGS:-$ROOT/codes/xfsprogs-dev}"
IMG="${1:-$HERE/vm_imgs/torner-src.raw}"
SIZE="${SIZE:-256M}"

[ -d "$SRC" ] || { echo "mksrcdisk: no torner tree at $SRC" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "mksrcdisk: must run as root (loop mount)" >&2; exit 1; }

MNT="$(mktemp -d)"
cleanup() { mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT"; }
trap cleanup EXIT

rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.ext4 -q -F "$IMG"
mount -o loop "$IMG" "$MNT"

mkdir -p "$MNT/torner"
cp -r "$SRC"/Makefile "$SRC"/README.md "$SRC"/include "$SRC"/src \
      "$SRC"/scripts "$SRC"/tests "$MNT/torner/"
rm -f "$MNT/torner/src"/*.o

mkdir -p "$MNT/bin"
for f in "$E2FSPROGS"/misc/mke2fs \
         "$E2FSPROGS"/misc/tune2fs \
         "$E2FSPROGS"/e2fsck/e2fsck \
         "$XFSPROGS"/mkfs/mkfs.xfs \
         "$XFSPROGS"/repair/xfs_repair \
         "$XFSPROGS"/db/xfs_db; do
	[ -f "$f" ] || { echo "mksrcdisk: missing $f -- build the fork first" >&2; exit 1; }
	cp "$f" "$MNT/bin/"
done
# capture.sh calls mkfs.ext4; the fork installs it as a mke2fs alias
ln -sf mke2fs "$MNT/bin/mkfs.ext4"
sync

echo "mksrcdisk: $IMG ready ($(du -sh "$MNT/torner" | cut -f1) of sources)" >&2
