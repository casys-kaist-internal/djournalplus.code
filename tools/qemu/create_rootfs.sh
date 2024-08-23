#!/bin/bash

# Install required package.
sudo apt install -y debootstrap

IMG_DIR=vm_imgs
IMG=$IMG_DIR/qemu-image.raw
IMG_QCOW2=$IMG_DIR/qemu-image.qcow2
DIR=./temp_mount_dir

mkdir -p $IMG_DIR

if [ -f "$IMG" ]; then
	echo "Image(qemu-image.img) alread exists."
	exit 1
fi

qemu-img create $IMG 100g
mkfs.ext4 $IMG
mkdir -p $DIR
sudo mount -o loop $IMG $DIR
sudo debootstrap --arch amd64 jammy $DIR
sudo umount $DIR
rmdir $DIR
qemu-img convert -O qcow2 $IMG $IMG_QCOW2
rm -rf $IMG
