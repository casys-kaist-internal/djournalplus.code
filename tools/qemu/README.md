# README for running custom kernel in Qemu

## Install qemu

```shell
./install.sh
```

Once you install qemu, do source set_env.sh on root directory again!

## Create rootfs

```shell
./create_rootfs.sh
```

## Add user to kvm group

```shell
sudo usermod -a -G kvm $USER
```

## Build kernel

`run_vm.sh` script run qemu using kernel image in $TAUFS_KERNEL path.
So, you have to build the kernel first.
Refer to the README.md file in the project root directory.

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
gdb $TAUFS_KERNEL/vmlinux -ex 'target remote localhost:1234'
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
