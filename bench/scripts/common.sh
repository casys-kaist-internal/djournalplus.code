#!/bin/bash
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
	echo "Do source set_env.sh first."
	exit
fi

### Common environment setup
DEVICE=$TAU_DEVICE
MOUNT_DIR="/mnt/temp"

warning() {
  echo "WARNING: This will destroy all data on $TAU_DEVICE in 5 seconds."
  echo "Press Ctrl+C to cancel."
  sleep 5
}

# Baseline file systems are made with the unmodified distro mkfs (the system
# binaries are the tau forks); see install_stock_mkfs.sh.
STOCK_DIR=$TAUFS_BENCH_WS/stock

stock_mke2fs() {
  [ -x "$STOCK_DIR/usr/sbin/mke2fs" ] || { echo "No stock mke2fs: run bench/scripts/install_stock_mkfs.sh"; exit 1; }
  sudo env MKE2FS_CONFIG="$STOCK_DIR/etc/mke2fs.conf" "$STOCK_DIR/usr/sbin/mke2fs" "$@"
}

stock_mkfs_xfs() {
  [ -x "$STOCK_DIR/sbin/mkfs.xfs" ] || { echo "No stock mkfs.xfs: run bench/scripts/install_stock_mkfs.sh"; exit 1; }
  sudo "$STOCK_DIR/sbin/mkfs.xfs" "$@"
}

do_mkfs() {
  local FS=$1
  local DEVICE=$2
  warning
  echo "[+] Formatting $FS on $DEVICE"

  case $FS in
    ext4)
      stock_mke2fs -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    ext4-dj10)
      stock_mke2fs -t ext4  -J size=10000 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    ext4-dj20)
      stock_mke2fs -t ext4  -J size=20000 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    ext4-dj40)  # largest journal mke2fs allows: 10240000 blocks
      stock_mke2fs -t ext4  -J size=40000 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
      ;;
    f2fs)
      sudo mkfs.f2fs -f $DEVICE
      ;;
    btrfs|btrfs-nodatacow)
      sudo mkfs.btrfs -f $DEVICE
      ;;
    xfs|xfs-cow)
      stock_mkfs_xfs -f $DEVICE
      ;;
    zfs)
      sudo wipefs -a $DEVICE
      sudo zpool destroy -f zfspool || true
      sudo zpool create -o ashift=12 zfspool $DEVICE
      ;;
    zfs-8k|zfs-16k)  # recordsize = DB page (PG 8k, MySQL 16k), no compression
      # destroy first: a pool re-imported at boot keeps the device busy for wipefs
      sudo zpool destroy -f zfspool || true
      sudo wipefs -a $DEVICE
      # OpenZFS Workload Tuning (InnoDB, PostgreSQL): separate datasets for the
      # data and the WAL/redo, logbias=throughput on the data. With the default
      # (latency) the pages an fsync commits (under 32K) are copied into the
      # ZIL, and a copy split across two log blocks can replay half new
      # (openzfs/zfs#17879; tools/killtest/results/libra09/SUMMARY.md §3.3).
      # WAL/redo stay at the defaults (recordsize 128K, logbias latency) in
      # zfspool/log, at $MOUNT_DIR/log (db_log_dir).
      sudo zpool create -o ashift=12 -O recordsize=${FS#zfs-} -O compression=off \
          -O logbias=throughput zfspool $DEVICE
      sudo zfs create -o recordsize=128k -o logbias=latency zfspool/log
      ;;
    xfs-tau)
      sudo mkfs.xfs $DEVICE -f -l tjmaxsize=1G
      ;;
    ext4-tau)
      sudo $TAUFS_E2FSPROGS/misc/mke2fs -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F $DEVICE
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
    ext4-dj10|ext4-dj20|ext4-dj40)
      sudo mount -t ext4 -o data=journal $DEVICE $MOUNT_DIR
      ;;
    f2fs)
      sudo mount -t f2fs $DEVICE $MOUNT_DIR
      ;;
    btrfs)
      sudo mount -t btrfs $DEVICE $MOUNT_DIR
      ;;
    btrfs-nodatacow)  # files created on it skip CoW (and data checksums): the no-CoW floor
      sudo mount -t btrfs -o nodatacow $DEVICE $MOUNT_DIR
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
    zfs-8k|zfs-16k)  # zfspool/log inherits the mountpoint: $MOUNT_DIR/log
      sudo zfs set recordsize=${FS#zfs-} compression=off logbias=throughput zfspool
      sudo zfs set mountpoint=$MOUNT_DIR zfspool
      ;;
    ext4-tau)
      sudo mount -t ext4 -o tjournal,tjournal_size=32  $DEVICE $MOUNT_DIR
      ;;
    xfs-tau)
      sudo mount -t xfs -o tjournal $DEVICE $MOUNT_DIR
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
}

