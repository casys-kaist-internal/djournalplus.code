#!/bin/bash
# Hand an NVMe drive to QEMU for PCIe passthrough (vfio-pci), or give it back
# to the nvme driver -- what SPDK's scripts/setup.sh and `setup.sh reset` did.
# Needs the IOMMU on (README).  Usage: passthrough.sh [BDF] [reset]
set -e
# Addresses are per machine (lspci | grep -i 'non-volatile').  The PM1735 test
# device is 0000:86:00.0 on libra08 and libra09, libra09's PM1753 0000:af:00.0;
# libra08's 0000:3b:00.0 is another user's mounted 980 PRO.
BDF=${1:-0000:86:00.0}
dev=/sys/bus/pci/devices/$BDF
[ -e "$dev" ] || { echo "no PCI device $BDF" >&2; exit 1; }

# Refuse a drive in use: a namespace mounted (partitions and swap too) or held
# by dm/md/LVM.  Unbinding would pull it from under its user, whoever that is.
# A multipath path node nvmeXcYnZ is looked up as its namespace nvmeXnZ.
in_use() {
  local ns
  for ns in "$dev"/nvme/nvme*/nvme*n*; do
    [ -e "$ns" ] || continue
    ns=$(basename "$ns" | sed -E 's/c[0-9]+n/n/')
    lsblk -nro NAME,TYPE,MOUNTPOINT "/dev/$ns" 2>/dev/null |
      awk '$3 != "" || ($2 != "disk" && $2 != "part")'
  done
}
if [ -n "$(in_use)" ]; then
  echo "$BDF is in use, not unbinding it:" >&2
  in_use >&2
  exit 1
fi

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
