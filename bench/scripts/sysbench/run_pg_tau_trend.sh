#!/bin/bash
# PostgreSQL counterpart of run_mysql_tau_trend.sh (2026-08-25).
# Same scaled-down, trend-only design so the two DBs can be read side by side:
#   8 tables x 5M rows (~10 GB), postgres tree capped with a cgroup MemoryMax,
#   fresh mkfs + load per cell, fixed event count, iostat bracketed per cell.
#
# PostgreSQL-specific notes:
#   - PG uses buffered I/O by default (io_direct is off in 17), so there is no
#     O_DIRECT/fsync dimension: 6 configs, not 8.
#   - The tau patch tags only MAIN_FORKNUM with O_TAU_ATOMIC
#     (bench/postgresql src/backend/storage/smgr/md.c:159). WAL/FSM/VM forks are
#     NOT journaled -- same scoping as the InnoDB patch.
#   - RDBMS defaults are left untuned ON PURPOSE (shared_buffers=128MB,
#     wal_level=replica, synchronous_commit=on): the target regime is I/O
#     saturation. See bench/docs/sysbench-workloads-and-db-defaults.md 4.12.
#   - max_wal_size is kept at the DEFAULT 1GB for *both* fpw=on and fpw=off,
#     which differs from run_main.sh (16GB for fpw=on only). At this DB size a
#     16GB cap means no checkpoint fires during a run, so FPIs are emitted once
#     per page and full_page_writes becomes nearly free -- i.e. it would erase
#     the very cost being measured. The `wal` cell set quantifies that.
#
# Usage:
#   source bench/scripts/env_local.sh
#   TAU_CONFIRM=yes ./bench/scripts/sysbench/run_pg_tau_trend.sh measure

set -euo pipefail
if [[ -z "${TAUFS_ENV_SOURCED:-}" ]]; then
  echo "Do 'source bench/scripts/env_local.sh' first." >&2; exit 1
fi
PHASE="${1:-measure}"

############################ knobs ############################
SB_TABLES=${TAU_TABLES:-8}
SB_ROWS=${TAU_ROWS:-5000000}
# empty MEM_CAP = no cgroup memory limit (used to reproduce io_main, which ran
# on the unrestricted host; the original runs never recorded their RAM size)
MEM_CAP=${TAU_MEM_CAP-4G}
EVENTS=${TAU_EVENTS:-4000000}
events_for() {
  case "$1" in
    oltp_write_only) echo $((EVENTS/4)) ;;
    oltp_read_write) echo $((EVENTS/8)) ;;
    oltp_delete)     echo $((EVENTS/4)) ;;
    *)               echo "$EVENTS" ;;
  esac
}
THREADS=32
DBNAME="trend_t${SB_TABLES}"
MOUNT_DIR=/mnt/temp
DEV="$TAU_DEVICE"
MKFS_XFS="${TAUFS_XFSPROGS:-$TAUFS_ROOT/codes/xfsprogs-dev}/mkfs/mkfs.xfs"
MKE2FS="${TAUFS_E2FSPROGS:-$TAUFS_ROOT/codes/e2fsprogs}/misc/mke2fs"
PG_BIN="$TAUFS_BENCH_WS/pg_install/bin"
PG_PORT=5432
UNIT=tau-trend-postgres

DATE=$(date +%Y%m%d_%H%M%S)
RES="$TAUFS_BENCH_WS/results/sysbench/postgres/trend_${DATE}"

# cells: workload | fs | full_page_writes | journal_GB | max_wal_size | tag
ALL_CELLS=()
for WLX in oltp_update_non_index oltp_insert oltp_update_index \
           oltp_delete oltp_write_only oltp_read_write; do
  ALL_CELLS+=(
    "$WLX|ext4    |on | 0|1GB|full"
    "$WLX|ext4    |off| 0|1GB|full"
    "$WLX|ext4-tau|off|32|1GB|full"
    "$WLX|xfs     |on | 0|1GB|full"
    "$WLX|xfs     |off| 0|1GB|full"
    "$WLX|xfs-tau |off|32|1GB|full"
  )
