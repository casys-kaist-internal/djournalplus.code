#!/bin/bash

# For checking this file is sourced.
export TAUFS_ENV_SOURCED=1

# Set directory paths.
export TAUFS_ROOT=$PWD
export TAUFS_KERNEL=$TAUFS_ROOT/djournalplus-kernel.code
export TAUFS_BENCH=$TAUFS_ROOT/bench
export TAUFS_BENCH_WS=$TAUFS_BENCH/workspace
export PATH=$TAUFS_BENCH_WS/pg_install/bin:$PATH

# Add binary to env path
export PATH=$TAUFS_ROOT/tools/bin:$PATH
export LD_LIBRARY_PATH=$TAUFS_BENCH/workspace/pg_install/lib:$LD_LIBRARY_PATH


#TARGET_DISK="SAMSUNG MZPLJ3T2HBJR-00007"
TARGET_DISK="Samsung SSD 980 PRO"
TAU_DEVICE=$(nvme list | awk -v model="$TARGET_DISK" '$0 ~ model {print $1; exit}')
#TAU_DEVICE="/dev/nvme0n1"

export TAU_DEVICE
echo "TAU_DEVICE set to: $TAU_DEVICE"
