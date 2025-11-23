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
pg_wal_level() {
  local pgdata="$1"
  local level="$2"   # replica | logical | minimal
  pg_conf_set "$pgdata" "wal_level" "$level"
}
pg_wal_max_set() {
  local pgdata="$1" max="$2"
  pg_conf_set "$pgdata" "max_wal_size" "$max"
}
pg_io_stat() {
  local pgdata="$1"
  pg_conf_set "$pgdata" "track_io_timing" "on"
}
# sed -i "s/^#*max_connections = .*/max_connections = 200/" "$PG_DATA/postgresql.conf"

log_pg_specs() {
  local out_log="$1"
  local dbname="$2"
  local test="$3"
  sleep 1
  {
    echo "===== PostgreSQL Server Info in $test ====="
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

pg_reset_wal_stats() {
  local pguser="$1"
  local pgport="$2"
  local pgbin="$3"
  echo "--> Resetting WAL stats"
  sudo -u "$pguser" "$pgbin/psql" -p "$pgport" -d postgres -c "SELECT pg_stat_reset_shared('wal');"
}

pg_reset_io_stats() {
  local pguser="$1"
  local pgport="$2"
  local pgbin="$3"
  echo "--> Resetting WAL stats"
  sudo -u "$pguser" "$pgbin/psql" -p "$pgport" -d postgres -c "SELECT pg_stat_reset_shared('io');"
}

log_pg_wal_status() {
  local out_log="$1"
  local interval="${2:-5}"
  local count="${3:-0}"
  local i=0
  local max_wal_mb=131072

  echo "===== WAL/FPI ratio logging every ${interval}s =====" >> "$out_log"

  local prev_bytes=0
  local prev_fpi=0

  while :; do
    sleep "$interval"

    local IFS='|'
    read ts bytes fpi <<< $(sudo -u "$PGUSER" "$PG_BIN/psql" -AtX -p "$PG_PORT" -d postgres -c \
      "SELECT to_char(now(),'HH24:MI:SS'), wal_bytes, wal_fpi FROM pg_stat_wal;")

    if (( prev_bytes > 0 )); then
      local delta_bytes=$((bytes - prev_bytes))
      local delta_fpi=$((fpi - prev_fpi))

      if (( delta_bytes > 0 )); then
        local delta_wal_mb=$(awk "BEGIN {printf \"%.1f\", $delta_bytes / 1024 / 1024}")
        local delta_fpi_mb=$(awk "BEGIN {printf \"%.1f\", $delta_fpi * 8192 / 1024 / 1024}")
        local fpi_ratio=$(awk "BEGIN {printf \"%.2f\", ($delta_fpi * 8192 / $delta_bytes) * 100}")

        local used_mb=$(awk "BEGIN {printf \"%.1f\", ($bytes / 1024 / 1024) % $max_wal_mb}")
        local free_mb=$(awk "BEGIN {printf \"%.1f\", $max_wal_mb - $used_mb}")

        echo "$ts | ΔWAL=${delta_wal_mb}MB | ΔFPI=${delta_fpi_mb}MB | FPI_ratio=${fpi_ratio}% | used=${used_mb}MB | free=${free_mb}MB" \
          >> "$out_log"
      fi
    fi

    prev_bytes=$bytes
    prev_fpi=$fpi

    ((count>0)) && { ((++i>=count)) && break; }
  done
}

pg_io_stats_total() {
  local out_log="$1"
  echo "" >> "$out_log"
  echo "===== Final Summary (pg_stat_wal) =====" >> "$out_log"
  sudo -u "$PGUSER" "$PG_BIN/psql" -AtX -p "$PG_PORT" -d postgres -c "
    SELECT
      wal_records,
      wal_fpi,
      wal_bytes,
      ROUND((wal_fpi*8192.0)/NULLIF(wal_bytes,0)*100,2) AS fpi_pct
    FROM pg_stat_wal;
  " >> "$out_log"

  echo "" >> "$out_log"
  echo "===== Final Summary (pg_stat_io, WAL) =====" >> "$out_log"
  sudo -u "$PGUSER" "$PG_BIN/psql" -AtX -p "$PG_PORT" -d postgres -c "
    SELECT
      COALESCE(SUM(write_bytes)/1024/1024,0) AS wal_io_mb,
      COALESCE(SUM(fsyncs),0) AS wal_fsyncs
    FROM pg_stat_io WHERE object='wal';
  " >> "$out_log"

  echo "===== Logging finished at $(date '+%H:%M:%S') =====" >> "$out_log"
}