#!/bin/bash
# pgvector insert cost with full_page_writes on (App) and off (Raw).
#
# VectorDBBench loads a dataset into a table that already has its HNSW index
# (create_index_before_load, see vdbbench.py), so every row is an index insert
# that also rewrites the neighbor lists on older index pages: the case where
# FPW logs full-page images. Search is skipped; only the load is measured.
# Each block starts from a fresh file system and initdb, with the fixed server
# settings of the sysbench runs (postgres/api.sh).
#
#   source set_env.sh   # from the repository root
#   bench/scripts/vectordb/run_pgvector.sh
#   FS_LIST=xfs FPW_LIST=on REPEATS=2 bench/scripts/vectordb/run_pgvector.sh
#   LOAD_CONN=16 bench/scripts/vectordb/run_pgvector.sh   # 16 loading connections
#   CASE=Performance768D10M LOAD_CONN=16 bench/scripts/vectordb/run_pgvector.sh
#   REPEATS=2 RUN_START=2 ALTERNATE=1 ...     # runs 2 and 3: off on, then on off
#   CASE=StreamingPerformanceCase STREAM_RATE=1500 ...   # search while inserting
#
# Needs pgvector and the VectorDBBench venv (install.sh) and the dataset in
# DATASET_LOCAL_DIR (fetch_dataset.sh cohere_medium_1m | cohere_large_10m).
# Summarize with parse_pgvector.py <result dir>.
set -e

if [ -z "$TAUFS_ENV_SOURCED" ]; then
  echo "Do source set_env.sh first."
  exit 1
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/postgres/api.sh"

FS_LIST="${FS_LIST-ext4}"
FPW_LIST="${FPW_LIST-on off}"
REPEATS="${REPEATS-1}"
RUN_START="${RUN_START-1}"         # first run number (the labels' _r<N>)
ALTERNATE="${ALTERNATE-0}"         # 1: even runs take FPW_LIST backwards (on off, off on, ...)
CASE="${CASE-Performance768D1M}"   # Cohere 1M, 768 dimensions, cosine
HNSW_M="${HNSW_M-16}"              # pgvector's defaults
HNSW_EFC="${HNSW_EFC-64}"
BATCH="${BATCH-100}"               # rows per COPY + commit, VectorDBBench's default
LOAD_CONN="${LOAD_CONN-1}"         # loading connections; VectorDBBench uses 1 for pgvector
SAMPLE_SEC="${SAMPLE_SEC-10}"
# CASE=StreamingPerformanceCase: insert at STREAM_RATE rows/s and search at the
# STREAM_STAGES fractions of the dataset, with one client (all test queries,
# latency percentiles, recall) and then STREAM_CONC clients (QPS, latency) until
# the next stage (vdbbench.py sets dataset, stages and clients)
STREAM_RATE="${STREAM_RATE-1500}"
STREAM_DATASET="${STREAM_DATASET-Large Cohere (768dim, 10M)}"
STREAM_STAGES="${STREAM_STAGES-[0.1, 0.3, 0.5, 0.7, 0.9]}"
STREAM_CONC="${STREAM_CONC-[5]}"
K="${K-100}"                       # VectorDBBench's default
EF_SEARCH="${EF_SEARCH-128}"       # >= K; pgvector's default 40 would return fewer rows
VDB_VENV="${VDB_VENV-$TAUFS_BENCH_WS/vdb-venv}"
export DATASET_LOCAL_DIR="${DATASET_LOCAL_DIR-/mnt/tau_backup/vectordb/dataset}"
VDB_DBNAME=vectordb

[ -f "$TAUFS_BENCH_WS/pg_install/lib/postgresql/vector.so" ] || { echo "❌ pgvector is not installed in pg_install"; exit 1; }
[ -x "$VDB_VENV/bin/python" ] || { echo "❌ no VectorDBBench venv at $VDB_VENV"; exit 1; }

# Same host checks as sysbench/run_main.sh
[[ "$(uname -r)" == *"6.8.0"* ]] || { echo "❌ kernel $(uname -r), expected 6.8.0*"; exit 1; }
MEM_TOTAL_GB=$(( $(awk '/^MemTotal/{t=$2} /^Hugetlb/{h=$2} END{print t-h}' /proc/meminfo) / 1024 / 1024 ))
[ "$MEM_TOTAL_GB" -le "$TAU_MEM_GB" ] || { echo "❌ usable memory ~${MEM_TOTAL_GB}GB > ${TAU_MEM_GB}GB"; exit 1; }
if [[ "${HOST_CHECK:-1}" != 0 ]]; then
  bash "$TAUFS_BENCH/scripts/host_setup.sh" check || { echo "❌ run bench/scripts/host_setup.sh apply"; exit 1; }
fi

DATE=$(date +%Y%m%d_%H%M%S)
RESULT_DIR="$TAU_RESULTS/vectordb/pgvector/$DATE${VARIANT:+_$VARIANT}"
mkdir -p "$RESULT_DIR"
log_env "$RESULT_DIR/env.txt"
cp "$0" "$HERE/vdbbench.py" "$RESULT_DIR/"
echo "=== results: $RESULT_DIR ==="

