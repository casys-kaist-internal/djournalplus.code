#!/bin/bash
# Shared by the BenchBase TPC-C scripts (pilot_tpcc.sh, create_image.sh,
# run_tpcc.sh), sourced after common.sh and <db>/api.sh with MODE (postgres or
# mysql), OUT (result directory), WH (warehouses) and TERMINALS set:
#   q, db_init, db_start, db_stop, set_fpw, db_fs_settings, db_counters   the database
#   bb_config, bb                                          BenchBase
#   tpcc_run                                               one measured run
BB="$TAUFS_BENCH_WS/benchbase/$MODE"
[[ -f "$BB/benchbase.jar" ]] || { echo "❌ no $BB/benchbase.jar (bench/scripts/benchbase/install.sh)"; exit 1; }

case "$MODE" in
  postgres)
    PG_DATA="$MOUNT_DIR/pgsql_data"
    q() { $PG_BIN/psql -XAt -F ' ' -h 127.0.0.1 -p "$PG_PORT" -d tpcc -c "$1"; }
    db_init() {  # a new cluster with the tpcc database, FPW off, running
      sudo mkdir -p "$PG_DATA"
      sudo chown -R "$PGUSER:$PGUSER" "$PG_DATA"
      $PG_BIN/initdb -D "$PG_DATA" > "$OUT/initdb.log"
      pg_fpw "$PG_DATA" off
      pg_fixed_settings "$PG_DATA"
      db_start
      $PG_BIN/createdb -h 127.0.0.1 -p "$PG_PORT" tpcc
    }
    db_start() { $PG_BIN/pg_ctl -D "$PG_DATA" -l "${SERVER_LOG:-$OUT/server.log}" start; }
    db_stop() { $PG_BIN/pg_ctl -D "$PG_DATA" -t 600 stop; }
    set_fpw() { pg_fpw "$PG_DATA" "$1"; }
    db_counters() { log_pg_io_counters "$1" "$2"; }
    TYPE=POSTGRES DRIVER=org.postgresql.Driver DB_USER=$PGUSER ISOLATION=TRANSACTION_READ_COMMITTED
    URL="jdbc:postgresql://127.0.0.1:$PG_PORT/tpcc?sslmode=disable&amp;ApplicationName=tpcc&amp;reWriteBatchedInserts=true"
    ;;
  mysql)
    MY_DATA="$MOUNT_DIR/mysql_data"
    MY_SOCK="$MY_DATA/mysql.sock"
    DBW=OFF
    q() { $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -NBe "$1" tpcc; }
    db_init() {  # a new datadir (redo log pre-created at run-time size) with tpcc, running
      sudo mkdir -p "$MY_DATA"
      sudo chown -R "$MYUSER:$MYUSER" "$MY_DATA"
      $MYSQL_BIN/mysqld --initialize-insecure --datadir="$MY_DATA" \
          --innodb_redo_log_capacity=$MY_REDO_LOG_CAPACITY
      db_start
      $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "CREATE DATABASE tpcc"
    }
    db_start() { start_mysqld "$MY_DATA" "$MY_SOCK" "$DBW" "${SERVER_LOG:-$OUT/server.log}"; }
    db_stop() {
      $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown
      wait "$MYSQLD_PID" || true
    }
    set_fpw() { if [[ "$1" == on ]]; then DBW=ON; else DBW=OFF; fi; }
    db_counters() { log_mysql_io_counters "$MY_SOCK" "$1" "$2"; }
    TYPE=MYSQL DRIVER=com.mysql.cj.jdbc.Driver DB_USER=root ISOLATION=TRANSACTION_REPEATABLE_READ
    URL="jdbc:mysql://127.0.0.1:$MYSQL_PORT/tpcc?rewriteBatchedStatements=true&amp;allowPublicKeyRetrieval=True&amp;sslMode=DISABLED"
    ;;
esac

