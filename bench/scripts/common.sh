#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

### Common environment setup
DEVICE=$TAU_DEVICE
MOUNT_DIR="/mnt/temp"


do_mkfs() {
  FS=$1
  DEVICE=$2
  echo "[+] Formatting $FS on $DEVICE"

  case $FS in
    ext4)
      sudo mke2fs -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    f2fs)
      sudo mkfs.f2fs -f $DEVICE
      ;;
    btrfs)
      sudo mkfs.btrfs -f $DEVICE
      ;;
    zfs)
      sudo zpool destroy -f zfspool || true
      sudo zpool create zfspool $DEVICE
      ;;
    taujournal)
      sudo mke2fs -t ext4 -J size=40000 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
}

mount_fs() {
  FS=$1
  MOUNT_DIR=$2
  sudo mkdir -p $MOUNT_DIR
  echo "[+] Mounting $FS on $MOUNT_DIR"

  case $FS in
    ext4)
      sudo mount -t ext4 -o data=ordered $DEVICE $MOUNT_DIR
      ;;
    f2fs)
      sudo mount -t f2fs $DEVICE $MOUNT_DIR
      ;;
    btrfs)
      sudo mount -t btrfs $DEVICE $MOUNT_DIR
      ;;
    zfs)
      sudo zfs set recordsize=8k zfspool
      sudo zfs set mountpoint=$MOUNT_DIR zfspool
      ;;
    taujournal)
      # sudo mount -t ext4 -o data=journal,tjournal $DEVICE $MOUNT_DIR
      sudo mount -t ext4 -o data=ordered,tjournal $DEVICE $MOUNT_DIR
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
}

clear_fs() {
  FS=$1
  DEVICE=$2

  case $FS in
    ext4)
      ;;
    f2fs)
      ;;
    btrfs)
      ;;
    zfs)
      sudo zpool export zfspool || true
      ;;
    taujournal)
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
  
  sudo wipefs -a $DEVICE
}


umount_fs() {
  MOUNT_DIR=$1
  sudo umount $MOUNT_DIR || sudo zfs umount -a
}

drop_caches() {
  echo "[+] Dropping caches"
  sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"
}