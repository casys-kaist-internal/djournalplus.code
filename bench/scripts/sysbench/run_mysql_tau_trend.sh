#!/bin/bash
# Scaled-down MySQL/tau trend experiment (2026-08-21).
#
# Answers two open questions from bench/docs/sysbench-workloads-and-db-defaults.md:
#   (4d) xfs-tau wrote 2x more on 2026-04-01 than on 2026-04-15 in the same
#        nominal config. Which number does the current kernel produce?
#   (4.8) how does tau's write volume / throughput move with innodb_buffer_pool_size?
#
# Deliberately NOT a headline run. Everything is scaled so the whole thing
# finishes in ~2h and only trends are claimed:
#   - 8 tables x 5M rows  (~10 GB) instead of 16 x 40M (~127 GB)
#   - mysqld is capped with a cgroup MemoryMax instead of rebooting with mem=
#     (this boot is 187 GB and unrestricted; the original runs used mem=...)
#   - fixed event count per cell so write volume is comparable per event
#   - NO partclone images: XFS speculatively allocates ~90 GB on this 3.0 TB
#     device, so an image does not fit in / (72 GB free). At this DB size a
#     fresh load is only ~3 min, cheaper than a restore, so every cell does
#     mkfs -> load -> measure. Every cell therefore starts from an identical
#     logical state, which is what the image was for.
#
# Controls that the historical runs did NOT have:
#   - innodb_flush_method is set EXPLICITLY (never left to InnoDB's startup probe)
#   - ext4-tau and xfs-tau get the SAME journal cap (1 GB)
#   - the iostat window is bracketed correctly and its length is recorded
#
# Usage:
#   source bench/scripts/env_local.sh
#   TAU_CONFIRM=yes ./bench/scripts/sysbench/run_mysql_tau_trend.sh [load|measure|all]

set -euo pipefail

if [[ -z "${TAUFS_ENV_SOURCED:-}" ]]; then
  echo "Do 'source bench/scripts/env_local.sh' first." >&2; exit 1
fi

PHASE="${1:-all}"

############################ knobs ############################
SB_TABLES=8
SB_ROWS=5000000              # -> 40M rows total, ~10 GB
MEM_CAP=4G                   # mysqld cgroup cap; DB/RAM ~ 2.5
EVENTS=${TAU_EVENTS:-4000000}   # default; per-workload overrides below
events_for() {
  case "$1" in
    oltp_write_only) echo $((EVENTS/4)) ;;   # 4 write statements per transaction
    oltp_read_write) echo $((EVENTS/8)) ;;   # 14 statements per transaction
    oltp_delete)     echo $((EVENTS/4)) ;;   # keep row depletion small
    *)               echo "$EVENTS" ;;
  esac
}
THREADS=32
JOURNAL_GB=1                 # SAME for ext4-tau and xfs-tau
FS_LIST=(xfs-tau ext4-tau)

DBNAME="trend_t${SB_TABLES}"
MOUNT_DIR=/mnt/temp
DEV="$TAU_DEVICE"
MKFS_XFS="${TAUFS_XFSPROGS:-$TAUFS_ROOT/codes/xfsprogs-dev}/mkfs/mkfs.xfs"
MKE2FS="${TAUFS_E2FSPROGS:-$TAUFS_ROOT/codes/e2fsprogs}/misc/mke2fs"
MYSQL_BIN="$TAUFS_BENCH/mysql-server/build/bin"
UNIT=tau-trend-mysqld

DATE=$(date +%Y%m%d_%H%M%S)
RES="$TAUFS_BENCH_WS/results/sysbench/mysql/trend_${DATE}"

