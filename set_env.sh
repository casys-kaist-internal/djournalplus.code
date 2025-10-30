#!/bin/bash

# For checking this file is sourced.
export TAU_USERNAME=$(whoami)

# Set directory paths.
export TAUFS_ROOT=$PWD
export TAUFS_KERNEL=$TAUFS_ROOT/djournalplus-kernel.code
export TAUFS_BENCH=$TAUFS_ROOT/bench
export TAUFS_BENCH_WS=$TAUFS_BENCH/workspace
export TAU_BACKUP_ROOT=/mnt/tau_backup


# Add binary to env path
export PATH=$TAUFS_ROOT/tools/bin:$PATH
export LD_LIBRARY_PATH=$TAUFS_BENCH/mysql-server/build/lib:$TAUFS_BENCH/workspace/pg_install/lib:$LD_LIBRARY_PATH
export PATH=$TAUFS_BENCH_WS/pg_install/bin:$PATH
export PATH=$TAUFS_BENCH/mysql-server/build/bin/:$PATH

# Test Device
# TARGET_DISK="Samsung SSD 980 PRO"
TARGET_DISK="SAMSUNG MZPLJ3T2HBJR-00007"
TAU_DEVICE=$(nvme list | awk -v model="$TARGET_DISK" '$0 ~ model {print $1; exit}')
if [[ -z "$TAU_DEVICE" ]]; then
  echo "[ERR] cannot find device: $TARGET_DISK" >&2
fi
echo "TAU_DEVICE set to: $TAU_DEVICE"
TAU_DEVICE_NAME="${TAU_DEVICE##*/}"
export TAU_DEVICE
export TAU_DEVICE_NAME

# Backup Device for file system images
BACKUP_DISK="PM1753V8TLC"
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
