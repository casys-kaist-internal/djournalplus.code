#!/bin/bash
set -e

### PostgreSQL Configuration
PG_BIN="$TAUFS_BENCH_WS/pg_install/bin"
PG_PORT=5432
PGUSER=$TAU_USERNAME

# Call before starting PostgreSQL
pg_conf_set() {
  local pgdata="$1" key="$2" val="$3" conf="$1/postgresql.conf"

  case "$val" in
    on|off|true|false|0|1) ;;
    *) echo "pg_conf_set: invalid value for $key: $val" >&2; return 2 ;;
  esac

  if [[ ! -f "${conf}.bak" ]]; then
    cp -a "$conf" "${conf}.bak"
  fi

  if grep -Eq "^[[:space:]]*#?[[:space:]]*$key[[:space:]]*=" "$conf"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*($key)[[:space:]]*=.*|\1 = $val|g" "$conf"
  else
    printf "\n%s = %s\n" "$key" "$val" >> "$conf"
  fi
}
pg_fpw() {
  local pgdata="$1" fpw="$2"
  pg_conf_set "$pgdata" "full_page_writes" "$fpw"
}
# sed -i "s/^#*max_connections = .*/max_connections = 200/" "$PG_DATA/postgresql.conf"