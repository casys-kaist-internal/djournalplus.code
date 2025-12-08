#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

# Filesystem groups
declare -A FS_GROUPS

FS_GROUPS[on]=""
FS_GROUPS[off]="tau16G"

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
source "$TAUFS_BENCH/scripts/tpcc/common.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/tpcc/$MODE
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/tpcc/$MODE/$DATE"
mkdir -p "$RESULT_DIR"

declare -A REPLACEMENTS

TOTAL_ITERATION=1000000000
DURATION=10
RAMPUP=10
VU_LIST=(32)
#VU_LIST=(4 8 16 32 48 64)

# IO capture helper
iostat_start() {
    DEVICE_NAME=$(basename "$TAU_DEVICE")
    LOG_FILE=$1
    iostat -dmx 1 "$DEVICE_NAME" > "$LOG_FILE" &
    IOSTAT_PID=$!
}
iostat_end() {
    if [[ -n "$IOSTAT_PID" ]]; then
        kill "$IOSTAT_PID"
        wait "$IOSTAT_PID" 2>/dev/null || true
    fi
}

## Start here
# MAIN LOOP
for FPW in on off; do
  for FS in ${FS_GROUPS[$FPW]}; do
    for WAREHOUSE in "${WAREHOUSE_LIST[@]}"; do
      for VU in "${VU_LIST[@]}"; do
        LABEL="${MODE}_${FS}_fpw_${FPW}_w${WAREHOUSE}_v${VU}_i${TOTAL_ITERATION}_d${DURATION}_r${RAMPUP}"
        OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
        OUT_ERR="$RESULT_DIR/${LABEL}.error"
        OUT_LOG="$RESULT_DIR/${LABEL}.log"
        # IOLOG="$RESULT_DIR/${LABEL}_iostat.log"

        echo "=== Setting up FS: $FS (FPW=$FPW) in device($DEVICE) ==="
        restore_filesystem $FS "w$WAREHOUSE" $BACKUP_DIR
        mount_fs $FS $MOUNT_DIR

        REPLACEMENTS=(
          ["VU"]=$VU
          ["WAREHOUSE"]=$WAREHOUSE
          ["ITERATIONS"]=$TOTAL_ITERATION
          ["DURATION"]=$DURATION
          ["RAMPUP"]=$RAMPUP
        )

        case "$MODE" in
          postgres)
            PG_DATA="$MOUNT_DIR/postgres"
            pg_fpw $PG_DATA $FPW
            if [[ "$FPW" == "on" ]]; then
              WALSIZE="16GB"
            else
              WALSIZE="2GB"
            fi
            $PG_BIN/pg_ctl -D $PG_DATA start
            pg_wal_max_set $PG_DATA $WALSIZE
            log_pg_specs "$OUT_DBSPEC" "$DBNAME"

            pushd $HAMMERDB

            echo "--> Benchmarking $LABEL"
            RUN_TCL="$HAMMERDB/run_${LABEL}.tcl"
            render_tcl_template "$HAMMERDB/run_postgres_template.tcl" $RUN_TCL REPLACEMENTS
            ./hammerdbcli auto $RUN_TCL > "$OUT_LOG" 2> "$OUT_ERR"

            popd

            $PG_BIN/psql -d postgres -c "CHECKPOINT;"
            $PG_BIN/pg_ctl -D $PG_DATA stop
            umount_fs $MOUNT_DIR
          ;;
          mysql)
            MY_DATA="$MOUNT_DIR/mysql"
            MY_SOCK="$MY_DATA/mysql.sock"
            DBW=$(FPW="on" && echo "1" || echo "0")
            REPLACEMENTS["MYSOCKET"]=$MY_SOCK

            echo "[*] Start mysqld"
            $MYSQL_BIN/mysqld \
                --datadir="$MY_DATA" \
                --socket="$MY_SOCK" \
                --port="$MYSQL_PORT" \
                --pid-file="$MY_DATA/mysqld.pid" \
                --bind-address=127.0.0.1 \
                --skip-networking=0 \
                --log-error="$MY_DATA/mysqld.err" \
                --innodb-doublewrite=$DBW &
            wait_for_sock "$MY_SOCK" 60

            log_mysql_specs $MY_SOCK $OUT_DBSPEC $DBNAME

            pushd $HAMMERDB

            echo "--> Benchmarking $LABEL"
            RUN_TCL="$HAMMERDB/run_${LABEL}.tcl"
            render_tcl_template "$HAMMERDB/run_mysql_template.tcl" $RUN_TCL REPLACEMENTS
            ./hammerdbcli auto $RUN_TCL > "$OUT_LOG" 2> "$OUT_ERR"

            popd

            $MYSQL_BIN/mysql -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
            $MYSQL_BIN/mysqladmin -uroot --socket="$MY_SOCK" shutdown

            umount_fs $MOUNT_DIR

            echo "--> Done: $LABEL"
          ;;
        esac
      done
    done
    echo "=== FS: $FS Done ==="
    clear_fs $FS $DEVICE
    sleep 30  # Cooling down
  done
done

echo "=== All benchmarks completed ==="
