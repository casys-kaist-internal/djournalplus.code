#!/bin/bash
set -e

PG_BIN="$TAUFS_BENCH_WS/pg_install/bin"
PGUSER=$TAU_USERNAME
DEVICE=$TAU_DEVICE
BACKUP_DIR=$TAU_BACKUP_ROOT/pgbench
MOUNT_DIR="/mnt/temp"

# Call before starting PostgreSQL
pg_fpw() {
    PG_DATA=$1
    FPW=$2
    sed -i "s/^#*full_page_writes = .*/full_page_writes = $FPW/" "$PG_DATA/postgresql.conf"
}

# sed -i "s/^#*max_connections = .*/max_connections = 200/" "$PG_DATA/postgresql.conf"