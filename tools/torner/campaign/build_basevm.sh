#!/bin/bash
# The kernel for the baseline columns of the atomicity table (paper §6.2,
# decided 2026-10-20): the source of 6.8.0-base+, the performance baseline
# (v6.8 + four fixes, branch base-fixes in ~/codes/linux-6.8.0plus-build), with
# its config, but XFS, libcrc32c, dm-log-writes and the VM's NIC (e1000) built
# in, so the Torner VM boots it, network and all, without modules.
# LOCALVERSION -basevm keeps it apart from the host's base+.  Built by gcc 9.5
# as base+ was, from a git archive in its own directory: the base+ tree is not
# touched.
#   usage: build_basevm.sh [out dir]      (nohup ... > build.log 2>&1 &)
set -eu
SRC=${BASE_SRC:-$HOME/codes/linux-6.8.0plus-build}
REV=$(git -C "$SRC" rev-parse --short=8 HEAD)
OUT=${1:-/mnt/tau_backup/build/linux-basevm-$REV}
export PATH=$HOME/codes/gcc9-bin:$PATH
[ "$(gcc -dumpfullversion)" = 9.5.0 ] || { echo "gcc is $(gcc -dumpfullversion), not 9.5.0"; exit 1; }
[ -e "$OUT" ] && { echo "$OUT exists"; exit 1; }
[ -z "$(git -C "$SRC" status --short -uno)" ] || { echo "$SRC has local changes"; exit 1; }
mkdir -p "$OUT"
echo "=== archive $SRC $REV -> $OUT $(date '+%F %T')"
git -C "$SRC" archive HEAD | tar -x -C "$OUT"
cd "$OUT"
cp /boot/config-6.8.0-base+ .config
scripts/config --set-str LOCALVERSION "-basevm" -e XFS_FS -e LIBCRC32C -e DM_LOG_WRITES -e E1000
# LOCALVERSION=+ on every make: no .git here, so setlocalversion adds no "+"
make LOCALVERSION=+ olddefconfig
scripts/diffconfig /boot/config-6.8.0-base+ .config | tee diffconfig.txt
echo "=== build $(date '+%F %T')"
make LOCALVERSION=+ -j"$(nproc)" bzImage
echo "=== built $(make LOCALVERSION=+ -s kernelrelease) $(date '+%F %T')"
strings arch/x86/boot/bzImage | grep -m1 -E '^6\.8\.0-basevm'
