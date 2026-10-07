#!/bin/bash
QEMU_SSH_PORT=5555
QEMU_GDB_PORT=1235
# Both are overridable from the environment (vm_boot() runs this under
# "sudo -E").  NVME_PCIE_ADDR decides which disk gets destroyed by a test, so a
# harness that must not touch the default one sets it rather than editing here.
TOTAL_MEM="${TOTAL_MEM:-${VM_MEM:-64G}}"
NVME_PCIE_ADDR="${NVME_PCIE_ADDR:-86:00.0}" # Set proper PCIE address for your NVMe device.

# VM_NUMA=1 mirrors this host's two-socket layout into the guest and binds each
# guest node's memory to the matching host node. Off by default because it
# changes nothing for the functional tests, but it matters for anything timing
# sensitive: with a flat topology the guest scheduler treats every core as
# equidistant, while the threads underneath it are still spread across two
# sockets. A race whose window is a cache-line transfer looks different in the
# two cases.
# VM_CONSOLE_PORT puts the serial console on a TCP socket instead of this
# terminal's stdio, so a VM started in the background is still reachable:
#     VM_CONSOLE_PORT=4555 ./run_vm.sh   then   telnet 127.0.0.1 4555
# Without it the behaviour is unchanged (--nographic, console on stdio).
if [ -n "${VM_CONSOLE_PORT:-}" ]; then
	DISPLAY_ARGS="-display none -serial telnet:127.0.0.1:${VM_CONSOLE_PORT},server,nowait"
else
	DISPLAY_ARGS="--nographic"
fi

# VM_KCMDLINE_EXTRA appends to the guest kernel command line. Built-in module
# parameters take "<module>.<param>=<value>" there, which is how a setting can
# be held across the reboots a crash test performs -- writing to
# /sys/module/... only lasts until the next power cut.
SMP_ARGS="-smp cpus=32"
NUMA_ARGS=""
PREALLOC_ARG="-mem-prealloc"
if [ "${VM_NUMA:-0}" = 1 ]; then
	half=$(( ${TOTAL_MEM%G} / 2 ))
	SMP_ARGS="-smp cpus=32,sockets=2,cores=16,threads=1"
	NUMA_ARGS="-object memory-backend-ram,id=m0,size=${half}G,host-nodes=0,policy=bind,prealloc=on"
	NUMA_ARGS="$NUMA_ARGS -numa node,nodeid=0,cpus=0-15,memdev=m0"
	NUMA_ARGS="$NUMA_ARGS -object memory-backend-ram,id=m1,size=${half}G,host-nodes=1,policy=bind,prealloc=on"
	NUMA_ARGS="$NUMA_ARGS -numa node,nodeid=1,cpus=16-31,memdev=m1"
	PREALLOC_ARG=""		# prealloc is a property of the backends above
fi
# 86:00.0 SAMSUNG MZPLJ3T2HBJR   3c:00.0 980 PRO   af:00.0 Optane

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then # script is executed directly.
	qemu-system-x86_64	-kernel $TAUFS_KERNEL/arch/x86/boot/bzImage \
				-initrd /boot/initrd.img-6.8.0tjournal+ \
				-cpu host \
				$SMP_ARGS \
				$NUMA_ARGS \
				-drive file=vm_imgs/qemu-image.qcow2,index=0,media=disk,format=qcow2 \
				-m "$TOTAL_MEM" \
				-append "root=/dev/sda rw console=ttyS0 selinux=0 ${VM_KCMDLINE_EXTRA:-}" \
				--enable-kvm \
				$DISPLAY_ARGS \
				-net nic -net user,hostfwd=tcp::$QEMU_SSH_PORT-:22 \
				-device vfio-pci,host=$NVME_PCIE_ADDR \
				$PREALLOC_ARG \
				-gdb tcp::$QEMU_GDB_PORT 
			       	# If you want kernel debug enable this
				# -append "root=/dev/sda rw console=ttyS0 single" \
				# -vnc :0 \
				# -hda vm_imgs/qemu-image.img \
fi