# cells: workload | fs | buffer_pool | flush_method | journal_GB | doublewrite | tag
#   doublewrite 1 = fpw=on (safe baseline), 0 = fpw=off (unsafe, or tau)
# Select with TAU_SET=<tag>[,<tag>...]
ALL_CELLS=()
for WLX in oltp_update_non_index oltp_insert; do
  ALL_CELLS+=(
    # --- plain filesystems: the baselines tau is judged against ---------------
    "$WLX|ext4    |128M|O_DIRECT| 0|1|full"   # honest baseline (probe picks O_DIRECT)
    "$WLX|ext4    |128M|O_DIRECT| 0|0|full"   # unsafe upper bound
    "$WLX|ext4    |128M|fsync   | 0|0|full"   # CACHE-MATCHED control: buffered, no journaling
    "$WLX|xfs     |128M|O_DIRECT| 0|1|full"
    "$WLX|xfs     |128M|O_DIRECT| 0|0|full"
    "$WLX|xfs     |128M|fsync   | 0|0|full"   # CACHE-MATCHED control
    # --- tau, journal cap matched between the two --------------------------
    "$WLX|ext4-tau|128M|fsync   |32|0|full"
    "$WLX|xfs-tau |128M|fsync   |32|0|full"
  )
done

# the four workloads not yet covered, same 8 configs, tau at 32 GB
for WLX in oltp_update_index oltp_delete oltp_write_only oltp_read_write; do
  ALL_CELLS+=(
    "$WLX|ext4    |128M|O_DIRECT| 0|1|rest"
    "$WLX|ext4    |128M|O_DIRECT| 0|0|rest"
    "$WLX|ext4    |128M|fsync   | 0|0|rest"
    "$WLX|ext4-tau|128M|fsync   |32|0|rest"
    "$WLX|xfs     |128M|O_DIRECT| 0|1|rest"
    "$WLX|xfs     |128M|O_DIRECT| 0|0|rest"
    "$WLX|xfs     |128M|fsync   | 0|0|rest"
    "$WLX|xfs-tau |128M|fsync   |32|0|rest"
  )
done
ALL_CELLS+=(
  # (4.8) buffer pool sweep under a FIXED memory budget
  "oltp_update_non_index|xfs-tau |512M|fsync   | 1|0|bpsweep"
  "oltp_update_non_index|xfs-tau |1G  |fsync   | 1|0|bpsweep"
  "oltp_update_non_index|xfs-tau |2G  |fsync   | 1|0|bpsweep"
  # (4.6) tau at the intended 32 GB journal cap, both filesystems, both workloads.
  # NOTE: XFS's own default when -l tjmaxsize= is omitted is ~10% of the device
  # (=~320 GB here), so 32G must be passed explicitly to match ext4's mount default.
  "oltp_update_non_index|ext4-tau|128M|fsync   |32|0|j32"
  "oltp_insert          |ext4-tau|128M|fsync   |32|0|j32"
  "oltp_update_non_index|xfs-tau |128M|fsync   |32|0|j32"
  "oltp_insert          |xfs-tau |128M|fsync   |32|0|j32"
  # the 1 GB variants measured on 2026-08-22, kept for the contrast
  "oltp_update_non_index|ext4-tau|128M|fsync   | 1|0|j1"
  "oltp_insert          |ext4-tau|128M|fsync   | 1|0|j1"
  "oltp_update_non_index|xfs-tau |128M|fsync   | 1|0|j1"
  "oltp_insert          |xfs-tau |128M|fsync   | 1|0|j1"
  # flush_method control (confirmed inert on tau, 2026-08-21)
  "oltp_update_non_index|ext4-tau|128M|O_DIRECT| 1|0|flushctl"
)

TAU_SET="${TAU_SET:-full}"
CELLS=()
for c in "${ALL_CELLS[@]}"; do
  tag="${c##*|}"
  case ",$TAU_SET," in *",$tag,"*) CELLS+=("$c") ;; esac
