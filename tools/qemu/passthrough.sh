#!/bin/bash
set -e

#OMMU가 켜져 있으면 vfio-pci, 아니면 uio_pci_generic 사용
sudo modprobe vfio-pci || true
# sudo modprobe uio_pci_generic || true

# 2) 타겟 BDF 지정 (예: 0000:5e:00.0)
BDF=0000:86:00.0 # PM1735
#BDF=0000:af:00.0 #PM1753
#BDF=0000:3b:00.0

# 3) 기존 드라이버에서 장치 unbind
echo $BDF | sudo tee /sys/bus/pci/devices/$BDF/driver/unbind

# 4) 원하는 드라이버로 강제 bind (driver_override + drivers_probe)
echo vfio-pci | sudo tee /sys/bus/pci/devices/$BDF/driver_override
echo $BDF | sudo tee /sys/bus/pci/drivers_probe
echo "" | sudo tee /sys/bus/pci/devices/$BDF/driver_override