# Every SAMPLE_SEC: rows inserted so far, WAL bytes, full-page images and
# checkpoints -- the time series behind the .io totals -- plus the CPU ticks
# of the VectorDBBench processes (the CLI and the loaders it spawns: is the
# client the limit?) and of the machine.
sampler_start() {
  local out="$1"
  echo "time rows wal_bytes wal_fpi ckpt_timed ckpt_requested client_ticks busy_ticks" > "$out"
  ( while sleep "$SAMPLE_SEC"; do
      # (subshell: these do not leak)
      db=$(sudo -u "$PGUSER" "$PG_BIN/psql" -AtX -F' ' -p "$PG_PORT" -d "$VDB_DBNAME" -c "
        SELECT to_char(now(), 'HH24:MI:SS'),
               coalesce((SELECT sum(n_tup_ins) FROM pg_stat_user_tables), 0),
               w.wal_bytes, w.wal_fpi, c.num_timed, c.num_requested
        FROM pg_stat_wal w, pg_stat_checkpointer c;" 2>/dev/null) || continue
      client=$(for p in $(pgrep -f "$VDB_VENV/bin/python"); do cat /proc/$p/stat 2>/dev/null; done \
               | awk '{ s += $14 + $15 } END { print s + 0 }')
      busy=$(awk '/^cpu / { print $2 + $3 + $4 + $7 + $8 }' /proc/stat)
      echo "$db $client $busy" >> "$out"
    done ) &
  SAMPLER_PID=$!
}

sampler_stop() {
  [[ -n "$SAMPLER_PID" ]] || return 0
  kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=
}

# Every second: what the client backends wait on, as
# "<role>/<type>:<event>=<count>" with role ins (COPY), srch (SELECT) or other
# (CPU:running = no wait event: on CPU, or in a spot PostgreSQL does not
# instrument; Client:ClientRead = waiting for VectorDBBench).
waits_start() {
  local out="$1"
  ( while sleep 1; do
      sudo -u "$PGUSER" "$PG_BIN/psql" -AtX -p "$PG_PORT" -d "$VDB_DBNAME" -c "
        SELECT to_char(now(), 'HH24:MI:SS') || ' ' || coalesce(string_agg(w || '=' || n, ' ' ORDER BY w), '')
        FROM (SELECT CASE WHEN query ILIKE 'copy%' THEN 'ins' WHEN query ILIKE 'select%' THEN 'srch'
                          ELSE 'other' END || '/'
                     || coalesce(wait_event_type, 'CPU') || ':' || coalesce(wait_event, 'running') AS w,
                     count(*) AS n
              FROM pg_stat_activity
              WHERE backend_type = 'client backend' AND datname = '$VDB_DBNAME'
                AND pid <> pg_backend_pid()
              GROUP BY 1) s;" >> "$out" 2>/dev/null || true
    done ) &
  WAITS_PID=$!
}

waits_stop() {
  [[ -n "$WAITS_PID" ]] || return 0
  kill "$WAITS_PID" 2>/dev/null || true
  wait "$WAITS_PID" 2>/dev/null || true
  WAITS_PID=
}

# The table, its indexes and its TOAST table after the load
log_sizes() {
  sudo -u "$PGUSER" "$PG_BIN/psql" -X -p "$PG_PORT" -d "$VDB_DBNAME" -c "
    SELECT r.relname, r.relkind, pg_relation_size(r.oid) AS bytes,
           pg_size_pretty(pg_relation_size(r.oid)) AS size
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         JOIN pg_class r ON r.oid IN (c.oid, c.reltoastrelid)
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'i')
    ORDER BY 3 DESC;" >> "$1" 2>&1
}

if [[ "$CASE" == StreamingPerformanceCase ]]; then
  CASE_TAG="Stream${STREAM_RATE}"
  CASE_ARGS=(--case-type "$CASE" --streaming-insert-rate "$STREAM_RATE" --k "$K" --ef-search "$EF_SEARCH")
  export VDB_STREAM_DATASET="$STREAM_DATASET" VDB_STREAM_STAGES="$STREAM_STAGES" VDB_STREAM_CONC="$STREAM_CONC"
else
  CASE_TAG="$CASE"
  CASE_ARGS=(--case-type "$CASE" --skip-search-serial --skip-search-concurrent)
fi

