#!/bin/bash
# Reproduce the 2026-08-25 silent torn write with the workload that actually
# produced it: PostgreSQL under sysbench oltp_update_non_index, on ext4-tau,
# with full_page_writes off so tau alone is responsible for page atomicity.
#
# No crash anywhere in this script.  The cluster is shut down cleanly, the
# filesystem unmounted and remounted, and only then is every page of every
# relation scanned.  A clean unmount flushes everything, so anything pgscan
# finds was lost in steady state.
#
# Scale is chosen by RATIO to the bare-metal failure rather than by absolute
# size, because what mattered there was that the data did not fit in RAM:
#
#             bare metal        default here
#   dataset   152 GB            10 GB
#   RAM       64 GB             8 GB      (2.4x vs 1.25x dataset:RAM)
#   journal   32 GB (21%)       32 GB     (not scaled, see below)
#   tables    16 (~47 relations, matching "running tau: 47")
#
# Relation count is deliberately not scaled: 16 sysbench tables produce ~47
# main-fork relations once their indexes are counted, which is the number of
# concurrent tau transactions the failing run reported.
#
# Nor is the journal: a segment belongs to one file, so what has to match is
# segments per file (256 for ~47), not the data ratio.  A 2 GB journal is 16
# segments for ~48 files, and its run phase crawls -- ~650 TPS, not one revoke
# (taudocs/plan.md §3.8).  32 GB is also what every performance benchmark uses.
# RAM is 8 GB, not the 4 GB the ratio asks for: at 4 GB the run writes half as
# fast, the 120 s checkpoint age holds the journal under half full, and the
# pressure check at the end calls every run INCONCLUSIVE.
#
#   usage: pg-torn.sh [secs] [tables] [rows_per_table]
#
# WARNING: runs mkfs on $TAU_DEV. Destroys it.

cd "$(dirname "$0")" || exit 1
. ./common.sh

SECS=${1:-1800}
# The corrupted page's first block held the extension image, not load-time
# data, so the write that was lost was the load's -- the measurement phase only
# read the damage back.  LOAD_ONLY=1 therefore skips the run entirely and
# scans straight after the load, which is the whole cycle for a fraction of the
# time.  (It also means the run-phase journal size stops mattering.)
LOAD_ONLY=${LOAD_ONLY:-0}
# ext4-tau and xfs-tau reach the journal along different seams -- XFS defers
# unwritten->written to a pass 2 after the commit record (jcommit_publish),
# ext4 has no pass 2 and converts inside pass 1.  Running the same experiment on
# both is what separates "tau core" from "ext4 integration".
FS=${FS:-ext4}
case "$FS" in ext4|xfs) ;; *) die "FS must be ext4 or xfs" ;; esac
TABLES=${2:-16}
ROWS=${3:-2600000}

TAU_JOURNAL_GB=${TAU_JOURNAL_GB:-32}
# The load is a sustained write-once allocating burst -- sysbench's index builds
# in particular -- and that starves on a journal sized for the run phase: real
# PostgreSQL wedges partway through "Creating a secondary index" with the
# journal pinned full and its backends parked in tau_file_transaction_start.
# So load with headroom, then remount at the size the run is supposed to see.
# tjournal_size is a cap on a dynamically grown journal, and a clean unmount
# leaves it empty, so lowering it here costs nothing.
LOAD_JOURNAL_GB=${LOAD_JOURNAL_GB:-32}
THREADS=${THREADS:-32}
PREPARE_THREADS=${PREPARE_THREADS:-8}
SHARED_BUFFERS=${SHARED_BUFFERS:-128MB}
FPW=${FPW:-off}

BENCH=${BENCH:-$TAU_SRCTREE/bench}
PG_BIN=${PG_BIN:-$BENCH/workspace/pg_install/bin}
PGSCAN=${PGSCAN:-$TAU_BIN/pgscan}
DATA=$TAU_MNT/pgsql_data
DB=sbtest
USER_NAME=$(whoami)
PORT=${PGPORT:-5433}
export PGPORT=$PORT
export LD_LIBRARY_PATH="$BENCH/workspace/pg_install/lib:${LD_LIBRARY_PATH:-}"