clear_fs() {
  local FS=$1
  local DEVICE=$2

  case $FS in
    ext4|ext4-dj10|ext4-dj20|ext4-dj40|ext4-tau)
      ;;
    f2fs)
      ;;
    btrfs|btrfs-nodatacow)
      ;;
    xfs|xfs-cow)
      ;;
    zfs|zfs-8k|zfs-16k)
      sudo zpool export zfspool || true
      ;;
    xfs-tau|xfs-tau1G|xfs-tau4G|xfs-tau8G|xfs-tau16G|xfs-tau32G)
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
  sudo wipefs -a $DEVICE
}


umount_fs() {
  MOUNT_DIR=$1
  # -R: zfs-8k/16k mount zfspool/log inside $MOUNT_DIR
  sudo umount -R $MOUNT_DIR || sudo zfs umount -a
}

# db_log_dir <fs>: where the WAL/redo go when not in the database directory --
# zfspool/log on the zfs-8k/zfs-16k pools (do_mkfs) -- or nothing.
db_log_dir() {
  case $1 in
    zfs-8k|zfs-16k) echo "$MOUNT_DIR/log" ;;
  esac
}

warming_up_ssd() {
  warning
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
    ext4|ext4-dj10|ext4-dj20|ext4-dj40|ext4-tau)
      sudo partclone.ext4 -c -s $DEVICE -o "$BACKUP_DIR/${FS}_${KEY}.img"
      ;;
    xfs|xfs-cow|xfs-tau)
      sudo partclone.xfs -c -s $DEVICE -o "$BACKUP_DIR/${FS}_${KEY}.img"
      ;;
    btrfs|btrfs-nodatacow)
      sudo partclone.btrfs -c -s $DEVICE -o "$BACKUP_DIR/${FS}_${KEY}.img"
      ;;
    zfs)
      mount_fs $FS $MOUNT_DIR
      sudo zfs snapshot zfspool@pgbackup
      sudo sh -c "zfs send zfspool@pgbackup > '$BACKUP_DIR/${FS}_${KEY}.img'"
      umount_fs $MOUNT_DIR
      ;;
    zfs-8k|zfs-16k)  # replication stream: keeps recordsize and compression
      mount_fs $FS $MOUNT_DIR
      sudo zfs snapshot -r zfspool@pgbackup
      sudo sh -c "zfs send -R zfspool@pgbackup > '$BACKUP_DIR/${FS}_${KEY}.img'"
      umount_fs $MOUNT_DIR
    ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
}

restore_filesystem() {
  local FS=$1
  local KEY=$2
  local BACKUP_DIR=$3
  warning
  echo "[+] Restoring filesystem: $FS"

  case $FS in
    ext4|ext4-dj10|ext4-dj20|ext4-dj40|ext4-tau)
      sudo partclone.ext4 -r -s $BACKUP_DIR/${FS}_${KEY}.img -o $TAU_DEVICE
      ;;
    xfs|xfs-cow|xfs-tau)
      sudo partclone.xfs -r -s $BACKUP_DIR/${FS}_${KEY}.img -o $TAU_DEVICE
      ;;
    btrfs|btrfs-nodatacow)
      sudo partclone.btrfs -r -s $BACKUP_DIR/${FS}_${KEY}.img -o $TAU_DEVICE
      ;;
    zfs|zfs-4k|zfs-8k|zfs-16k)
      do_mkfs $FS $DEVICE
      # zfs-8k/16k: the replication stream brings zfspool/log with it
      sudo zfs destroy zfspool/log 2>/dev/null || true
      mount_fs $FS $MOUNT_DIR
      sudo sh -c "zfs receive -F zfspool < '$BACKUP_DIR/${FS}_${KEY}.img'"
      umount_fs $MOUNT_DIR
      ;;
    *)
      echo "Unknown FS: $FS"; exit 1;;
  esac
  sleep 1
  drop_caches
}

# 32 tables with 10M rows about 80GB database size
motivation_rows_per_table () { 
  local tables="$1"
  echo $(( 320000000 / tables )) # 320M
}

main_rows_per_table () { 
  local tables="$1"
  echo $(( 640000000 / tables )) # 640M
}

# Main dataset for the revision: a fixed row count instead of one derived from
# the table count. 16 x 32M rows measured at 254 B/row (PG) and 242 B/row
# (MySQL), i.e. ~121 GiB / ~115 GiB. Images are keyed by it
# (<fs>_t16_r32000000.img) so they never collide with the older s<tables> ones.
MAIN_TABLES=16
MAIN_ROWS_PER_TABLE=32000000

main_image_key () {
  echo "t${MAIN_TABLES}_r${MAIN_ROWS_PER_TABLE}"
}

