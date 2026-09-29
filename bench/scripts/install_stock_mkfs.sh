#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

# The system e2fsprogs/xfsprogs binaries are overwritten by the tau forks
# (mke2fs then adds a tau journal to every ext4). Baseline file systems are
# made with the unmodified distro binaries instead, unpacked here from the
# packages of the installed version. The shared libraries they load
# (libext2fs, liburcu, libinih) are the untouched system ones.
STOCK_DIR=$TAUFS_BENCH_WS/stock

rm -rf "$STOCK_DIR"
mkdir -p "$STOCK_DIR/debs"
cd "$STOCK_DIR/debs"
for pkg in e2fsprogs xfsprogs; do
  apt-get download "$pkg=$(dpkg-query -W -f='${Version}' $pkg)"
done
for deb in *.deb; do
  dpkg-deb -x "$deb" "$STOCK_DIR"
done

"$STOCK_DIR/usr/sbin/mke2fs" -V
"$STOCK_DIR/sbin/mkfs.xfs" -V
