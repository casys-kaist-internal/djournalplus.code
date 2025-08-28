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
  local FS=$1
  local DEVICE=$2
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
      sudo zfs set recordsize=8k zfspool
      ;;
    zfs-16k)
      sudo zpool destroy -f zfspool || true
      sudo zpool create zfspool $DEVICE
      sudo zfs set recordsize=16k zfspool
      ;;
    taujournal)
      sudo mke2fs -t ext4 -J size=40000 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
}

mount_fs() {
  local FS=$1
  local MOUNT_DIR=$2
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
  local FS=$1
  local DEVICE=$2

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

create_backup_fs_image()
{
  local FS=$1
  local KEY=$2
  local BACKUP_DIR=$3
  case $FS in
    ext4)
      sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/${FS}_${KEY}.img"
      ;;
    zfs)
      mount_fs $FS $MOUNT_DIR
      sudo zfs snapshot zfspool@pgbackup
      sudo sh -c "zfs send zfspool@pgbackup > '$BACKUP_DIR/${FS}_${KEY}.img'"
      umount_fs $MOUNT_DIR
      ;;
    taujournal)
      sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/${FS}_${KEY}.img"
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
}

restore_filesystem() {
  local FS=$1
  local KEY=$2
  local BACKUP_DIR=$3
  echo "[+] Restoring filesystem: $FS"
  case $FS in
    ext4)
      sudo partclone.$FS -r -s $BACKUP_DIR/${FS}_${KEY}.img -o $TAU_DEVICE
      ;;
    zfs)
      do_mkfs $FS $DEVICE
      mount_fs $FS $MOUNT_DIR
      sudo sh -c "zfs receive -F zfspool < '$BACKUP_DIR/${FS}_${KEY}.img'"
      umount_fs $MOUNT_DIR
      ;;
    taujournal)
      sudo partclone.ext4 -r -s $BACKUP_DIR/${FS}_${KEY}.img -o $TAU_DEVICE
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
  sleep 1
  drop_caches
}

# SCALE 5000≈80GB, 10000≈160GB, 20000≈320GB  for PGBENCH in postgres
# But the differs in sysbench.
# postgres -- scale 500=17GB, 2500=85GB 5000=170GB, 10000=340GB
# MySQL    -- scale 500=14GB, 2500=72GB

sysbench_rows_per_table () { 
  local s="$1"
  echo $(( 4480 * s ))
}
