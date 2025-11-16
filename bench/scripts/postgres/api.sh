#!/bin/bash
set -e

### PostgreSQL Configuration
PG_BIN="$TAUFS_BENCH_WS/pg_install/bin"
PG_PORT=5432
PGUSER=$TAU_USERNAME

# Call before starting PostgreSQL
pg_conf_set() {
  local pgdata="$1" key="$2" val="$3" conf="$1/postgresql.conf"

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
pg_wal_max_set() {
  local pgdata="$1" max="$2"
  pg_conf_set "$pgdata" "max_wal_size" "$max"
}
# sed -i "s/^#*max_connections = .*/max_connections = 200/" "$PG_DATA/postgresql.conf"

log_pg_specs() {
  local out_log="$1"
  local dbname="$2"
  sleep 1
  {
    echo "===== PostgreSQL Server Info ====="
    date

    echo -e "\n-- Version --"
    sudo -u "$PGUSER" "$PG_BIN/psql" -p "$PG_PORT" -d postgres -c "SELECT version();"

    echo -e "\n-- Settings (fsync/full_page_writes/synchronous_commit/wal_level) --"
    sudo -u "$PGUSER" "$PG_BIN/psql" -p "$PG_PORT" -d postgres -c "
      SHOW fsync;
      SHOW full_page_writes;
      SHOW synchronous_commit;
      SHOW wal_level;
      SHOW max_wal_size;
      SHOW shared_buffers;
      SHOW work_mem;
      SHOW maintenance_work_mem;
    "

    echo -e "\n-- Database Size --"
    sudo -u "$PGUSER" "$PG_BIN/psql" -p "$PG_PORT" -d postgres -c \
      "SELECT pg_size_pretty(pg_database_size('${dbname}')) AS size;"

    echo -e "\n-- Top 10 Tables (size) --"
    sudo -u "$PGUSER" "$PG_BIN/psql" -p "$PG_PORT" -d "${dbname}" -c "
      SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total
      FROM pg_catalog.pg_statio_user_tables
      ORDER BY pg_total_relation_size(relid) DESC
      LIMIT 10;
    "
  } >> "$out_log" 2>&1
}
