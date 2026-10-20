#!/bin/bash
# OpenZFS for the ZFS column of the atomicity table (paper §6.2): the version
# the performance baselines run (libra09: zfs-dkms and zfsutils-linux
# 2.2.2-0ubuntu9.5, bench/machines/libra09.txt), its modules built for
# build_basevm.sh's kernel, and the noble userland they match -- a kit that
# table.sh (ZFS_KIT=) installs into the VM's throwaway overlay.
#   usage: build_zfs.sh <basevm kernel tree> [kit dir]
# Built by gcc 9.5 like the kernel; nice'd, so it can run beside a campaign.
set -eu
KB=$(cd "${1:?usage: build_zfs.sh <basevm kernel tree> [kit dir]}" && pwd)
V=2.2.2-0ubuntu9.5
KIT=${2:-/mnt/tau_backup/build/zfs-kit-$V-basevm}
DEBS=$(dirname "$KIT")/zfs-$V-debs; SRC=$(dirname "$KIT")/zfs-$V-src
export PATH=$HOME/codes/gcc9-bin:$PATH
[ "$(gcc -dumpfullversion)" = 9.5.0 ] || { echo "gcc is $(gcc -dumpfullversion), not 9.5.0"; exit 1; }
[ -e "$KIT" ] && { echo "$KIT exists"; exit 1; }
mkdir -p "$DEBS" "$SRC"
(cd "$DEBS" && apt-get download zfs-dkms=$V zfsutils-linux=$V libzfs4linux=$V \
	libzpool5linux=$V libnvpair3linux=$V libuutil3linux=$V)
dpkg-deb -x "$DEBS/zfs-dkms_${V}_all.deb" "$SRC"
S=$SRC/usr/src/zfs-2.2.2
# an external module needs what a bzImage-only build leaves out: the symbol
# versions (vmlinux's are all this kernel has) and scripts/module.lds
[ -f "$KB/Module.symvers" ] || cp "$KB/vmlinux.symvers" "$KB/Module.symvers"
nice -n 19 make -C "$KB" LOCALVERSION=+ -s modules_prepare
cd "$S"
nice -n 19 ./configure --prefix=/usr --with-config=kernel --with-linux="$KB" \
	--with-linux-obj="$KB" > "$SRC/configure.log" 2>&1
nice -n 19 make -j8 > "$SRC/make.log" 2>&1
mkdir -p "$KIT/root"
for p in zfsutils-linux libzfs4linux libzpool5linux libnvpair3linux libuutil3linux; do
	dpkg-deb -x "$DEBS/${p}_${V}_amd64.deb" "$KIT/root"
done
for m in spl zfs; do strip --strip-debug -o "$KIT/$m.ko" "$S/module/$m.ko"; done
echo "zfs $V modules for $(modinfo -F vermagic "$KIT/zfs.ko" | cut -d' ' -f1), userland from the noble debs" \
	> "$KIT/VERSION"
cat "$KIT/VERSION"
