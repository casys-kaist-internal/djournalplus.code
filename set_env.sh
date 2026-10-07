#!/bin/bash

# For checking this file is sourced.
export TAU_USERNAME=$(whoami)

# Set directory paths.
export TAUFS_ROOT=$PWD
# The system sources, submodules under codes/: the tau kernel and the
# mke2fs/mkfs.xfs forks (a machine's .env, read below, may point elsewhere)
export TAUFS_KERNEL=$TAUFS_ROOT/codes/djournalplus-kernel.code
export TAUFS_E2FSPROGS=$TAUFS_ROOT/codes/e2fsprogs
export TAUFS_XFSPROGS=$TAUFS_ROOT/codes/xfsprogs-dev
export TAUFS_BENCH=$TAUFS_ROOT/bench
export TAUFS_BENCH_WS=$TAUFS_BENCH/workspace
export TAU_BACKUP_ROOT=/mnt/tau_backup


# Add binary to env path
export PATH=$TAUFS_ROOT/tools/bin:$PATH
export LD_LIBRARY_PATH=$TAUFS_BENCH/mysql-server/build/lib:$TAUFS_BENCH/workspace/pg_install/lib:$LD_LIBRARY_PATH
export PATH=$TAUFS_BENCH_WS/pg_install/bin:$PATH
export PATH=$TAUFS_BENCH/mysql-server/build/bin/:$PATH

# This machine's settings: bench/machines/<host>.env (the SSDs, the memory the
# benchmarks see); a new machine starts from a copy of libra09.env
export TAU_HOST=$(hostname -s)
TAU_MACHINE_ENV=$TAUFS_BENCH/machines/$TAU_HOST.env
if [[ ! -f "$TAU_MACHINE_ENV" ]]; then
  echo "[ERR] no $TAU_MACHINE_ENV: copy bench/machines/libra09.env and edit it" >&2
  return 1
fi
source "$TAU_MACHINE_ENV"
export TAU_MEM_GB TAU_BOOT_ARGS TAU_DB_CACHE_GB TAU_ZFS_ARC_GB
# Results stay outside git, per machine
export TAU_RESULTS=$TAUFS_BENCH_WS/results/$TAU_HOST

# The test device and the backup device (file system images) are picked from
# `nvme list` by a pattern matched against the whole line: the model, or the
# serial when two disks share a model (libra08's two 980 PROs do, and one of
# them is another user's).  Exactly one device has to match, and the test
# device must not be in use: the bench scripts mkfs, fio and partclone it
# without asking.  Sourced by zsh as well as bash.
tau_pick_nvme() {  # <pattern> <what>: prints the one /dev/nvmeXnY it matches
  local devs n
  if [[ -z "$1" ]]; then
    echo "[ERR] $2: no pattern in $TAU_MACHINE_ENV" >&2
    return 1
  fi
  devs=$(nvme list 2>/dev/null | awk -v pat="$1" '$1 ~ "^/dev/" && $0 ~ pat {print $1}')
  n=$(printf '%s' "$devs" | grep -c .)
  if [[ $n -ne 1 ]]; then
    echo "[ERR] $2: $n NVMe devices match '$1' $(echo $devs | tr '\n' ' ')" >&2
    return 1
  fi
  echo "$devs"
}
tau_in_use() {  # <disk>: its mounts (partitions and swap too) and dm/md/LVM users
  lsblk -nro NAME,TYPE,MOUNTPOINT "$1" 2>/dev/null |
    awk '$3 != "" || ($2 != "disk" && $2 != "part")'
}

# Test Device
TAU_DEVICE=$(tau_pick_nvme "$TARGET_DISK" "test device")
if [[ -n "$TAU_DEVICE" && -n "$(tau_in_use "$TAU_DEVICE")" ]]; then
  echo "[ERR] test device $TAU_DEVICE is in use, not using it:" >&2
  tau_in_use "$TAU_DEVICE" >&2
  TAU_DEVICE=
fi
echo "TAU_DEVICE set to: $TAU_DEVICE"
TAU_DEVICE_NAME="${TAU_DEVICE##*/}"
export TAU_DEVICE
export TAU_DEVICE_NAME

# Backup Device for file system images.  BACKUP_DISK="" is a machine without
# one: whatever is mounted at TAU_BACKUP_ROOT is used, or nothing, and then
# only the image scripts fail.
TAU_BACKUP_DEVICE=
if [[ -n "$BACKUP_DISK" ]]; then
  TAU_BACKUP_DEVICE=$(tau_pick_nvme "$BACKUP_DISK" "backup device") || return 1
  if [[ "$TAU_BACKUP_DEVICE" == "$TAU_DEVICE" ]]; then
    echo "[ERR] TARGET_DISK and BACKUP_DISK match the same disk $TAU_DEVICE" >&2
    return 1
  fi
fi
echo "TAU_BACKUP_DEVICE set to: $TAU_BACKUP_DEVICE"
export TAU_BACKUP_DEVICE

if mountpoint -q "$TAU_BACKUP_ROOT"; then
  echo "$TAU_BACKUP_ROOT already mounted"
elif [[ -n "$TAU_BACKUP_DEVICE" ]]; then
  # mounted elsewhere is someone else's file system: no second mount, no chown
  if [[ -n "$(tau_in_use "$TAU_BACKUP_DEVICE")" ]]; then
    echo "[ERR] backup device $TAU_BACKUP_DEVICE is in use, not mounting it:" >&2
    tau_in_use "$TAU_BACKUP_DEVICE" >&2
    return 1
  fi
  sudo mkdir -p $TAU_BACKUP_ROOT
  sudo mount "$TAU_BACKUP_DEVICE" "$TAU_BACKUP_ROOT"
  if [ $? -ne 0 ]; then
    echo "mount failed! $TAU_BACKUP_DEVICE"
    return 1
  fi
else
  echo "[WARN] no image store: BACKUP_DISK is empty and $TAU_BACKUP_ROOT is not mounted" >&2
fi

if mountpoint -q "$TAU_BACKUP_ROOT"; then
  sudo chown $TAU_USERNAME:$TAU_USERNAME $TAU_BACKUP_ROOT
  echo "TAU_BACKUP_ROOT set to: $TAU_BACKUP_ROOT"
fi

# All setting done!
export TAUFS_ENV_SOURCED=1