# File-system settings as run_main.sh: PG on btrfs/ZFS without WAL zero-fill and
# recycling (pg_cow_settings); on zfs-8k/16k the WAL/redo in zfspool/log
# (copy_image.sh puts them there)
db_fs_settings() {  # <fs>
  local log_dir
  log_dir=$(db_log_dir "$1")
  case "$MODE" in
    postgres)
      case $1 in btrfs|zfs*) pg_cow_settings "$PG_DATA" ;; esac
      if [[ -n "$log_dir" && ! -L "$PG_DATA/pg_wal" ]]; then
        echo "❌ $PG_DATA/pg_wal is not a link into $log_dir"
        exit 1
      fi
      ;;
    mysql)
      MY_EXTRA_ARGS=${log_dir:+--innodb_log_group_home_dir=$log_dir}
      ;;
  esac
}

# BenchBase configuration: 32 loader threads, rate unlimited, the standard mix,
# no think time, the databases' default isolation (EVAL_PLAN)
bb_config() {  # <file> <randomWarehouse: true|false> <measured s> <warm-up s>
  cat > "$1" <<EOF
<?xml version="1.0"?>
<parameters>
    <type>$TYPE</type>
    <driver>$DRIVER</driver>
    <url>$URL</url>
    <username>$DB_USER</username>
    <password></password>
    <isolation>$ISOLATION</isolation>
    <batchsize>128</batchsize>
    <loaderThreads>32</loaderThreads>
    <scalefactor>$WH</scalefactor>
    <terminals>$TERMINALS</terminals>
    <randomWarehouse>$2</randomWarehouse>
    <works>
        <work>
            <time>$3</time>
            <warmup>$4</warmup>
            <rate>unlimited</rate>
            <weights>45,43,4,4,4</weights>
        </work>
    </works>
    <transactiontypes>
        <transactiontype><name>NewOrder</name></transactiontype>
        <transactiontype><name>Payment</name></transactiontype>
        <transactiontype><name>OrderStatus</name></transactiontype>
        <transactiontype><name>Delivery</name></transactiontype>
        <transactiontype><name>StockLevel</name></transactiontype>
    </transactiontypes>
</parameters>
EOF
}

bb() {  # <name> <benchbase options...>: BenchBase with $OUT/<name>.xml, timed
  local name=$1 rc=0
  shift
  ( cd "$BB" && /usr/bin/time -f "elapsed=%e user=%U sys=%S" -o "$OUT/$name.jvm_time" \
      java -jar benchbase.jar -b tpcc -c "$OUT/$name.xml" "$@" > "$OUT/$name.log" 2>&1 ) || rc=$?
  echo "exit=$rc" >> "$OUT/$name.jvm_time"
  (( rc == 0 )) || echo "    ❗ BenchBase exited with $rc (see $name.log)"
}

# One run on the running database: the districts' d_next_o_id, the device and
# WAL/redo/doublewrite counters (<name>.io) and mpstat around BenchBase
tpcc_run() {  # <name> <randomWarehouse> <measured s> <warm-up s> [FPW/DWB, recorded]
  local name=$1 mp
  bb_config "$OUT/$name.xml" "$2" "$3" "$4"
  echo "fpw=${5:-off}" > "$OUT/$name.io"
  q "SELECT d_w_id, d_id, d_next_o_id FROM district ORDER BY 1, 2" > "$OUT/$name.district_before"
  log_dev_stat begin "$OUT/$name.io"
  db_counters begin "$OUT/$name.io"
  # longer than the run (BenchBase's start and its output writing take a minute)
  S_TIME_FORMAT=ISO mpstat 1 $(($3 + $4 + 120)) > "$OUT/$name.mpstat" 2>&1 &
  mp=$!
  bb "$name" --execute=true -d "$OUT/$name" -s 1 -jh "$OUT/$name.histograms.json"
  kill "$mp" 2>/dev/null || true
  wait "$mp" 2>/dev/null || true
  log_dev_stat end "$OUT/$name.io"
  db_counters end "$OUT/$name.io"
  q "SELECT d_w_id, d_id, d_next_o_id FROM district ORDER BY 1, 2" > "$OUT/$name.district_after"
  echo "    $(tr '\n' ' ' < "$OUT/$name.jvm_time")"
}
