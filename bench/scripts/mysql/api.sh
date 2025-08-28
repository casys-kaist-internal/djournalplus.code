#!/bin/bash
set -e

### MySQL Configuration
MYSQL_BIN="$TAUFS_BENCH/mysql-server/build/bin"
MYSQL_PORT=3306
MYUSER=$TAU_USERNAME

wait_for_sock () {
  local path="$1" tries="${2:-60}"
  for i in $(seq 1 "$tries"); do
    [[ -S "$path" ]] && return 0
    sleep 1
  done
  echo "Socket $path not found (timeout)" >&2
  return 1
}

log_mysql_specs() {
  local sock="$1"
  local out_log="$2"
  local dbname="${3:-}"

  {
    echo "===== MySQL Server Info ====="
    date

    echo -e "\n-- Version --"
    $MYSQL_BIN/mysql -uroot --socket="$sock" -e "SELECT VERSION() AS version\G"

    echo -e "\n-- InnoDB Config --"
    $MYSQL_BIN/mysql -uroot --socket="$sock" -e "
      SHOW VARIABLES LIKE 'innodb_doublewrite';
      SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';
      SHOW VARIABLES LIKE 'innodb_flush_method';
      SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
      SHOW VARIABLES LIKE 'innodb_log_file_size';
      SHOW VARIABLES LIKE 'innodb_file_per_table';
      SHOW VARIABLES LIKE 'sync_binlog';
    "

    echo -e "\n-- Charset/Collation --"
    $MYSQL_BIN/mysql -uroot --socket="$sock" -e "
      SHOW VARIABLES LIKE 'character_set_server';
      SHOW VARIABLES LIKE 'collation_server';
    "

    echo -e "\n-- Database Sizes --"
    if [[ -n "$dbname" ]]; then
      $MYSQL_BIN/mysql -uroot --socket="$sock" -NBe "
        SELECT ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS size_gb
        FROM information_schema.tables
        WHERE table_schema='${dbname}';
      "
    else
      $MYSQL_BIN/mysql -uroot --socket="$sock" -NBe "
        SELECT table_schema,
               ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS size_gb
        FROM information_schema.tables
        GROUP BY table_schema;
      "
    fi
  } >> "$out_log" 2>&1
}