done
if [[ ${#CELLS[@]} -eq 0 ]]; then echo "[ERR] TAU_SET='$TAU_SET' selected no cells" >&2; exit 1; fi
# run only the first N cells (smoke test); empty = all
CELL_LIMIT="${TAU_CELL_LIMIT:-}"
if [[ -n "$CELL_LIMIT" ]]; then CELLS=("${CELLS[@]:0:$CELL_LIMIT}"); fi
###############################################################

banner() { printf '\n=== %s ===\n' "$*"; }

confirm_device() {
  banner "TARGET DEVICE"
  cat <<EOF
  TAU_DEVICE : $DEV        <-- WILL BE DESTROYED (mkfs)
  kernel     : $(uname -r)
  db size    : ${SB_TABLES} tables x ${SB_ROWS} rows (reloaded per cell)
  results    : $RES
EOF
  lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINT "$DEV" 2>/dev/null || true
  if mount | grep -q "^$DEV"; then
    echo "[ERR] $DEV is mounted. Refusing." >&2; exit 1
  fi
  if [[ "${TAU_CONFIRM:-}" != "yes" ]]; then
    echo "[ERR] set TAU_CONFIRM=yes to proceed." >&2; exit 1
  fi
}

do_mkfs_tau() {
  local fs=$1
  case "$fs" in
    xfs-tau)  sudo "$MKFS_XFS" -f -l "tjmaxsize=${JOURNAL_GB}G" "$DEV" >/dev/null ;;
    ext4-tau) sudo "$MKE2FS" -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "$DEV" >/dev/null ;;
    ext4)     sudo mke2fs -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "$DEV" >/dev/null ;;
    xfs)      sudo mkfs.xfs -f "$DEV" >/dev/null ;;
    *) echo "unknown fs $fs" >&2; exit 1 ;;
  esac
}

mount_tau() {
  local fs=$1
  sudo mkdir -p "$MOUNT_DIR"
  case "$fs" in
    xfs-tau)  sudo mount -t xfs  -o tjournal "$DEV" "$MOUNT_DIR" ;;
    ext4-tau) sudo mount -t ext4 -o "tjournal,tjournal_size=${JOURNAL_GB}" "$DEV" "$MOUNT_DIR" ;;
    ext4)     sudo mount -t ext4 "$DEV" "$MOUNT_DIR" ;;
    xfs)      sudo mount -t xfs  "$DEV" "$MOUNT_DIR" ;;
  esac
}

