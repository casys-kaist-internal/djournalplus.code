#!/bin/bash
set -e


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
    zfs8k)
      sudo zpool destroy -f zfs8kpool || true
      sudo zpool create zfs8kpool $DEVICE
      ;;
    zfs128k)
      sudo zpool destroy -f zfs128kpool || true
      sudo zpool create zfs128kpool $DEVICE
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
    zfs8k)
      sudo zfs set recordsize=8k zfs8kpool
      sudo zfs set mountpoint=$MOUNT_DIR zfs8kpool
      ;;
    zfs128k)
      sudo zfs set recordsize=128k zfs128kpool
      sudo zfs set mountpoint=$MOUNT_DIR zfs128kpool
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
    zfs8k)
      sudo zpool export zfs8kpool || true
      ;;
    zfs128k)
      sudo zpool export zfs128kpool || true
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