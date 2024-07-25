#!/bin/bash
QEMU_SSH_PORT=5555
QEMU_GDB_PORT=1235
TOTAL_MEM="64G"
NVME_PCIE_ADDR="" # Set proper PCIE address for your NVMe device.
# NVME_PCIE_ADDR="d8:00.0"
# NVME_PCIE_ADDR="af:00.0"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then # script is executed directly.
	qemu-system-x86_64	-kernel ../djournalplus-kernel.code/arch/x86/boot/bzImage \
				-initrd /boot/initrd.img-6.2.10djplus+ \
				-cpu host \
				-smp cpus=32 \
				-drive file=vm_imgs/qemu-image.qcow2,index=0,media=disk,format=qcow2 \
				-m "$TOTAL_MEM" \
				-append "root=/dev/sda rw console=ttyS0 selinux=0" \
				--enable-kvm \
				--nographic \
				-net nic -net user,hostfwd=tcp::$QEMU_SSH_PORT-:22 \
				-device vfio-pci,host=$NVME_PCIE_ADDR \
				-mem-prealloc \
				-gdb tcp::$QEMU_GDB_PORT 
			       	# If you want kernel debug enable this
				# -append "root=/dev/sda rw console=ttyS0 single" \
				# -vnc :0 \
				# -hda vm_imgs/qemu-image.img \
fi