umount_tau() { sudo umount "$MOUNT_DIR" 2>/dev/null || true; }
drop_caches() { sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"; }

load_db() {   # mkfs + fresh sysbench prepare. Leaves the fs mounted.
  local fs=$1
  umount_tau; do_mkfs_tau "$fs"; mount_tau "$fs"
  MY_DATA="$MOUNT_DIR/mysql_data"; MY_SOCK="$MY_DATA/mysql.sock"
  sudo mkdir -p "$MY_DATA"; sudo chown -R "$USER:$USER" "$MY_DATA"
  LD_LIBRARY_PATH="$TAUFS_BENCH/mysql-server/build/lib" \
    "$MYSQL_BIN/mysqld" --initialize-insecure --datadir="$MY_DATA" >/dev/null 2>&1
  # loading only: unsafe-but-fast, no binlog, no memory cap
  LD_LIBRARY_PATH="$TAUFS_BENCH/mysql-server/build/lib" \
    "$MYSQL_BIN/mysqld" --datadir="$MY_DATA" --socket="$MY_SOCK" --port=3306 \
      --pid-file="$MY_DATA/mysqld.pid" --bind-address=127.0.0.1 \
      --log-error="$MY_DATA/mysqld.err" --disable-log-bin \
      --innodb_buffer_pool_size=8G --innodb_doublewrite=0 \
      --innodb_flush_log_at_trx_commit=0 --sync_binlog=0 &
  for _ in $(seq 1 180); do
    if [[ -S "$MY_SOCK" ]]; then break; fi
    sleep 1
  done
  "$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;"
  sysbench --db-driver=mysql --mysql-user=root --mysql-socket="$MY_SOCK" \
    --mysql-db="$DBNAME" oltp_read_write --threads=32 \
    --tables="$SB_TABLES" --table-size="$SB_ROWS" prepare >/dev/null
  "$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -e "SET GLOBAL innodb_fast_shutdown=0;"
  "$MYSQL_BIN/mysqladmin" -uroot --socket="$MY_SOCK" shutdown
  sleep 5
  sync; drop_caches
}

start_mysqld() {  # $1=bufferpool $2=flush_method $3=doublewrite $4=extra
  local bp=$1 fm=$2 dbw=$3; shift 3
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
  sudo systemd-run --unit="$UNIT" --service-type=exec --collect \
    -p "MemoryMax=$MEM_CAP" -p MemorySwapMax=0 -p "User=$USER" \
    -p "Environment=LD_LIBRARY_PATH=$TAUFS_BENCH/mysql-server/build/lib" \
    -- "$MYSQL_BIN/mysqld" \
       --datadir="$MY_DATA" --socket="$MY_SOCK" --port=3306 \
       --pid-file="$MY_DATA/mysqld.pid" --bind-address=127.0.0.1 \
       --log-error="$MY_DATA/mysqld.err" \
       --innodb_buffer_pool_size="$bp" \
       --innodb_flush_method="$fm" \
       --innodb_doublewrite="$dbw" "$@" >/dev/null
  for _ in $(seq 1 120); do
    if [[ -S "$MY_SOCK" ]]; then sleep 2; return 0; fi
    sleep 1
  done
  echo "[ERR] mysqld socket never appeared; tail of error log:" >&2
  sudo tail -20 "$MY_DATA/mysqld.err" >&2 || true
  exit 1
}

stop_mysqld() {
  "$MYSQL_BIN/mysqladmin" -uroot --socket="$MY_SOCK" shutdown 2>/dev/null || true
  for _ in $(seq 1 120); do
    if ! systemctl is-active --quiet "$UNIT"; then break; fi
    sleep 1
  done
  sudo systemctl stop "$UNIT" 2>/dev/null || true
  sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
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
  rm -f "$IOSTAT_RAW"
}


############################ scale phase ############################
# Client-count sweep. One load per CONFIG, then all thread points back to back
# (oltp_write_only keeps the table size constant: delete+insert reuse the same id).
# Time-based, so low thread counts stay tractable.
SCALE_WL="${TAU_SCALE_WL:-oltp_write_only}"
SCALE_THREADS="${TAU_SCALE_THREADS:-1 8 16 32 64}"
SCALE_TIME="${TAU_SCALE_TIME:-120}"
SCALE_WARMUP="${TAU_SCALE_WARMUP:-60}"
# idle gap between points so the page cleaner drains the previous point's dirty
# backlog. Without it the short low-concurrency windows attribute leftover
# checkpoint writes to far fewer events and KB/event blows up (c=1 measured
# 1000 KB/event vs ~198 at c=32 in the fixed-event matrix).
SCALE_SETTLE="${TAU_SCALE_SETTLE:-45}"
SCALE_CONFIGS=(
  "ext4    |128M|O_DIRECT| 0|1"
  "ext4    |128M|O_DIRECT| 0|0"
  "ext4-tau|128M|fsync   |32|0"
  "xfs     |128M|O_DIRECT| 0|1"
  "xfs     |128M|O_DIRECT| 0|0"
  "xfs-tau |128M|fsync   |32|0"
)

phase_scale() {
  mkdir -p "$RES"
  local CSV="$RES/summary_scale.csv"
  echo "workload,fs,fpw,flush,journal_GB,threads,events,run_s,tps,p99_ms,write_GB,iostat_s,cov,KB_per_event" > "$CSV"
  for spec in "${SCALE_CONFIGS[@]}"; do
    IFS='|' read -r FS BP FM JGB DBW <<<"$spec"
    FS=$(echo "$FS"|xargs); BP=$(echo "$BP"|xargs); FM=$(echo "$FM"|xargs)
    JGB=$(echo "$JGB"|xargs); DBW=$(echo "$DBW"|xargs)
    JOURNAL_GB="$JGB"
    if [[ "$DBW" == "1" ]]; then FPW=on; else FPW=off; fi

    banner "SCALE CONFIG $FS fpw=$FPW $FM j=${JGB}G"
    echo "  [load] mkfs $FS + prepare ${SB_TABLES}x${SB_ROWS} ..."
    load_db "$FS"          # leaves the filesystem mounted, MY_DATA/MY_SOCK set
    sudo chown -R "$USER:$USER" "$MY_DATA"
    start_mysqld "$BP" "$FM" "$DBW"

    echo "  [warmup] ${SCALE_WARMUP}s @ c32"
    sysbench "$SCALE_WL" --db-driver=mysql --mysql-user=root --mysql-socket="$MY_SOCK" \
      --mysql-db="$DBNAME" --tables="$SB_TABLES" --table-size="$SB_ROWS" \
      --threads=32 --time="$SCALE_WARMUP" run >/dev/null 2>&1 || true

    for TH in $SCALE_THREADS; do
      LABEL="scale_${SCALE_WL}_${FS}_fpw_${FPW}_${FM}_j${JGB}_c${TH}"
      echo "  --> c=$TH"
      {
        echo "===== $LABEL ====="; date
        echo "kernel_commit: $(cd "$TAUFS_KERNEL" && git rev-parse --short HEAD)"
        echo "mem_cap: $MEM_CAP   host_ram_gb: $(free -g|awk '/^Mem:/{print $2}')"
        echo "journal_cap_gb: $JGB   bp: $BP   flush: $FM   doublewrite: $DBW"
      } > "$RES/$LABEL.spec" 2>&1
      iostat_start "$RES/$LABEL.iostat"
      sysbench "$SCALE_WL" --db-driver=mysql --mysql-user=root --mysql-socket="$MY_SOCK" \
        --mysql-db="$DBNAME" --tables="$SB_TABLES" --table-size="$SB_ROWS" \
        --threads="$TH" --time="$SCALE_TIME" --percentile=99 run > "$RES/$LABEL.log" 2>&1 || true
      iostat_end
      sleep "$SCALE_SETTLE"
      python3 - "$RES/$LABEL" "$CSV" "$SCALE_WL" "$FS" "$FPW" "$FM" "$JGB" "$TH" <<'PY'
import sys,re
base,csvp,wl,fs,fpw,fm,jgb,th = sys.argv[1:9]
sm=[]
for ln in open(base+'.iostat',errors='ignore'):
    f=ln.split()
    if not f or f[0] in ('Device','Linux','#'): continue
    try: v=[float(x) for x in f[1:]]
    except: continue
    if len(v)>=22: sm.append(v)
sm=sm[1:]
w=sum(v[7] for v in sm)/1024; n=len(sm)
t=open(base+'.log',errors='ignore').read()
def g(p,d=''):
    m=re.search(p,t); return m.group(1) if m else d
ev=int(g(r'total number of events:\s+(\d+)','0'))
run=float(g(r'total time:\s+([\d.]+)s','0') or 0)
tps=g(r'transactions:\s+\d+\s+\(([\d.]+) per sec')
p99=g(r'99th percentile:\s+([\d.]+)')
cov=n/run if run else 0
kb=w*1024*1024/ev if ev else 0
open(csvp,'a').write(f"{wl},{fs},{fpw},{fm},{jgb},{th},{ev},{run:.0f},{tps},{p99},{w:.1f},{n},{cov:.2f},{kb:.2f}\n")
print(f"      c={th} tps={tps} p99={p99}ms write={w:.1f}GB cov={cov:.2f} KB/event={kb:.2f}")
PY
    done
    stop_mysqld
    umount_tau
  done
  banner "SCALE SUMMARY"; column -s, -t "$CSV"
}

############################ phases ############################

phase_measure() {
  mkdir -p "$RES"
  echo "cell,workload,fs,fpw,bp,flush,journal_GB,events,run_s,tps,write_GB,read_GB,iostat_s,cov,KB_per_event" > "$RES/summary.csv"
  for spec in "${CELLS[@]}"; do
    IFS='|' read -r WL FS BP FM JGB DBW TAG <<<"$spec"
    WL=$(echo "$WL"|xargs); FS=$(echo "$FS"|xargs); BP=$(echo "$BP"|xargs)
    FM=$(echo "$FM"|xargs); JGB=$(echo "$JGB"|xargs)
    DBW=$(echo "$DBW"|xargs); TAG=$(echo "$TAG"|xargs)
    JOURNAL_GB="$JGB"
    CELL_EVENTS=$(events_for "$WL")
    if [[ "$DBW" == "1" ]]; then FPW=on; else FPW=off; fi
    LABEL="mysql_${WL}_${FS}_fpw_${FPW}_t${SB_TABLES}_c${THREADS}_bp${BP}_${FM}_j${JGB}_${TAG}"
    banner "CELL $LABEL"
    echo "  [load] mkfs $FS + prepare ${SB_TABLES}x${SB_ROWS} ..."
    load_db "$FS"

    start_mysqld "$BP" "$FM" "$DBW"
    {
      echo "===== cell: $LABEL ====="; date
      echo "kernel: $(uname -r)  build: $(uname -v)"
      echo "kernel_commit: $(cd "$TAUFS_KERNEL" && git rev-parse --short HEAD)"
      echo "mem_cap: $MEM_CAP   host_ram_gb: $(free -g|awk '/^Mem:/{print $2}')"
      echo "journal_cap_gb: $JOURNAL_GB   fs: $FS   tables: $SB_TABLES   rows: $SB_ROWS   events: $CELL_EVENTS"
      "$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -e "
        SHOW VARIABLES LIKE 'innodb_buffer_pool_size';
        SHOW VARIABLES LIKE 'innodb_flush_method';
        SHOW VARIABLES LIKE 'innodb_doublewrite';
        SHOW VARIABLES LIKE 'innodb_buffer_pool_instances';
        SHOW VARIABLES LIKE 'innodb_redo_log_capacity';
        SHOW VARIABLES LIKE 'innodb_io_capacity';
        SHOW VARIABLES LIKE 'sync_binlog';
        SHOW VARIABLES LIKE 'log_bin';"
      "$MYSQL_BIN/mysql" -uroot --socket="$MY_SOCK" -NBe "
        SELECT ROUND(SUM(data_length+index_length)/1024/1024/1024,2)
        FROM information_schema.tables WHERE table_schema='$DBNAME';"
    } > "$RES/$LABEL.spec" 2>&1

    iostat_start "$RES/$LABEL.iostat"
    sysbench "$WL" --db-driver=mysql --mysql-user=root --mysql-socket="$MY_SOCK" \
      --mysql-db="$DBNAME" --tables="$SB_TABLES" --table-size="$SB_ROWS" \
      --threads="$THREADS" --time=0 --events="$CELL_EVENTS" run > "$RES/$LABEL.log" 2>&1 || true
    # cgroup memory pressure: distinguishes "page cache squeezed" from
    # "reclaim thrashing" when the bp sweep falls off a cliff (see 4.11)
    {
      echo "----- cgroup memory -----"
      for f in memory.max memory.peak memory.current memory.events memory.stat; do
        cg="/sys/fs/cgroup/system.slice/${UNIT}.service/$f"
        [[ -r "$cg" ]] && { echo "== $f"; head -20 "$cg"; }
      done
    } >> "$RES/$LABEL.spec" 2>&1 || true
    stop_mysqld
    iostat_end
    umount_tau

    python3 - "$RES/$LABEL" "$CELL_EVENTS" "$RES/summary.csv" "$LABEL" "$WL" "$FS" "$FPW" "$BP" "$FM" "$JGB" <<'PY'
import sys,re
base, ev, csvp, label, wl, fs, fpw, bp, fm, jgb = sys.argv[1:11]
ev = int(ev)
samples=[]
for ln in open(base+'.iostat',errors='ignore'):
    f=ln.split()
    if not f or f[0] in ('Device','Linux','#'): continue
    try: v=[float(x) for x in f[1:]]
    except: continue
    if len(v)>=22: samples.append(v)
samples=samples[1:]                    # first iostat report is since-boot
w=sum(v[7] for v in samples); r=sum(v[1] for v in samples); n=len(samples)
t=open(base+'.log',errors='ignore').read()
m=re.search(r'total time:\s+([\d.]+)s',t); run=float(m.group(1)) if m else 0
m=re.search(r'transactions:\s+\d+\s+\(([\d.]+) per sec',t); tps=m.group(1) if m else ''
wgb=w/1024; rgb=r/1024; cov=(n/run) if run else 0
kb=wgb*1024*1024/ev if ev else 0
open(csvp,'a').write(f"{label},{wl},{fs},{fpw},{bp},{fm},{jgb},{ev},{run:.0f},{tps},{wgb:.1f},{rgb:.1f},{n},{cov:.2f},{kb:.2f}\n")
print(f"  -> tps={tps} write={wgb:.1f}GB cov={cov:.2f} KB/event={kb:.2f}")
PY
  done
  banner "SUMMARY"; column -s, -t "$RES/summary.csv"
}

confirm_device
case "$PHASE" in
  scale)       phase_scale ;;
  measure|all) phase_measure ;;
  *) echo "usage: $0 [measure|scale]" >&2; exit 1 ;;
esac
banner "DONE -> $RES"
