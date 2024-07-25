# djournalplus.code
DJPLUS: High-performance data journaling

## Setting environment variables

```shell
source set_env.sh
```

## Get the submodule source code

```shell
git submodule update --recursive --init
```

## Compile Kernel

Develop data journal modules (jbd2) in kernel code.
Modify code and build on host. Then reboot on QEMU.
HIGHLY recommend you to use gcc-9 (gcc-13 makes compile error)

```shell
cp ./VM_kernel.config ./djournalplus-kernel.code/.config
cd ./djournal-kernel.code
make menuconfig # Optional
make -j
sudo make modules_install
sudo make install
```

## PCIe Passthrough to QEMU

Before setting Passthrough, check memlock of user by following command

```shell
ulimit -l
```

If it is not "unlimited" then modify "/etc/security/limits.conf" file.

For example add follow lines to the file.
jhlee    soft    memlock    unlimited
jhlee    hard    memlock    unlimited

Then applying the changes
```shell
sudo systemctl restart systemd-logind
```

After checking memlock, follow below steps

### 1. Enable Vt-d at BIOS setup

### 2. Make host Linux to use IOMMU

1. Add `intel_iommu=on` to `GRUB_CMDLINE_LINUX_DEFAULT` variable in `/etc/default/grub` file.
2. `sudo update-grub`
3. Reboot the host machine.
4. Check IOMMU has been activated with `dmesg | grep DMAR`.

### 3. Enable Vt-d at BIOS setup

SPDK repo will be used only for PCIe Passthrough setting.
DO NOT build SPDK on host machine.

```shell
cd ./spdk
sudo ./scripts/setup.sh
```

You may see "0000:86:00.0 (144d a824): nvme -> vfio-pci"
86.00.0 will be PCIe address of NVMe drive, used in QEMU

You can reset PCIe passthrough
```shell
cd ./spdk
sudo ./scripts/setup.sh reset
```

## QEMU/GDB setting

Refer to README file in qemu directory.