P=/sys/module/tau_journal/parameters
# DUMP_ALL=1: every probe counter at the end of the load and of the run
dump_all() {
	[ "${DUMP_ALL:-0}" = 1 ] || return 0
	echo "-- all counters, $1 --"
	for c in "$P"/tau_probe_*; do
		printf '  %-28s %s\n' "${c##*/tau_probe_}" "$(cat "$c")"
	done
}

COUNTERS="tau_probe_revoke_taken tau_probe_revoke_anchore \
	  tau_probe_revoke_ckpt tau_probe_revoke_dirty_skip \
	  tau_probe_revoke_notag tau_probe_ckpt_raw_dirty \
	  tau_probe_flush_unmapped tau_probe_flush_notdirty \
	  tau_probe_flush_onwrite tau_probe_flush_onwrite_rev \
	  tau_probe_cpdrop_infer tau_probe_cpdrop_orphan \
	  tau_probe_tx_dropped tau_probe_bulk_short \
	  tau_probe_cpdrop_unwritten tau_probe_anchore_notag"

[ -x "$PG_BIN/initdb" ] || die "no postgres at $PG_BIN"
[ -x "$PGSCAN" ]        || die "missing $PGSCAN (build with tools/tautest/Makefile)"
command -v sysbench >/dev/null || die "sysbench is not installed in this guest"

# Leave nothing holding $TAU_MNT: a round that dies with postgres still running
# makes every later round fail at mke2fs on a busy device, which reads like a
# string of real failures and tests nothing.
cleanup() {
	local rc=$?

	"$PG_BIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true
	sync
	sudo umount "$TAU_MNT" 2>/dev/null || true
	return $rc
}
trap cleanup EXIT

pg_conf() {
	sed -i -E "s|^[[:space:]]*#?[[:space:]]*($1)[[:space:]]*=.*|\1 = $2|" \
		"$DATA/postgresql.conf"
}

echo "== $FS-tau: postgres + sysbench oltp_update_non_index =="
echo "   $TABLES tables x $ROWS rows, $THREADS threads, ${SECS}s,"
echo "   journal ${TAU_JOURNAL_GB}GB (load: ${LOAD_JOURNAL_GB}GB), shared_buffers $SHARED_BUFFERS, full_page_writes $FPW"
free -g | sed -n 2p

if [ "$FS" = xfs ]; then
	# mkfs lays out the segment map (whole 32 GiB map blocks); the cap the
	# kernel enforces is the mount option, as on ext4
	TAU_MKFS_XFS_OPTS="${TAU_MKFS_XFS_OPTS:--l tjmaxsize=${LOAD_JOURNAL_GB}g}"
	export TAU_MKFS_XFS_OPTS
	TAU_MOUNT_OPTS="tjournal,tjournal_size=$LOAD_JOURNAL_GB"
else
	TAU_MOUNT_OPTS="tjournal,tjournal_size=$LOAD_JOURNAL_GB"
fi
export TAU_MOUNT_OPTS
mkfs_mount "$FS"
sudo dmesg -C
for c in $COUNTERS; do
	[ -f "$P/$c" ] && echo 0 | sudo tee "$P/$c" >/dev/null
done

sudo mkdir -p "$DATA"
sudo chown -R "$USER_NAME:$USER_NAME" "$TAU_MNT"
rm -rf "$DATA"; mkdir -p "$DATA"

# -k turns on page checksums.  The bare-metal cluster did not have them, so
# this is a deliberate deviation: without it the only detectable damage is a
# broken page header, and a write lost inside the tuple area passes unnoticed
# by both PostgreSQL and pgscan's zero-half test.
echo "-- initdb (data checksums ${DATA_CHECKSUMS:-on}) --"
initdb_opts=""
[ "${DATA_CHECKSUMS:-on}" = on ] && initdb_opts="-k"
"$PG_BIN/initdb" $initdb_opts -D "$DATA" >/tmp/pg-initdb.log 2>&1 || die "initdb failed"