run_block() {
  local LABEL="pgvector_${CASE_TAG}_${FS}${VARIANT:+-$VARIANT}_fpw_${FPW}_c${LOAD_CONN}_r${R}"
  local PG_DATA="$MOUNT_DIR/pgsql_data" LOG_DIR
  echo "=== $LABEL ($(date +%H:%M:%S)) ==="

  do_mkfs "$FS" "$TAU_DEVICE"
  mount_fs "$FS" "$MOUNT_DIR"
  sudo mkdir -p "$PG_DATA"
  sudo chown -R "$PGUSER:$PGUSER" "$MOUNT_DIR"
  LOG_DIR=$(db_log_dir "$FS")
  if [[ -n "$LOG_DIR" ]]; then
    sudo chown "$PGUSER:$PGUSER" "$LOG_DIR"
    "$PG_BIN/initdb" -D "$PG_DATA" --waldir="$LOG_DIR/pg_wal" > "$RESULT_DIR/${LABEL}_initdb.log"
  else
    "$PG_BIN/initdb" -D "$PG_DATA" > "$RESULT_DIR/${LABEL}_initdb.log"
  fi
  pg_fpw "$PG_DATA" "$FPW"
  pg_fixed_settings "$PG_DATA"
  # Memory held back with hold_memory.sh is a 2 MiB huge page pool, which
  # huge_pages=try would take for shared_buffers. With no pool (the sysbench
  # runs) try already meant regular pages, so off changes nothing there.
  pg_conf_set "$PG_DATA" huge_pages off
  case $FS in btrfs|zfs*) pg_cow_settings "$PG_DATA" ;; esac

  "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$RESULT_DIR/${LABEL}_server.log" start
  "$PG_BIN/createdb" -p "$PG_PORT" "$VDB_DBNAME"
  sudo -u "$PGUSER" "$PG_BIN/psql" -qX -p "$PG_PORT" -d "$VDB_DBNAME" -c "CREATE EXTENSION vector;"
  log_pg_specs "$RESULT_DIR/${LABEL}.spec" "$VDB_DBNAME" "$LABEL"
  sudo -u "$PGUSER" "$PG_BIN/psql" -AtX -p "$PG_PORT" -d "$VDB_DBNAME" \
    -c "SELECT 'pgvector ' || extversion FROM pg_extension WHERE extname = 'vector';
        SELECT 'huge_pages ' || current_setting('huge_pages');" >> "$RESULT_DIR/${LABEL}.spec"
  bash "$TAUFS_BENCH/scripts/hold_memory.sh" >> "$RESULT_DIR/${LABEL}.spec"
  # Both configurations start the load at the same checkpoint phase
  sudo -u "$PGUSER" "$PG_BIN/psql" -qX -p "$PG_PORT" -d postgres -c "CHECKPOINT;"

  log_dev_stat begin "$RESULT_DIR/${LABEL}.io" || true
  log_pg_io_counters begin "$RESULT_DIR/${LABEL}.io" || true
  iostat_start "$RESULT_DIR/${LABEL}.iostat" 86400
  sampler_start "$RESULT_DIR/${LABEL}.progress"
  waits_start "$RESULT_DIR/${LABEL}.waits"
  local t0=$(date +%s.%N) rc=0
  local conn_args=()
  if (( LOAD_CONN > 1 )); then
    conn_args=(--load-concurrency "$LOAD_CONN")
  fi
  ( cd "$RESULT_DIR" && env VDB_INDEX_BEFORE_LOAD=1 VDB_CONN_PER_THREAD=$(( LOAD_CONN > 1 )) \
      LOG_FILE="$RESULT_DIR/${LABEL}.vdb.log" RESULTS_LOCAL_DIR="$RESULT_DIR/vdb_results" \
      "$VDB_VENV/bin/python" "$HERE/vdbbench.py" pgvectorhnsw \
        --user-name "$PGUSER" --password "" --host 127.0.0.1 --port "$PG_PORT" --db-name "$VDB_DBNAME" \
        "${CASE_ARGS[@]}" --m "$HNSW_M" --ef-construction "$HNSW_EFC" \
        --insert-batch-size "$BATCH" "${conn_args[@]}" --drop-old --load \
        --db-label "$LABEL" --task-label "$LABEL" ) > "$RESULT_DIR/${LABEL}.out" 2>&1 || rc=$?
  local t1=$(date +%s.%N)
  waits_stop
  sampler_stop
  iostat_stop
  log_dev_stat end "$RESULT_DIR/${LABEL}.io" || true
  log_pg_io_counters end "$RESULT_DIR/${LABEL}.io" || true
  echo "elapsed_s=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') rc=$rc" >> "$RESULT_DIR/${LABEL}.io"
  echo "rows=$(sudo -u "$PGUSER" "$PG_BIN/psql" -AtX -p "$PG_PORT" -d "$VDB_DBNAME" \
    -c "SELECT count(*) FROM vdbbench_table_test;" 2>/dev/null)" >> "$RESULT_DIR/${LABEL}.io"
  log_sizes "$RESULT_DIR/${LABEL}.sizes" || true

  "$PG_BIN/pg_ctl" -D "$PG_DATA" -t 600 stop
  umount_fs "$MOUNT_DIR"
  [[ "$rc" == 0 ]] || { echo "❌ $LABEL: VectorDBBench exited with $rc (see ${LABEL}.out)"; exit 1; }
}

for (( R=RUN_START; R<RUN_START+REPEATS; R++ )); do
  order=$FPW_LIST
  if [[ "$ALTERNATE" == 1 ]] && (( R % 2 == 0 )); then
    order=$(echo $FPW_LIST | tr ' ' '\n' | tac | xargs)
  fi
  for FS in $FS_LIST; do
    for FPW in $order; do
      run_block
    done
  done
done
echo "=== done: $RESULT_DIR ==="