done
ALL_CELLS+=(
  # io_main reproduction: same dataset (t16 x 40M = 152 GB), same WAL scheme
  # (16GB only for fpw=on), same shared_buffers default, current kernel.
  "oltp_update_non_index|ext4    |on | 0|16GB|repro"
  "oltp_update_non_index|ext4    |off| 0|1GB |repro"
  "oltp_update_non_index|ext4-tau|off|32|1GB |repro"
  # baremetal reproduction of the 2026-08-25 corruption: ext4-tau only, in the
  # exact configuration that produced it. The load is what matters -- the
  # original was caught by CREATE INDEX during prepare -- so the run phase is
  # left trivial (TAU_EVENTS=1).
  "oltp_update_non_index|ext4-tau|off|32|1GB |bm"
  # does run_main.sh's 16GB-for-fpw=on scheme change the answer at this scale?
  "oltp_write_only      |ext4|on | 0|16GB|wal"
  "oltp_write_only      |xfs |on | 0|16GB|wal"
  "oltp_update_non_index|ext4|on | 0|16GB|wal"
)

TAU_SET="${TAU_SET:-full}"
CELLS=()
for c in "${ALL_CELLS[@]}"; do
  tag="${c##*|}"
  case ",$TAU_SET," in *",$tag,"*) CELLS+=("$c") ;; esac
done
if [[ -n "${TAU_CELL_LIMIT:-}" ]]; then CELLS=("${CELLS[@]:0:$TAU_CELL_LIMIT}"); fi
if [[ ${#CELLS[@]} -eq 0 ]]; then echo "[ERR] TAU_SET='$TAU_SET' selected no cells" >&2; exit 1; fi
###############################################################

banner() { printf '\n=== %s ===\n' "$*"; }
drop_caches() { sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"; }
umount_tau() { sudo umount "$MOUNT_DIR" 2>/dev/null || true; }

confirm_device() {
  banner "TARGET DEVICE"
  cat <<EOF
  TAU_DEVICE : $DEV        <-- WILL BE DESTROYED (mkfs)
  kernel     : $(uname -r)
  db size    : ${SB_TABLES} tables x ${SB_ROWS} rows (reloaded per cell)
  results    : $RES
  cells      : ${#CELLS[@]}
EOF
  if mount | grep -q "^$DEV"; then echo "[ERR] $DEV is mounted. Refusing." >&2; exit 1; fi
  if [[ "${TAU_CONFIRM:-}" != "yes" ]]; then
    echo "[ERR] set TAU_CONFIRM=yes to proceed." >&2; exit 1
  fi
}

do_mkfs_tau() {
  case "$1" in
    xfs-tau)  sudo "$MKFS_XFS" -f -l "tjmaxsize=${JOURNAL_GB}G" "$DEV" >/dev/null ;;
    ext4-tau) sudo "$MKE2FS" -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "$DEV" >/dev/null ;;
    ext4)     sudo mke2fs -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "$DEV" >/dev/null ;;
    xfs)      sudo mkfs.xfs -f "$DEV" >/dev/null ;;
    *) echo "unknown fs $1" >&2; exit 1 ;;
  esac
}
mount_tau() {
  sudo mkdir -p "$MOUNT_DIR"
  case "$1" in
    xfs-tau)  sudo mount -t xfs  -o tjournal "$DEV" "$MOUNT_DIR" ;;
    ext4-tau) sudo mount -t ext4 -o "tjournal,tjournal_size=${JOURNAL_GB}" "$DEV" "$MOUNT_DIR" ;;
    ext4)     sudo mount -t ext4 "$DEV" "$MOUNT_DIR" ;;
    xfs)      sudo mount -t xfs  "$DEV" "$MOUNT_DIR" ;;
  esac
}

pg_set() {  # key value
  local conf="$PGDATA/postgresql.conf"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*$1[[:space:]]*=" "$conf"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*($1)[[:space:]]*=.*|\1 = $2|g" "$conf"
  else
    printf "\n%s = %s\n" "$1" "$2" >> "$conf"
  fi
}

