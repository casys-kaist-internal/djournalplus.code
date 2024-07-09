# README for running custom kernel in Qemu

## Install qemu

```shell
./install.sh
```

## Create rootfs

```shell
./create_rootfs.sh
```

## Add user to kvm group

```shell
sudo usermod -a -G kvm $USER
```

## Build kernel

`run_vm.sh` script run qemu using kernel image in `src/linux` path.
So, you have to build the kernel first.
Refer to the README.md file in the project root directory.

## Enabling NVMe passthrough in Qemu/KVM

### 1. Enable Vt-d at BIOS setup

### 2. Make host Linux to use IOMMU

1. Add `intel_iommu=on` to `GRUB_CMDLINE_LINUX_DEFAULT` variable in `/etc/default/grub` file.
2. `sudo update-grub`
3. Reboot the host machine.
4. Check IOMMU has been activated with `dmesg | grep DMAR`.

### 3. Configure vfio-pci driver using SPDK script

Instead of setting up vfio-pci manually, we will use a SPDK script.

```shell
cd oxbow/oxbow/libfs/lib/spdk
sudo scripts/setup.sh
```

<!-- We don't need the following processes if we use the SPDK script.

### 3. Let VFIO-PCI driver know about the NVMe device

1. Check your NVMe devices' ID. For example, `144d:a80a` is my ID.

```shell
$ sudo lspci -nn | grep NVMe
d8:00.0 Non-Volatile memory controller [0108]: Samsung Electronics Co Ltd NVMe SSD Controller PM9A1/PM9A3/980PRO [144d:a80a]
d9:00.0 Non-Volatile memory controller [0108]: Samsung Electronics Co Ltd NVMe SSD Controller PM9A1/PM9A3/980PRO [144d:a80a]
```

2. Add the following line to `/etc/modprobe.d/vfio.conf` file.

```
options vfio-pci ids=[Your NVMe device ID]
```

If the id is `144d:a80a`, then as below.

```
options vfio-pci ids=144d:a80a
```

3. Make `vfio-pci` module be loaded at boot time, update initrd file and reboot.

```
sudo echo 'vfio-pci' > /etc/modules-load.d/vfio-pci.conf
sudo update-initramfs -u
sudo reboot
```

The other method.

1. Add `vfio-pci.ids=[Your NVMe device ID]` to `GRUB_CMDLINE_LINUX_DEFAULT` variable in `/etc/default/grub` file.
For example, if id is `144d:a80a`, add `vfio-pci.ids=144d:a80a`.

2. `sudo update-grub` and reboot.

### To give access to unprivileged user to this VFIO device

1. Get the `iommu_group` number.

```shell
readlink /sys/bus/pci/devices/[slot_info]/iommu_group
```

For example,

```shell
$ readlink /sys/bus/pci/devices/0000:d8:00.0/iommu_group
../../../../kernel/iommu_groups/168
```
the group number is `168`.

2. Give permission to a user.

```shell
sudo chown $USER /dev/vfio/[group_number]
``` -->

## Run qemu

```shell
./run_vm.sh
```

### Change root password (Login for the first time.)

After debootstrapping rootfs, you have to change the root password.
By adding `single` to the `-append` option of Qemu, you will fall into a root shell directly (in rescue mode).
You can change the root password in that mode. See the following example.

```
# In run_vm.sh file, add 'single' parameter.
...
   -append "root=/dev/sda rw console=ttyS0 single"
...
```

## Kill qemu

```shell
sudo pkill -9 qemu-system-x86 
```

## Debugging kernel with qemu

After boot qemu image, attach gdb client. You can run `gdb.sh`.

```shell
gdb $OXBOW_KERNEL/vmlinux -ex 'target remote localhost:1234'
```

## Access guest VM via SSH

`run_vm.sh` includes network device configuration.
It creates the slirp network backend and forward 5555(`QEMU_SSH_PORT`) port of host to guest.
You can access to guest VM using this port.

First, you have to configure network interface of a guest VM.

In a guest session, create a file, `/etc/netplan/50-cloud-init.yaml` with the following content.

```
# /etc/netplan/50-cloud-init.yaml

network:
  ethernets:
    enp0s3:
      dhcp4: true
  version: 2
```

Apply the changes.

```shell
sudo netplan apply
```

Install ssh server and start the service.

```shell
sudo apt install -y openssh-server
sudo systemctl start sshd
```

Now, you can access from host to the guest via SSH.

```shell
ssh -p 5555 localhost
```

## Troubleshooting

If qemu does not start with `-gdb` option and prompts the following message,

```shell
qemu-system-x86_64: -gdb tcp::1235: gdbstub: KVM doesn't support guest debugging
```

upgrade your host kernel to a recent version. You can install the oxbow kernel.
