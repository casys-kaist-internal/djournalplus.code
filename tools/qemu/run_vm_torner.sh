#!/usr/bin/env bash
# Boot the tau kernel for Torner crash-state work.
#
# Deliberately NOT run_vm.sh:
#
#  - No NVMe passthrough.  vfio-pci hands the whole device to one guest, so a
#    passthrough VM cannot be run N-way parallel, and qcow2 overlays cannot be
#    stacked on a passed-through device.  Both are load-bearing for T2b.
#    (It is also the wrong device: tools/crashmonkey/docs/tau.md 7.2 measured
#    /dev/nvme0n1 reporting "write through", which gets REQ_PREFLUSH/REQ_FUA
#    stripped before dm-log-writes can record them.)
#  - Modest RAM/cores: this is correctness work on a ~10 GiB dataset, not the
#    150 GiB performance rig.
#  - Different SSH/GDB ports, so it can run alongside a perf VM.
#
# Self-contained: does not need set_env.sh.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
KERNEL="$ROOT/djournalplus-kernel.code"

SSH_PORT="${SSH_PORT:-5556}"
GDB_PORT="${GDB_PORT:-1236}"
MEM="${MEM:-16G}"
CORES="${CORES:-8}"
SCRATCH="${SCRATCH:-$HERE/vm_imgs/torner-scratch.raw}"
SCRATCH_SIZE="${SCRATCH_SIZE:-32G}"
SRCDISK="${SRCDISK:-$HERE/vm_imgs/torner-src.raw}"
ROOTFS="${ROOTFS:-$HERE/vm_imgs/qemu-image_2404.qcow2}"

QEMU="${QEMU:-$ROOT/tools/bin/qemu-system-x86_64}"

die() { echo "run_vm_torner: $*" >&2; exit 1; }

[ -x "$QEMU" ] || die "qemu not found at $QEMU"
[ -f "$KERNEL/arch/x86/boot/bzImage" ] || die "kernel not built: $KERNEL/arch/x86/boot/bzImage"
[ -f "$ROOTFS" ] || die "rootfs not found: $ROOTFS"

RELEASE="$(cat "$KERNEL/include/config/kernel.release" 2>/dev/null)"
[ -n "$RELEASE" ] || die "cannot read kernel release"
INITRD="/boot/initrd.img-$RELEASE"
[ -f "$INITRD" ] || die "initrd not found: $INITRD"

# The stack under test needs CONFIG_DM_LOG_WRITES; without it the guest cannot
# create the dm target at all.
grep -q '^CONFIG_DM_LOG_WRITES=[ym]' "$KERNEL/.config" \
	|| die "CONFIG_DM_LOG_WRITES is not enabled in $KERNEL/.config"

[ -f "$SRCDISK" ] || die "torner source disk missing: $SRCDISK (run tools/qemu/mksrcdisk.sh)"

if [ ! -f "$SCRATCH" ]; then
	echo "run_vm_torner: creating scratch disk $SCRATCH ($SCRATCH_SIZE)" >&2
	truncate -s "$SCRATCH_SIZE" "$SCRATCH" || die "cannot create scratch disk"
fi

cat >&2 <<EOF
run_vm_torner: kernel $RELEASE
               rootfs  $ROOTFS
               scratch $SCRATCH  -> guest /dev/vda
               torner src        -> guest /dev/vdb  (built by mksrcdisk.sh)
               ssh localhost:$SSH_PORT   gdb :$GDB_PORT

In the guest:
    mkdir -p /mnt/src && mount -o ro /dev/vdb /mnt/src
    cp -r /mnt/src/torner /root/torner && cd /root/torner && make && make test
    mkdir -p /mnt/scratch && mkfs.ext4 -qF /dev/vda && mount /dev/vda /mnt/scratch

EOF

exec "$QEMU" \
	-kernel "$KERNEL/arch/x86/boot/bzImage" \
	-initrd "$INITRD" \
	-append "root=/dev/sda rw console=ttyS0" \
	-cpu host \
	-smp "cpus=$CORES" \
	-m "$MEM" \
	--enable-kvm \
	--nographic \
	-drive "file=$ROOTFS,index=0,media=disk,format=qcow2" \
	-drive "file=$SCRATCH,if=virtio,format=raw,cache=writeback" \
	-drive "file=$SRCDISK,if=virtio,format=raw,readonly=on" \
	-net nic -net "user,hostfwd=tcp::$SSH_PORT-:22" \
	-gdb "tcp::$GDB_PORT"