start_pg() {   # runs the postmaster inside the memory cgroup
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
  local memopt=()
  if [[ -n "$MEM_CAP" ]]; then memopt=(-p "MemoryMax=$MEM_CAP" -p MemorySwapMax=0); fi
  sudo systemd-run --unit="$UNIT" --service-type=exec --collect \
    "${memopt[@]}" -p "User=$USER" \
    -p "Environment=LD_LIBRARY_PATH=$TAUFS_BENCH_WS/pg_install/lib" \
    -- "$PG_BIN/postgres" -D "$PGDATA" -p "$PG_PORT" >/dev/null
  for _ in $(seq 1 180); do
    if "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PG_PORT" >/dev/null 2>&1; then sleep 2; return 0; fi
    sleep 1
  done
  echo "[ERR] postgres never became ready" >&2
  sudo journalctl -u "$UNIT" -n 30 --no-pager >&2 || true
  exit 1
}
stop_pg() {
  "$PG_BIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null 2>&1 || true
  for _ in $(seq 1 180); do
    if ! systemctl is-active --quiet "$UNIT"; then break; fi
    sleep 1
  done
  sudo systemctl stop "$UNIT" 2>/dev/null || true
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
}

load_db() {    # mkfs + initdb + prepare; leaves the fs mounted and PG stopped
  local fs=$1
  umount_tau; do_mkfs_tau "$fs"; mount_tau "$fs"
  PGDATA="$MOUNT_DIR/pgsql_data"
  sudo mkdir -p "$PGDATA"; sudo chown -R "$USER:$USER" "$PGDATA"; chmod 700 "$PGDATA"
  LD_LIBRARY_PATH="$TAUFS_BENCH_WS/pg_install/lib" "$PG_BIN/initdb" -k -D "$PGDATA" >/dev/null 2>&1  # -k: data checksums, so a stale half is caught too
  # loading only: no memory cap, fpw off, big WAL so the load is not checkpoint-bound
  pg_set full_page_writes off
  pg_set max_wal_size 8GB
  LD_LIBRARY_PATH="$TAUFS_BENCH_WS/pg_install/lib" \
    "$PG_BIN/pg_ctl" -D "$PGDATA" -o "-p $PG_PORT" -l "$PGDATA/load.log" -w start >/dev/null
  "$PG_BIN/createdb" -h 127.0.0.1 -p "$PG_PORT" "$DBNAME"
  # NOTE: prepare builds every table's k index, so it reads the whole heap back.
  # That makes it a full read-verification pass -- and on 2026-08-25 it is what
  # first caught the tau corruption ("invalid page in block 748637 ... STATEMENT:
  # CREATE INDEX k_6"). This used to be `>/dev/null` with no status check, so the
  # load completed with 31 indexes instead of 32 and nobody noticed. Never again.
  if ! sysbench --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
       --pgsql-user="$USER" --pgsql-db="$DBNAME" --auto_inc=on --threads=32 \
       oltp_read_write --tables="$SB_TABLES" --table-size="$SB_ROWS" prepare \
       > "$PGDATA/prepare.log" 2>&1; then
    echo "[ERR] sysbench prepare FAILED -- tail of its output:" >&2
    tail -20 "$PGDATA/prepare.log" >&2
    grep -nE "invalid page|ERROR|FATAL" "$PGDATA/load.log" | grep -viE "autovacuum|lock not available" >&2 || true
    exit 1
  fi
  # even on success, the server log can hold a page-validation error
  if grep -qE "invalid page|could not read block" "$PGDATA/load.log" 2>/dev/null; then
    echo "[ERR] PostgreSQL reported page corruption during the load:" >&2
    grep -nE "invalid page|could not read block" "$PGDATA/load.log" >&2
    exit 1
  fi
  local nidx
  nidx=$("$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -AtX -d "$DBNAME" \
         -c "SELECT count(*) FROM pg_indexes WHERE tablename LIKE 'sbtest%';")
  if [[ "$nidx" != "$((SB_TABLES*2))" ]]; then
    echo "[ERR] expected $((SB_TABLES*2)) indexes, found $nidx -- load is incomplete" >&2
    exit 1
  fi
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d "$DBNAME" -c "ANALYZE;" >/dev/null
  "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -c "CHECKPOINT;" >/dev/null
  "$PG_BIN/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null
  sync; drop_caches
}

iostat_start() {
  IOSTAT_RAW="$1.raw"; IOSTAT_OUT="$1"
  iostat -dmx 1 > "$IOSTAT_RAW" & IOSTAT_PID=$!
  IOSTAT_T0=$(date +%s)
}
iostat_end() {
  kill "$IOSTAT_PID" 2>/dev/null || true; wait "$IOSTAT_PID" 2>/dev/null || true
  local pat; pat=$(echo "${DEV##*/}" | sed -E 's/(nvme[0-9]+)(n[0-9]+)/\1(c[0-9]+)?\2/')
  grep -E "Device|$pat" "$IOSTAT_RAW" > "$IOSTAT_OUT" || true
  echo "# iostat_window_seconds=$(( $(date +%s) - IOSTAT_T0 ))" >> "$IOSTAT_OUT"
  rm -f "$IOSTAT_RAW"; IOSTAT_PID=""; IOSTAT_RAW=""
}

TAU_PARAM=/sys/module/tau_journal/parameters
# tau probe counters are global module params, so they must be zeroed per cell.
# The judgment criterion for the corruption-verification round is
# wr_skip_unmapped == 0 over load+run (2026-08-25 corruption fired during load).
tau_probe_reset() {
  [[ -d "$TAU_PARAM" ]] || return 0
  local p
  for p in "$TAU_PARAM"/tau_probe_*; do echo 0 | sudo tee "$p" >/dev/null 2>&1 || true; done
}
tau_probe_dump() {   # $1 = stage label
  [[ -d "$TAU_PARAM" ]] || return 0
  echo "----- tau probes ($1) -----"
  local p
  for p in "$TAU_PARAM"/tau_probe_* "$TAU_PARAM"/tau_strict_cpdrop \
           "$TAU_PARAM"/tau_max_journal_size_gb "$TAU_PARAM"/tau_cp_selftest; do
    printf '%s=%s\n' "${p##*/}" "$(cat "$p" 2>/dev/null)"
  done
}

phase_measure() {
  mkdir -p "$RES"
  echo "cell,workload,fs,fpw,journal_GB,max_wal_size,events,run_s,tps,p99_ms,write_GB,read_GB,iostat_s,cov,KB_per_event" > "$RES/summary.csv"
  for spec in "${CELLS[@]}"; do
    IFS='|' read -r WL FS FPW JGB WALSZ TAG <<<"$spec"
    WL=$(echo "$WL"|xargs); FS=$(echo "$FS"|xargs); FPW=$(echo "$FPW"|xargs)
    JGB=$(echo "$JGB"|xargs); WALSZ=$(echo "$WALSZ"|xargs); TAG=$(echo "$TAG"|xargs)
    JOURNAL_GB="$JGB"
    CELL_EVENTS=$(events_for "$WL")
    LABEL="postgres_${WL}_${FS}_fpw_${FPW}_t${SB_TABLES}_c${THREADS}_j${JGB}_wal${WALSZ}_${TAG}"
    banner "CELL $LABEL"
    echo "  [load] mkfs $FS + prepare ${SB_TABLES}x${SB_ROWS} ..."
    tau_probe_reset
    load_db "$FS"
    pg_set full_page_writes "$FPW"
    pg_set max_wal_size "$WALSZ"
    start_pg
    {
      echo "===== $LABEL ====="; date
      echo "kernel: $(uname -r)   kernel_commit: $(cd "$TAUFS_KERNEL" && git rev-parse --short HEAD)"
      echo "mem_cap: $MEM_CAP   host_ram_gb: $(free -g|awk '/^Mem:/{print $2}')"
      echo "journal_cap_gb: $JGB   fs: $FS   tables: $SB_TABLES   rows: $SB_ROWS   events: $CELL_EVENTS"
      "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -c "
        SELECT name, setting, unit FROM pg_settings WHERE name IN
        ('full_page_writes','max_wal_size','min_wal_size','shared_buffers','wal_buffers',
         'fsync','synchronous_commit','wal_level','checkpoint_timeout',
         'checkpoint_completion_target','wal_compression','io_direct') ORDER BY name;"
      "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -c \
        "SELECT pg_size_pretty(pg_database_size('$DBNAME')) AS db_size;"
      tau_probe_dump "after load"
    } > "$RES/$LABEL.spec" 2>&1
    "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -d postgres -c \
      "SELECT pg_stat_reset_shared('wal');" >/dev/null 2>&1 || true

    iostat_start "$RES/$LABEL.iostat"
    sysbench "$WL" --db-driver=pgsql --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT" \
      --pgsql-user="$USER" --pgsql-db="$DBNAME" --auto_inc=on \
      --tables="$SB_TABLES" --table-size="$SB_ROWS" \
      --threads="$THREADS" --time=0 --events="$CELL_EVENTS" --percentile=99 run \
      > "$RES/$LABEL.log" 2>&1 || true
    # WAL / FPI accounting: this is what makes the FPW cost directly visible
    {
      echo "----- pg_stat_wal -----"
      "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -AtX -d postgres -c "
        SELECT wal_records, wal_fpi, wal_bytes,
               ROUND((wal_fpi*8192.0)/NULLIF(wal_bytes,0)*100,2) AS fpi_pct
        FROM pg_stat_wal;"
      echo "----- checkpoints -----"
      "$PG_BIN/psql" -h 127.0.0.1 -p "$PG_PORT" -AtX -d postgres -c \
        "SELECT num_timed, num_requested, buffers_written FROM pg_stat_checkpointer;"
      tau_probe_dump "after run"
      echo "----- cgroup memory -----"
      for f in memory.max memory.peak memory.current memory.events; do
        cg="/sys/fs/cgroup/system.slice/${UNIT}.service/$f"
        [[ -r "$cg" ]] && { echo "== $f"; head -8 "$cg"; }
      done
    } >> "$RES/$LABEL.spec" 2>&1
    stop_pg
    iostat_end
    umount_tau

    python3 - "$RES/$LABEL" "$CELL_EVENTS" "$RES/summary.csv" "$LABEL" "$WL" "$FS" "$FPW" "$JGB" "$WALSZ" <<'PY'
import sys,re
base, ev, csvp, label, wl, fs, fpw, jgb, walsz = sys.argv[1:10]
ev=int(ev)
sm=[]
for ln in open(base+'.iostat',errors='ignore'):
    f=ln.split()
    if not f or f[0] in ('Device','Linux','#'): continue
    try: v=[float(x) for x in f[1:]]
    except: continue
    if len(v)>=22: sm.append(v)
sm=sm[1:]
w=sum(v[7] for v in sm); r=sum(v[1] for v in sm); n=len(sm)
t=open(base+'.log',errors='ignore').read()
def g(p,d=''):
    m=re.search(p,t); return m.group(1) if m else d
run=float(g(r'total time:\s+([\d.]+)s','0') or 0)
tps=g(r'transactions:\s+\d+\s+\(([\d.]+) per sec')
p99=g(r'99th percentile:\s+([\d.]+)')
wgb=w/1024; rgb=r/1024; cov=(n/run) if run else 0
kb=wgb*1024*1024/ev if ev else 0
open(csvp,'a').write(f"{label},{wl},{fs},{fpw},{jgb},{walsz},{ev},{run:.0f},{tps},{p99},{wgb:.1f},{rgb:.1f},{n},{cov:.2f},{kb:.2f}\n")
print(f"  -> tps={tps} p99={p99}ms write={wgb:.1f}GB cov={cov:.2f} KB/event={kb:.2f}")
PY
  done
  banner "SUMMARY"; column -s, -t "$RES/summary.csv"
}

confirm_device
case "$PHASE" in
  measure|all) phase_measure ;;
  *) echo "usage: $0 [measure]" >&2; exit 1 ;;
esac
banner "DONE -> $RES"
