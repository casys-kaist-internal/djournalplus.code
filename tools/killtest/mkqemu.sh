#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the QEMU the SOSP round's kill experiment ran on -- 9.2.4, with the
# configure line of taujournal-test.code scripts/install_qemu.sh -- into
# $WORK instead of installing it system-wide.  The tree's own QEMU
# (tools/bin) is 7.2.1, whose NVMe emulation handles in-flight requests
# differently, and in-flight requests are all a kill can tear.
#
#   tools/killtest/mkqemu.sh
#   tools/killtest/killtest.py run --qemu tools/killtest/work/qemu-9.2.4/bin/qemu-system-x86_64 ...
#
#   WORK=...   [tools/killtest/work]
#   VER=...    [9.2.4]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/work}"
VER="${VER:-9.2.4}"
SRC="$WORK/qemu-$VER-src"
PREFIX="$WORK/qemu-$VER"

mkdir -p "$WORK"
cd "$WORK"
[ -f "qemu-$VER.tar.xz" ] ||
	curl -fL -o "qemu-$VER.tar.xz" "https://download.qemu.org/qemu-$VER.tar.xz"
rm -rf "$SRC" "qemu-$VER"
tar xJf "qemu-$VER.tar.xz"
mv "qemu-$VER" "$SRC"

cd "$SRC"
./configure --disable-rbd --target-list=x86_64-softmmu --disable-docs \
	--prefix="$PREFIX"
make -j"$(nproc)"
make install
"$PREFIX/bin/qemu-system-x86_64" --version | head -n 1
echo "mkqemu: --qemu $PREFIX/bin/qemu-system-x86_64" >&2
