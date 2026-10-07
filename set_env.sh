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

# Test Device
TAU_DEVICE=$(nvme list | awk -v model="$TARGET_DISK" '$0 ~ model {print $1; exit}')
if [[ -z "$TAU_DEVICE" ]]; then
  echo "[ERR] cannot find device: $TARGET_DISK" >&2
fi
echo "TAU_DEVICE set to: $TAU_DEVICE"
TAU_DEVICE_NAME="${TAU_DEVICE##*/}"
export TAU_DEVICE
export TAU_DEVICE_NAME

# Backup Device for file system images
TAU_BACKUP_DEVICE=$(nvme list | awk -v model="$BACKUP_DISK" '$0 ~ model {print $1}')
echo "TAU_BACKUP_DEVICE set to: $TAU_BACKUP_DEVICE"
if [[ -z "$TAU_BACKUP_DEVICE" ]]; then
  echo "[ERR] cannot find backup device: $BACKUP_DISK" >&2
fi
export TAU_BACKUP_DEVICE

sudo mkdir -p $TAU_BACKUP_ROOT

if ! mountpoint -q "$TAU_BACKUP_ROOT"; then
  sudo mount "$TAU_BACKUP_DEVICE" "$TAU_BACKUP_ROOT"
  if [ $? -ne 0 ]; then
    echo "mount failed! $TAU_BACKUP_DEVICE"
    return 1
  fi
else
    echo "$TAU_BACKUP_ROOT already mounted"
fi

sudo chown $TAU_USERNAME:$TAU_USERNAME $TAU_BACKUP_ROOT
echo "TAU_BACKUP_ROOT set to: $TAU_BACKUP_ROOT"

# All setting done!
export TAUFS_ENV_SOURCED=1
