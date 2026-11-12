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
KERNEL="${TAUFS_KERNEL:-$ROOT/codes/djournalplus-kernel.code}"

SSH_PORT="${SSH_PORT:-5556}"
GDB_PORT="${GDB_PORT:-1236}"
MEM="${MEM:-16G}"
CORES="${CORES:-8}"
SCRATCH="${SCRATCH:-$HERE/vm_imgs/torner-scratch.raw}"
SCRATCH_SIZE="${SCRATCH_SIZE:-32G}"
SRCDISK="${SRCDISK:-$HERE/vm_imgs/torner-src.raw}"
ROOTFS="${ROOTFS:-$HERE/vm_imgs/qemu-image_2404.qcow2}"
# more kernel command line, e.g. tau_journal.tau_shrink_seeks=32
KCMDLINE="${KCMDLINE:-}"
# VM_HUGEPAGES=1 (off by default): the guest's RAM on the host's 1 GiB hugepages,
# all on the node with the most free ones (libra08 and libra09 reserve 63 per node
# at boot for perf runs; a correctness VM may use them, and then cannot push
# another VM's plain memory into the OOM killer, as on 11-11). memfd, not a
# hugetlbfs mount: /dev/hugepages1G is root's and this VM runs as the user.
VM_HUGEPAGES="${VM_HUGEPAGES:-0}"

# tools/bin's build if there is one, else the one on PATH
if [ -z "${QEMU:-}" ]; then
	QEMU="$ROOT/tools/bin/qemu-system-x86_64"
	[ -x "$QEMU" ] || QEMU="$(command -v qemu-system-x86_64 || echo "$QEMU")"
fi

die() { echo "run_vm_torner: $*" >&2; exit 1; }

[ -x "$QEMU" ] || die "qemu not found at $QEMU"
[ -f "$KERNEL/arch/x86/boot/bzImage" ] || die "kernel not built: $KERNEL/arch/x86/boot/bzImage"
[ -f "$ROOTFS" ] || die "rootfs not found: $ROOTFS"

RELEASE="$(cat "$KERNEL/include/config/kernel.release" 2>/dev/null)"
[ -n "$RELEASE" ] || die "cannot read kernel release"
# root-only on some hosts (0600): INITRD=<a readable copy> runs qemu unprivileged
INITRD="${INITRD:-/boot/initrd.img-$RELEASE}"
[ -f "$INITRD" ] || die "initrd not found: $INITRD"

# The stack under test needs CONFIG_DM_LOG_WRITES; without it the guest cannot
# create the dm target at all.
grep -q '^CONFIG_DM_LOG_WRITES=[ym]' "$KERNEL/.config" \
	|| die "CONFIG_DM_LOG_WRITES is not enabled in $KERNEL/.config"

[ -f "$SRCDISK" ] || die "torner source disk missing: $SRCDISK (run tools/qemu/mksrcdisk.sh)"

# The scratch disk is sparse and fills as the guest writes: its file system has
# to take all of it, or a long run fills the host's disk -- on libra08 that is
# the shared root file system.
if [ -f "$SCRATCH" ]; then
	grow=$(( $(stat -c %s "$SCRATCH") - $(stat -c '%b * %B' "$SCRATCH") ))
else
	grow=$(numfmt --from=iec "$SCRATCH_SIZE")
fi
free=$(df --output=avail -B1 "$(dirname "$SCRATCH")" | tail -1)
[ "$grow" -le "$free" ] || die "scratch disk $SCRATCH can grow by $((grow >> 30)) GiB," \
	"$(dirname "$SCRATCH") has $((free >> 30)) GiB free: set SCRATCH to a bigger file system"

if [ ! -f "$SCRATCH" ]; then
	echo "run_vm_torner: creating scratch disk $SCRATCH ($SCRATCH_SIZE)" >&2
	truncate -s "$SCRATCH_SIZE" "$SCRATCH" || die "cannot create scratch disk"
fi

MEMARGS=(-m "$MEM")
if [ "$VM_HUGEPAGES" = 1 ]; then
	bytes=$(numfmt --from=iec "$MEM") || die "MEM=$MEM is not a size"
	[ $((bytes % (1 << 30))) = 0 ] || die "VM_HUGEPAGES=1 needs MEM in whole GiB, not $MEM"
	need=$((bytes >> 30)) node= most=-1
	for d in /sys/devices/system/node/node[0-9]*; do
		f=$(cat "$d/hugepages/hugepages-1048576kB/free_hugepages" 2>/dev/null) || continue
		[ "$f" -gt "$most" ] && { most=$f; node=${d##*node}; }
	done
	[ "$most" -ge "$need" ] ||
		die "VM_HUGEPAGES=1: no node has $need free 1 GiB pages (the most is $most, node $node)"
	MEMARGS+=(-object "memory-backend-memfd,id=ram0,size=$MEM,hugetlb=on,hugetlbsize=1G,prealloc=on,host-nodes=$node,policy=bind"
		-machine memory-backend=ram0)
	echo "run_vm_torner: guest RAM $MEM on node $node's 1 GiB pages ($most free before)" >&2
fi

cat >&2 <<EOF
run_vm_torner: kernel $RELEASE
               rootfs  $ROOTFS
               scratch $SCRATCH  -> guest /dev/vda
               torner src        -> guest /dev/vdb  (built by mksrcdisk.sh)
               ssh localhost:$SSH_PORT   gdb :$GDB_PORT

In the guest:
    mkdir -p /mnt/src && mount -o ro /dev/vdb /mnt/src
    export PATH=/mnt/src/bin:\$PATH    # the tau mkfs/fsck forks (capture.sh)
    cp -r /mnt/src/torner /root/torner && cd /root/torner && make && make test
    mkdir -p /mnt/scratch && mkfs.ext4 -qF /dev/vda && mount /dev/vda /mnt/scratch

EOF

exec "$QEMU" \
	-kernel "$KERNEL/arch/x86/boot/bzImage" \
	-initrd "$INITRD" \
	-append "root=/dev/sda rw console=ttyS0${KCMDLINE:+ $KCMDLINE}" \
	-cpu host \
	-smp "cpus=$CORES" \
	"${MEMARGS[@]}" \
	--enable-kvm \
	--nographic \
	-drive "file=$ROOTFS,index=0,media=disk,format=qcow2" \
	-drive "file=$SCRATCH,if=virtio,format=raw,cache=writeback" \
	-drive "file=$SRCDISK,if=virtio,format=raw,readonly=on" \
	-net nic -net "user,hostfwd=tcp::$SSH_PORT-:22" \
	-gdb "tcp::$GDB_PORT"