# Mirror the failing cell's settings (bench/workspace/corruption_evidence/cell.spec).
pg_conf port "$PORT"
pg_conf full_page_writes "$FPW"
pg_conf shared_buffers "'$SHARED_BUFFERS'"
pg_conf max_wal_size "'1GB'"
pg_conf min_wal_size "'80MB'"
pg_conf checkpoint_timeout "'300s'"
pg_conf checkpoint_completion_target 0.9
pg_conf fsync on
pg_conf synchronous_commit on
pg_conf wal_compression off
pg_conf wal_level replica
pg_conf listen_addresses "'localhost'"

"$PG_BIN/pg_ctl" -D "$DATA" -l /tmp/pg-server.log start >/dev/null 2>&1 ||
	die "pg start failed (see /tmp/pg-server.log)"
"$PG_BIN/createdb" -p "$PORT" "$DB" || die "createdb failed"

SB="sysbench /usr/share/sysbench/oltp_update_non_index.lua
	--db-driver=pgsql --pgsql-host=localhost --pgsql-port=$PORT
	--pgsql-user=$USER_NAME --pgsql-db=$DB
	--tables=$TABLES --table-size=$ROWS"

echo "-- loading (this is the write-once phase; it allocates every block) --"
t0=$(date +%s)
$SB --threads=$PREPARE_THREADS prepare >/tmp/sb-prepare.log 2>&1 ||
	{ tail -5 /tmp/sb-prepare.log; die "sysbench prepare failed"; }
echo "   loaded in $(( $(date +%s) - t0 ))s"
"$PG_BIN/psql" -p "$PORT" -d "$DB" -Atc \
	"SELECT 'db_size ' || pg_size_pretty(pg_database_size('$DB'))"

# Take the catalog's own word for what exists, before the filesystem is
# unmounted and again after it comes back.  A run once came back with two of
# sixteen tables missing, and without this there is no telling a table that was
# never created from one the filesystem lost: sysbench only says "relation does
# not exist", and pgscan cannot see it either, because the catalog page that
# would name it lives in a file far below its size floor.
tables_before=$("$PG_BIN/psql" -p "$PORT" -d "$DB" -Atc \
	"SELECT count(*) FROM pg_class WHERE relname LIKE 'sbtest%' AND relkind='r'")
# Indexes too: sysbench builds a PK and a k_ index per table, and a failed
# CREATE INDEX does not stop prepare from reporting success.  The bare-metal
# run that produced the corruption finished with 31 of 32 indexes and nobody
# noticed -- the missing one was the CREATE INDEX that read the torn page.
idx_before=$("$PG_BIN/psql" -p "$PORT" -d "$DB" -Atc \
	"SELECT count(*) FROM pg_class WHERE relname ~ '^(sbtest|k_)' AND relkind='i'")
echo "   catalog after load: $tables_before tables, $idx_before indexes"
if [ "$idx_before" != "$((TABLES * 2))" ]; then
	echo "   expected $((TABLES * 2)) indexes -- one failed to build"
	grep -aiE "error|fatal|invalid page" /tmp/pg-server.log | tail -10
fi
# CREATE INDEX scans every heap page, so the load is already a full read-back
# check: PostgreSQL reports a torn page here, long before the offline scan.
if grep -qa "invalid page" /tmp/pg-server.log 2>/dev/null; then
	echo "RESULT: FAIL -- PostgreSQL rejected a page DURING THE LOAD"
	grep -a "invalid page" /tmp/pg-server.log | head -5
	grep -a -A1 "invalid page" /tmp/pg-server.log | grep -a STATEMENT | head -3
	sudo dmesg | grep -aiE "TAU:|tau_" | tail -30
	exit 1