# /proc/diskstats lines of the test device (sector = 512 B), taken before and
# after each measurement for the device-level I/O volume. With NVMe multipath
# the I/O is accounted on the path node (nvme0c0n1), not on nvme0n1.
log_dev_stat() {
  local tag="$1" out="$2" re="^${TAU_DEVICE_NAME}\$"
  if [[ "$TAU_DEVICE_NAME" =~ ^(nvme[0-9]+)(n[0-9]+)$ ]]; then
    re="^${BASH_REMATCH[1]}(c[0-9]+)?${BASH_REMATCH[2]}\$"
  fi
  awk -v t="$tag" -v re="$re" '$3 ~ re {print t, $0}' /proc/diskstats >> "$out"
  # swapping and major faults during the measurement (pages)
  echo "$tag $(awk '/^(pswpin|pswpout|pgmajfault) /{printf "%s=%s ", $1, $2}' /proc/vmstat)" >> "$out"
  # CPU time of all CPUs (USER_HZ ticks), for the CPU utilization
  echo "$tag $(awk '/^cpu /{printf "cpu_user=%s cpu_nice=%s cpu_system=%s cpu_idle=%s cpu_iowait=%s cpu_irq=%s cpu_softirq=%s", $2, $3, $4, $5, $6, $7, $8}' /proc/stat)" >> "$out"
}

# Block devices that account the test SSD's I/O: the path nodes of a multipath
# NVMe namespace (nvme0c0n1 for nvme0n1), else the device itself.
tau_stat_devs() {
  local devs=""
  if [[ "$TAU_DEVICE_NAME" =~ ^(nvme[0-9]+)(n[0-9]+)$ ]]; then
    devs=$(awk -v re="^${BASH_REMATCH[1]}c[0-9]+${BASH_REMATCH[2]}\$" '$3 ~ re {print $3}' /proc/diskstats)
  fi
  echo ${devs:-$TAU_DEVICE_NAME}
}

# Per-second device and CPU statistics in the background, the time series
# behind the .io totals. iostat on nvme0n1 itself shows no I/O and a bogus
# %util, so this records the path node. It exits by itself after <max seconds>
# even if the caller dies. iostat_start <out file> <max seconds>; iostat_stop
iostat_start() {
  S_TIME_FORMAT=ISO iostat -xmty 1 "$2" $(tau_stat_devs) > "$1" 2>&1 &
  IOSTAT_PID=$!
}

iostat_stop() {
  [[ -n "$IOSTAT_PID" ]] || return 0
  kill "$IOSTAT_PID" 2>/dev/null || true
  wait "$IOSTAT_PID" 2>/dev/null || true
  IOSTAT_PID=
}

# Where a process's memory sits: MB per NUMA node and the memory policies of its
# mappings, from /proc/<pid>/numa_maps. log_numa_maps <pid> <out file>
log_numa_maps() {
  echo "numa_maps pid $1: $(awk '{
      kb = 4; pol[$2]++
      for (i = 3; i <= NF; i++) if ($i ~ /^kernelpagesize_kB=/) { split($i, a, "="); kb = a[2] }
      for (i = 3; i <= NF; i++) if ($i ~ /^N[0-9]+=/) { split($i, a, "="); mb[a[1]] += a[2] * kb / 1024 }
    } END { for (k in mb) printf "%s=%.0fMB ", k, mb[k]; for (k in pol) printf "[%s x%d] ", k, pol[k] }' \
    /proc/$1/numa_maps 2>/dev/null)" >> "$2"
}

# Host settings that can change results (machine_info.sh), once per result directory.
log_env() {
  local out="$1"
  bash "$TAUFS_BENCH/scripts/machine_info.sh" "$TAU_DEVICE_NAME" >> "$out" 2>&1
}


# 2. 극단적 지연 모드 함수 (켜기)
extreme_memory() {
    echo "========================================"
    echo " [!] 극단적 지연 모드 (Extreme) 켜기"
    echo "========================================"
    sudo sysctl -w vm.dirty_ratio=100
    sudo sysctl -w vm.dirty_background_ratio=99
    sudo sysctl -w vm.dirty_writeback_centisecs=0
    sudo sysctl -w vm.dirty_expire_centisecs=86400000
    echo "-> 완료: 쓰기 작업이 최대한 RAM에만 쌓입니다."
    echo "-> 주의: 이 상태에서 전원이 나가면 데이터가 손실됩니다!"
}

# 3. 기본 모드 복구 함수 (끄기)
restore_default_memory() {
    echo "========================================"
    echo " [*] 기본 모드 (Default) 복구 중..."
    echo "========================================"
    sudo sysctl -w vm.dirty_ratio=20
    sudo sysctl -w vm.dirty_background_ratio=10
    sudo sysctl -w vm.dirty_writeback_centisecs=500
    sudo sysctl -w vm.dirty_expire_centisecs=3000
    echo "-> 커널 설정 복구 완료."
    
    echo "-> 메모리에 밀린 데이터를 디스크로 동기화(sync) 합니다. 잠시만 기다려주세요..."
    sync
    echo "-> 동기화 완료! 시스템이 안전한 상태로 돌아왔습니다."
}