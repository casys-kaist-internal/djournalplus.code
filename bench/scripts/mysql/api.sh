#!/bin/bash
set -e

### MySQL Configuration
MYSQL_BIN="$TAUFS_BENCH/mysql-server/build/bin"
MYSQL_PORT=3306
MYUSER=$TAU_USERNAME

rows_per_table () { # SCALE 5000≈80GB, 10000≈160GB, 20000≈320GB
  local s="$1"
  echo $(( 4480 * s ))
}

wait_for_sock () {
  local path="$1" tries="${2:-60}"
  for i in $(seq 1 "$tries"); do
    [[ -S "$path" ]] && return 0
    sleep 1
  done
  echo "Socket $path not found (timeout)" >&2
  return 1
}