fi
if [ "$tables_before" != "$TABLES" ]; then
	echo "   sysbench prepare claimed success but the catalog has $tables_before of $TABLES"
	# Capture here, not later: the next round's mkfs clears the ring buffer,
	# and the kernel side of this is only visible in it.
	echo "   --- sysbench prepare (tail) ---"; tail -6 /tmp/sb-prepare.log
	echo "   --- postgres errors ---"
	grep -aiE "error|fatal|could not" /tmp/pg-server.log | tail -8
	echo "   --- kernel (tau/ext4) ---"
	sudo dmesg | grep -aiE "tau|ext4|alloc" | tail -20
	echo "   --- memory ---"; free -m | sed -n 2p
	echo "   --- which sbtest tables the catalog has ---"
	"$PG_BIN/psql" -p "$PORT" -d "$DB" -Atc \
		"SELECT string_agg(relname, ' ' ORDER BY relname) FROM pg_class
		 WHERE relname ~ '^sbtest[0-9]+$' AND relkind='r'"
	die "load is not what it claimed to be"
fi

# The load is the only phase with commit-time allocation in it: during the run
# every write lands on an already-written extent.  The reported corruption --
# a written extent over a zeroed block -- is allocation-shaped, so the load's
# numbers are reported separately rather than being zeroed away unseen.
echo "-- load-phase counters --"
for c in $COUNTERS; do
	printf '  %-28s %s\n' "$c" "$(cat "$P/$c" 2>/dev/null || echo -)"
done
dump_all load
loadpeak=$(sudo dmesg | grep -a 'Used journal' |
	   sed -n 's/.*Used journal \([0-9]*\)MB.*/\1/p' | sort -n | tail -1)
echo "  journal peak during load: ${loadpeak:-0}MB of $((LOAD_JOURNAL_GB * 1024))MB"

if [ "$LOAD_ONLY" = 1 ]; then
	echo "-- LOAD_ONLY: skipping the run phase --"
	"$PG_BIN/pg_ctl" -D "$DATA" -m fast stop >/dev/null 2>&1 || echo "  (pg_ctl stop reported an error)"
	sync
	sudo umount "$TAU_MNT" || die "umount failed"
	mount_tau "$FS"
	echo "-- scanning every relation page --"
	"$PGSCAN" -m 1 "$DATA/base"
	scanrc=$?
	echo
	echo "-- load-phase probe counters --"
	for c in $COUNTERS; do
		printf '  %-28s %s\n' "$c" "$(cat "$P/$c" 2>/dev/null || echo -)"
	done
	sudo umount "$TAU_MNT" 2>/dev/null
	if [ "$scanrc" != 0 ]; then
		echo "RESULT: FAIL -- damage on disk after a load and a clean unmount"
		exit 1
	fi
	lp=$((${loadpeak:-0} * 100 / (LOAD_JOURNAL_GB * 1024)))
	if [ "$lp" -lt 50 ]; then
		echo "RESULT: INCONCLUSIVE -- journal peaked at ${lp}% during the load"
		exit 2
	fi
	echo "RESULT: PASS (load journal peaked ${lp}%, nothing lost)"
	exit 0
fi

echo "-- remounting with the run-phase journal (${TAU_JOURNAL_GB}GB) --"
"$PG_BIN/pg_ctl" -D "$DATA" -m fast stop >/dev/null 2>&1 || die "pg stop failed"
sync
sudo umount "$TAU_MNT" || die "umount between phases failed"
TAU_MOUNT_OPTS="tjournal,tjournal_size=$TAU_JOURNAL_GB"
export TAU_MOUNT_OPTS
mount_tau "$FS"
"$PG_BIN/pg_ctl" -D "$DATA" -l /tmp/pg-server.log start >/dev/null 2>&1 ||
	die "pg restart failed (see /tmp/pg-server.log)"
tables_after=$("$PG_BIN/psql" -p "$PORT" -d "$DB" -Atc \
	"SELECT count(*) FROM pg_class WHERE relname LIKE 'sbtest%' AND relkind='r'" 2>/dev/null)
echo "   catalog after remount: ${tables_after:-?} tables (was $tables_before)"
if [ "${tables_after:-x}" != "$tables_before" ]; then
	echo "RESULT: FAIL -- the catalog lost relations across a clean unmount"
	"$PG_BIN/psql" -p "$PORT" -d "$DB" -Atc \
		"SELECT relname FROM pg_class WHERE relname LIKE 'sbtest%' AND relkind='r' ORDER BY 1" 2>&1 |
		tr '\n' ' '
	echo
	sudo dmesg | tail -20
	exit 1
