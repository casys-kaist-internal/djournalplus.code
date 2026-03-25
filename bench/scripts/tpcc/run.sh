#!/bin/bash
set -e

MODE="${1:-}"  # postgres | mysql
if [[ "$MODE" != "postgres" && "$MODE" != "mysql" ]]; then
  echo "Usage: $0 {postgres|mysql}"
  exit 1
fi

# Filesystem groups
declare -A FS_GROUPS

FS_GROUPS[on]="ext4"
FS_GROUPS[off]="ext4"

source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$MODE/api.sh"
source "$TAUFS_BENCH/scripts/tpcc/common.sh"

BACKUP_DIR=$TAU_BACKUP_ROOT/tpcc/$MODE
DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAUFS_BENCH_WS/results/tpcc/$MODE/$DATE"
mkdir -p "$RESULT_DIR"

declare -A REPLACEMENTS
declare -A IO_REPLACEMENTS

ITERATION=1000000000
DURATION=10
RAMPUP=10
# VU_LIST=(4 8 16 32 64)
VU_LIST=(1 16)

IO_ITERATION=1000000 # 1M
IO_DURATION=100
IO_RAMPUP=0

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

wait_for_hammerdb_completion() {
    local out_log=$1
    local vu=$2
    local hammer_pid=$3

    local count=0
    while true; do
        count=$(grep -c "FINISHED SUCCESS" "$out_log" 2>/dev/null || true)
        echo "[INFO] Completed $count / $vu"

        if (( count >= vu )); then
            echo "[INFO] All Vusers finished. Stopping hammerdbcli..."
            kill "$hammer_pid" 2>/dev/null
            sleep 2
            if ps -p "$hammer_pid" > /dev/null; then
                echo "[WARN] hammerdbcli still running, force killing..."
                kill -9 "$hammer_pid" 2>/dev/null
            fi
            echo "[INFO] HammerDB terminated."
            break
        fi

        sleep 5
    done
}

## Start here
# MAIN LOOP
for FPW in on off; do
  for FS in ${FS_GROUPS[$FPW]}; do
    for WAREHOUSE in "${WAREHOUSE_LIST[@]}"; do
      for VU in "${VU_LIST[@]}"; do
        # LABEL="${MODE}_${FS}_fpw_${FPW}_w${WAREHOUSE}_v${VU}_i${ITERATION}_d${DURATION}_r${RAMPUP}"
        LABEL="${MODE}_${FS}_fpw_${FPW}_w${WAREHOUSE}_v${VU}"
        OUT_DBSPEC="$RESULT_DIR/${LABEL}.spec"
        OUT_ERR="$RESULT_DIR/${LABEL}.error"
        OUT_LOG="$RESULT_DIR/${LABEL}.log"
        IO_OUT_ERR="$RESULT_DIR/${LABEL}_iostat.error"
        IO_OUT_LOG="$RESULT_DIR/${LABEL}_iostat.log"
        IOSTAT_LOG="$RESULT_DIR/${LABEL}_iostat"

        echo "=== Setting up FS: $FS (FPW=$FPW) in device($DEVICE) ==="
        restore_filesystem $FS "w$WAREHOUSE" $BACKUP_DIR
        mount_fs $FS $MOUNT_DIR

        REPLACEMENTS=(
          ["VU"]=$VU
          ["WAREHOUSE"]=$WAREHOUSE
          ["ITERATIONS"]=$ITERATION
          ["DURATION"]=$DURATION
          ["RAMPUP"]=$RAMPUP
        )

        IO_REPLACEMENTS=(
          ["VU"]=$VU
          ["WAREHOUSE"]=$WAREHOUSE
          ["ITERATIONS"]=$IO_ITERATION
          ["DURATION"]=$IO_DURATION
          ["RAMPUP"]=$IO_RAMPUP
        )

        case "$MODE" in
          postgres)
            PG_DATA="$MOUNT_DIR/postgres"
            pg_fpw $PG_DATA $FPW
            if [[ "$FPW" == "on" ]]; then
              WALSIZE="16GB"
            fi
            $PG_BIN/pg_ctl -D $PG_DATA start
            pg_wal_max_set $PG_DATA $WALSIZE
            log_pg_specs "$OUT_DBSPEC" "$DBNAME"

            pushd $HAMMERDB

            echo "--> Benchmarking UP $LABEL"
            RUN_TCL="$HAMMERDB/run_${LABEL}.tcl"
            render_tcl_template "$HAMMERDB/run_postgres_template.tcl" $RUN_TCL REPLACEMENTS
            ./hammerdbcli auto $RUN_TCL > "$OUT_LOG" 2> "$OUT_ERR"

            sleep 1

            echo "--> IO Benchmarking $LABEL"
            RUN_TCL="$HAMMERDB/run_${LABEL}.tcl"
            render_tcl_template "$HAMMERDB/run_postgres_template.tcl" $RUN_TCL IO_REPLACEMENTS
            iostat_start $IOSTAT_LOG
            setsid ./hammerdbcli auto "$RUN_TCL" > "$IO_OUT_LOG" 2> "$IO_OUT_ERR" &
            HAMMER_PID=$!
            wait_for_hammerdb_completion "$IO_OUT_LOG" "$VU" "$HAMMER_PID"
            iostat_end
            popd

            $PG_BIN/psql -d postgres -c "CHECKPOINT;"
            $PG_BIN/pg_ctl -D $PG_DATA stop
            umount_fs $MOUNT_DIR
          ;;
          mysql)
            MY_DATA="$MOUNT_DIR/mysql_data"
            MY_SOCK="$MY_DATA/mysql.sock"
            if [[ "$FPW" == "on" ]]; then
              DBW=1
            else
              DBW=0
            fi
            REPLACEMENTS["MYSOCKET"]=$MY_SOCK

            echo "[*] Start mysqld"
            $MYSQL_BIN/mysqld \
                --datadir="$MY_DATA" \
                --socket="$MY_SOCK" \
                --port="$MYSQL_PORT" \
                --pid-file="$MY_DATA/mysqld.pid" \
                --bind-address=127.0.0.1 \
                --skip-networking=0 \
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
  done
done

echo "=== All benchmarks completed ==="
