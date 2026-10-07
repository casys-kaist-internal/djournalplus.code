#!/bin/bash
# Hand an NVMe drive to QEMU for PCIe passthrough (vfio-pci), or give it back
# to the nvme driver -- what SPDK's scripts/setup.sh and `setup.sh reset` did.
# Needs the IOMMU on (README).  Usage: passthrough.sh [BDF] [reset]
set -e
BDF=${1:-0000:86:00.0}   # PM1735; PM1753 is 0000:af:00.0, the 990 PRO 0000:3b:00.0
dev=/sys/bus/pci/devices/$BDF
[ -e "$dev" ] || { echo "no PCI device $BDF" >&2; exit 1; }

# unbind from whatever driver has it
[ -e "$dev/driver" ] && echo "$BDF" | sudo tee "$dev/driver/unbind" >/dev/null

if [ "${2:-}" = reset ]; then
  echo "" | sudo tee "$dev/driver_override" >/dev/null
else
  sudo modprobe vfio-pci
  echo vfio-pci | sudo tee "$dev/driver_override" >/dev/null
fi
echo "$BDF" | sudo tee /sys/bus/pci/drivers_probe >/dev/null
# a later probe (rescan, reboot) binds the default driver again
echo "" | sudo tee "$dev/driver_override" >/dev/null
echo "$BDF -> $(basename "$(readlink "$dev/driver" 2>/dev/null || echo none)")"
