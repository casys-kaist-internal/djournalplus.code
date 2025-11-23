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
    ext4-dj)
      sudo mke2fs -t ext4  -J size=10000 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    f2fs)
      sudo mkfs.f2fs -f $DEVICE
      ;;
    btrfs)
      sudo mkfs.btrfs -f $DEVICE
      ;;
    xfs|xfs-cow)
      sudo mkfs.xfs -f $DEVICE
      ;;
    zfs|zfs-4k|zfs-8k|zfs-16k)
      sudo zpool destroy -f zfspool || true
      sudo zpool create -o ashift=12 zfspool $DEVICE
      ;;
    taujournal|tau4G|tau8G|tau16G|tau32G)
      sudo $TAUFS_ROOT/e2fsprogs/misc/mke2fs -t ext4 -J tau_journal_size=40000 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
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
    ext4-dj)
      sudo mount -t ext4 -o data=journal $DEVICE $MOUNT_DIR
      ;;
    f2fs)
      sudo mount -t f2fs $DEVICE $MOUNT_DIR
      ;;
    btrfs)
      sudo mount -t btrfs $DEVICE $MOUNT_DIR
      ;;
    xfs|xfs-cow)
      sudo mount -t xfs $DEVICE $MOUNT_DIR
      ;;
    zfs)
      sudo zfs set mountpoint=$MOUNT_DIR zfspool
      ;;
    zfs-4k)
      sudo zfs set recordsize=4k zfspool
      sudo zfs set mountpoint=$MOUNT_DIR zfspool
      ;;
    zfs-8k)
      sudo zfs set recordsize=8k zfspool
      sudo zfs set mountpoint=$MOUNT_DIR zfspool
      ;;
    zfs-16k)
      sudo zfs set recordsize=16k zfspool
      sudo zfs set mountpoint=$MOUNT_DIR zfspool
      ;;
    taujournal)
      sudo mount -t ext4 -o tjournal $DEVICE $MOUNT_DIR
      ;;
    tau4G)
      sudo mount -t ext4 -o tjournal,tjournal_size=4 $DEVICE $MOUNT_DIR
      ;;
    tau8G)
      sudo mount -t ext4 -o tjournal,tjournal_size=8 $DEVICE $MOUNT_DIR
      ;;
    tau16G)
      sudo mount -t ext4 -o tjournal,tjournal_size=16 $DEVICE $MOUNT_DIR
      ;;
    tau32G)
      sudo mount -t ext4 -o tjournal,tjournal_size=32 $DEVICE $MOUNT_DIR
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
}

clear_fs() {
  local FS=$1
  local DEVICE=$2

  case $FS in
    ext4|ext4-dj)
      ;;
    f2fs)
      ;;
    btrfs)
      ;;
    xfs|xfs-cow)
      ;;
    zfs|zfs-4k|zfs-8k|zfs-16k)
      sudo zpool export zfspool || true
      ;;
    taujournal|tau4G|tau8G|tau16G|tau32G)
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

sysbench_rows_per_table () { # SCALE 5000≈80GB, 10000≈160GB, 20000≈320GB
  local s="$1"
  echo $(( 4480 * s ))
}

warming_up_ssd() {
  echo "WARNING: This will destroy all data on $TAU_DEVICE in 5 seconds."
  echo "Press Ctrl+C to cancel."
  sleep 5

  echo "Starting 5-minute SSD Scramble on $TAU_DEVICE..."

  sudo fio --name=scramble \
      --filename=$TAU_DEVICE \
      --direct=1 \
      --rw=randwrite \
      --bs=4k \
      --ioengine=libaio \
      --iodepth=64 \
      --time_based \
      --runtime=300 \
      --group_reporting \
      --norandommap

  echo "Scramble complete."
}

log_ssd_state() {
    local LOG_FILE=$1

    local DEV_NAME=$(basename $DEVICE)

    (
        echo "======================================================================="
        echo "SSD State Snapshot for $DEV_NAME : $(date -u --rfc-3339=seconds)"
        echo "======================================================================="
        echo ""
        echo "### SMART/Health Data (smartctl -a) ###"

        if ! sudo smartctl -a $DEVICE; then
            echo "smartctl return $?"
        fi

        echo ""
        echo "### I/O Statistics (/proc/diskstats) ###"

        local diskstats_line=$(grep -w "$DEV_NAME" /proc/diskstats)
        if [ -n "$diskstats_line" ]; then
            echo "$diskstats_line"
            echo "(Fields: 1-major 2-minor 3-devname 4-rd_ios 5-rd_merges 6-rd_sectors ... 10-wr_sectors ...)"
        else
            echo "WARN: Not found $DEV_NAME on /proc/diskstats"
        fi
        echo ""

    ) >> $LOG_FILE

    echo "SSD state for $DEV_NAME logged to $LOG_FILE."
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
    ext4|ext4-dj)
      sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/${FS}_${KEY}.img"
      ;;
    xfs|xfs-cow)
      sudo partclone.xfs -c -s $DEVICE -o "$BACKUP_DIR/${FS}_${KEY}.img"
      ;;
    zfs|zfs-4k|zfs-8k|zfs-16k)
      mount_fs $FS $MOUNT_DIR
      sudo zfs snapshot zfspool@pgbackup
      sudo sh -c "zfs send zfspool@pgbackup > '$BACKUP_DIR/${FS}_${KEY}.img'"
      umount_fs $MOUNT_DIR
      ;;
    taujournal|tau4G|tau8G|tau16G|tau32G)
      sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/taujournal_${KEY}.img"
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
    ext4|ext4-dj)
      sudo partclone.ext4 -r -s $BACKUP_DIR/${FS}_${KEY}.img -o $TAU_DEVICE
      ;;
    xfs|xfs-cow)
      sudo partclone.xfs -r -s $BACKUP_DIR/${FS}_${KEY}.img -o $TAU_DEVICE
      ;;
    zfs|zfs-4k|zfs-8k|zfs-16k)
      do_mkfs $FS $DEVICE
      mount_fs $FS $MOUNT_DIR
      sudo sh -c "zfs receive -F zfspool < '$BACKUP_DIR/${FS}_${KEY}.img'"
      umount_fs $MOUNT_DIR
      ;;
    taujournal|tau4G|tau8G|tau16G|tau32G)
      sudo partclone.ext4 -r -s $BACKUP_DIR/taujournal_${KEY}.img -o $TAU_DEVICE
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