fi

# Counters are zeroed here, not at mkfs: the load is not what is under test and
# its traffic would swamp the run-phase numbers.  All of them, not only the
# ones reported below.
for c in "$P"/tau_probe_*; do
	echo 0 | sudo tee "$c" >/dev/null
done
sudo dmesg -C

echo "-- running ${SECS}s, $THREADS threads --"
peak=0
$SB --threads=$THREADS --time=$SECS --report-interval=60 run \
	>/tmp/sb-run.log 2>&1 &
sbpid=$!
# Poll rather than wait(1): a wedged guest ignores SIGKILL, so nothing here may
# block on the workload without a deadline of its own.
while kill -0 $sbpid 2>/dev/null; do
	used=$(sudo dmesg | grep -a 'Used journal' | tail -1 |
	       sed -n 's/.*Used journal \([0-9]*\)MB.*/\1/p')
	[ -n "$used" ] && [ "$used" -gt "$peak" ] && peak=$used
	sleep 10
done
wait $sbpid; sbrc=$?
grep -E "transactions:|queries:|FATAL|invalid page" /tmp/sb-run.log | head -5
if grep -q "does not exist" /tmp/sb-run.log 2>/dev/null; then
	echo "RESULT: FAIL -- a relation vanished mid-run"
	grep -m3 "does not exist" /tmp/sb-run.log
	sudo dmesg | tail -20
	exit 1
fi

echo "-- clean shutdown, unmount, remount --"
"$PG_BIN/pg_ctl" -D "$DATA" -m fast stop >/dev/null 2>&1 || echo "  (pg_ctl stop reported an error)"
sync
sudo umount "$TAU_MNT" || die "umount failed"
mount_tau "$FS"

echo "-- scanning every relation page --"
# -m 1: include the indexes, not just the heaps.  The original scan that found
# the corruption looked at the 16 table files only; an index page lost the same
# way would have gone unnoticed.
"$PGSCAN" -m 1 "$DATA/base"
scanrc=$?

echo
echo "-- probe counters --"
for c in $COUNTERS; do
	printf '  %-28s %s\n' "$c" "$(cat "$P/$c" 2>/dev/null || echo -)"
done
dump_all run

cap=$((TAU_JOURNAL_GB * 1024))
pct=$((peak * 100 / cap))
echo
echo "-- journal peak ${peak}MB of ${cap}MB (${pct}%) --"
stalls=$(sudo dmesg | grep -ac 'blocked for more than' || true)
[ "$stalls" != 0 ] && echo "-- $stalls writer stall warning(s) --"
faults=$(sudo dmesg | grep -icE 'kernel BUG|invalid opcode|soft lockup' || true)
[ "$faults" != 0 ] && { echo "kernel faulted $faults time(s):"; show_kernel_faults; }

sudo umount "$TAU_MNT" 2>/dev/null

if [ "$scanrc" != 0 ]; then
	echo "RESULT: FAIL -- torn pages on disk with no crash involved"
	exit 1
fi
if grep -q "invalid page" /tmp/sb-run.log 2>/dev/null; then
	echo "RESULT: FAIL -- postgres rejected a page during the run"
	exit 1
fi
[ "$sbrc" = 0 ] || { echo "RESULT: FAIL -- sysbench exited $sbrc"; tail -5 /tmp/sb-run.log; exit 1; }
# 40, not 50: with the shrinker (taudocs/plan.md §8) memory pressure checkpoints
# first, and in the 8 GB guest the ext4 journal tops out near half
if [ "$pct" -lt 40 ]; then
	echo "RESULT: INCONCLUSIVE -- journal peaked at ${pct}%; the failing run sat"
	echo "        at 80% for twenty minutes. Raise rows or secs (a smaller journal"
	echo "        is a different regime, see the header)."
	exit 2
fi
echo "RESULT: PASS (journal peaked ${pct}%, no torn page)"
exit 0
