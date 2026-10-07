#!/bin/bash
# Run a spread of database workload shapes on one tau filesystem.
#
#   usage: db-workloads.sh <ext4-tau|xfs-tau> [scale] [seconds-per-pattern]
#
# The point is coverage of I/O shapes, not throughput numbers: bulk sequential
# writes, small random updates, append-only, huge rows (TOAST), high fan-out
# concurrency, fsync-per-commit, and checkpoint pressure all hit the journal
# differently. Each pattern is checked for server and kernel errors; the TPS is
# printed only so a pathological collapse is visible.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
SCALE=${2:-30}
SECS=${3:-20}
[ -n "$FS" ] || die "usage: $0 <ext4-tau|xfs-tau> [scale] [seconds]"

BENCH=${BENCH:-$TAU_SRCTREE/bench}
PG_BIN=${PG_BIN:-$BENCH/workspace/pg_install/bin}
MYSQL_BUILD=${MYSQL_BUILD:-$BENCH/mysql-server/build}
MNT=$TAU_MNT
SOCK=/tmp/tau-mysql.sock
USER_NAME=$(whoami)
DATA="$MNT/postgre"
DB="pgbench_s$SCALE"
rc=0

export LD_LIBRARY_PATH="$BENCH/workspace/pg_install/lib:$MYSQL_BUILD/lib:${LD_LIBRARY_PATH:-}"
. ./db-common.sh

pg_conf() {
	sed -i -E "s|^[[:space:]]*#?[[:space:]]*($1)[[:space:]]*=.*|\1 = $2|" "$DATA/postgresql.conf"
}

pg_restart() {
	"$PG_BIN/pg_ctl" -D "$DATA" -l /tmp/pg-server.log restart >/dev/null 2>&1 ||
		{ echo "    FAIL: restart"; return 1; }
	sleep 1
}

# report <name> <logfile> [extra-metric-line]
report() {
	local name=$1 log=$2 bad=0
	local tps
	tps=$(grep -E '^tps' "$log" 2>/dev/null | head -1 | awk '{print $3}')
	if grep -qE 'PANIC|FATAL|could not|corrupt|invalid page' /tmp/pg-server.log 2>/dev/null; then
		echo "    server errors:"; grep -E 'PANIC|FATAL|could not|corrupt|invalid page' /tmp/pg-server.log | head -3
		: > /tmp/pg-server.log
		bad=1
	fi
	if [ "$(kernel_faults)" != "0" ]; then
		echo "    kernel faults:"; show_kernel_faults | head -5
		bad=1
	fi
	if [ $bad -eq 0 ]; then
		printf '    %-28s ok   %s\n' "$name" "${tps:+tps=$tps}"
	else
		printf '    %-28s FAIL\n' "$name"
		rc=1
	fi
}

echo "== $FS : postgres workload patterns (scale $SCALE, ${SECS}s each) =="
tau_mkfs_mount
sudo dmesg -C

sudo mkdir -p "$DATA"; sudo chown -R "$USER_NAME:$USER_NAME" "$DATA"
"$PG_BIN/initdb" -D "$DATA" >/tmp/pg-initdb.log 2>&1 || die "initdb failed"
pg_conf full_page_writes off
"$PG_BIN/pg_ctl" -D "$DATA" -l /tmp/pg-server.log start >/dev/null 2>&1 || die "pg start failed"
"$PG_BIN/createdb" "$DB" || die "createdb failed"

# 1. bulk load: COPY, big sequential writes plus index builds
echo "[1] bulk load (COPY)"
t0=$(date +%s)
"$PG_BIN/pgbench" -i -s "$SCALE" "$DB" >/tmp/w-load.log 2>&1 || { echo "    FAIL: load"; rc=1; }
echo "    took $(( $(date +%s) - t0 ))s for $((SCALE * 100000)) rows"
report "bulk-load" /tmp/w-load.log

# 2. TPC-B like: small random updates + append to history, the default shape
echo "[2] tpcb-like, 16 clients"
"$PG_BIN/pgbench" -b tpcb-like --no-vacuum -c 16 -j 8 -T "$SECS" "$DB" >/tmp/w-tpcb.log 2>&1
report "tpcb-like c16" /tmp/w-tpcb.log

# 3. simple-update: same writes without the SELECT, more write-dense
echo "[3] simple-update, 16 clients"
"$PG_BIN/pgbench" -b simple-update --no-vacuum -c 16 -j 8 -T "$SECS" "$DB" >/tmp/w-simple.log 2>&1
report "simple-update c16" /tmp/w-simple.log

# 4. read-only: no journal traffic at all, should not regress
echo "[4] select-only, 32 clients"
"$PG_BIN/pgbench" -b select-only --no-vacuum -c 32 -j 8 -T "$SECS" "$DB" >/tmp/w-ro.log 2>&1
report "select-only c32" /tmp/w-ro.log

# 5. high concurrency: many files fsyncing at once, per-inode journals in parallel
echo "[5] tpcb-like, 64 clients"
"$PG_BIN/pgbench" -b tpcb-like --no-vacuum -c 64 -j 16 -T "$SECS" "$DB" >/tmp/w-c64.log 2>&1
report "tpcb-like c64" /tmp/w-c64.log

# 6. fsync per commit with tiny transactions: worst case for commit overhead
echo "[6] single client, synchronous commits"
"$PG_BIN/pgbench" -b simple-update --no-vacuum -c 1 -j 1 -T "$SECS" "$DB" >/tmp/w-c1.log 2>&1
report "simple-update c1" /tmp/w-c1.log

# 7. full_page_writes ON: postgres writes whole pages into WAL, much larger
#    sequential WAL traffic than the off case tau targets
echo "[7] tpcb-like with full_page_writes=on"
pg_conf full_page_writes on
pg_restart && "$PG_BIN/pgbench" -b tpcb-like --no-vacuum -c 16 -j 8 -T "$SECS" "$DB" >/tmp/w-fpw.log 2>&1
report "tpcb-like fpw=on" /tmp/w-fpw.log
pg_conf full_page_writes off

# 8. checkpoint pressure: force frequent checkpoints so in-place writeback and
#    journal recycling run constantly underneath the workload
echo "[8] tpcb-like under checkpoint pressure"
pg_conf max_wal_size "'256MB'"
pg_conf checkpoint_timeout "'30s'"
pg_conf checkpoint_completion_target 0.1
pg_restart && "$PG_BIN/pgbench" -b tpcb-like --no-vacuum -c 16 -j 8 -T "$SECS" "$DB" >/tmp/w-ckpt.log 2>&1
report "tpcb-like checkpointing" /tmp/w-ckpt.log
pg_conf max_wal_size "'1GB'"
pg_conf checkpoint_timeout "'5min'"
pg_restart

# 9. wide rows / TOAST: multi-megabyte values, large out-of-line writes
echo "[9] large values (TOAST)"
"$PG_BIN/psql" -d "$DB" >/tmp/w-toast.log 2>&1 <<-SQL
	DROP TABLE IF EXISTS big;
	CREATE TABLE big (id serial primary key, payload text);
	INSERT INTO big (payload) SELECT repeat(md5(g::text), 40000) FROM generate_series(1, 200) g;
	CHECKPOINT;
	SELECT count(*) AS rows, pg_size_pretty(pg_total_relation_size('big')) AS size FROM big;
SQL
grep -E '^ +[0-9]+ \|' /tmp/w-toast.log | head -1 | sed 's/^/    /'
report "toast 200x1.2MB" /tmp/w-toast.log

# 10. append-only: insert-heavy, no updates, grows one relation steadily
echo "[10] append-only inserts"
"$PG_BIN/psql" -d "$DB" >/tmp/w-append.log 2>&1 <<-SQL
	DROP TABLE IF EXISTS appendlog;
	CREATE TABLE appendlog (id serial primary key, ts timestamptz default now(), pad text);
	INSERT INTO appendlog (pad) SELECT repeat('a', 512) FROM generate_series(1, 500000);
	CHECKPOINT;
	SELECT count(*) FROM appendlog;
SQL
report "append 500k rows" /tmp/w-append.log

# Consistency after all of that. Careful which invariant applies to this mix:
# tpcb-like updates accounts, tellers and branches, but simple-update only
# touches accounts (and history), so the three sums are NOT expected to match
# once both have run. What must hold is:
#   accounts == SUM(history.delta)   both scripts log every delta they apply
#   tellers  == branches             only tpcb-like touches these, by the same delta
# The runs above pass --no-vacuum for this reason: without it pgbench does
# "truncate pgbench_history" at the start of every run, so history would only
# ever reflect the last pattern.
a=$("$PG_BIN/psql" -d "$DB" -t -A -c "SELECT COALESCE(sum(abalance),0) FROM pgbench_accounts")
t=$("$PG_BIN/psql" -d "$DB" -t -A -c "SELECT COALESCE(sum(tbalance),0) FROM pgbench_tellers")
b=$("$PG_BIN/psql" -d "$DB" -t -A -c "SELECT COALESCE(sum(bbalance),0) FROM pgbench_branches")
h=$("$PG_BIN/psql" -d "$DB" -t -A -c "SELECT COALESCE(sum(delta),0) FROM pgbench_history")
echo "== invariants: accounts=$a history=$h | tellers=$t branches=$b =="
if [ "$a" != "$h" ]; then
	echo "FAIL: accounts do not match the logged deltas"
	rc=1
elif [ "$t" != "$b" ]; then
	echo "FAIL: tellers and branches diverged"
	rc=1
else
	echo "   invariants hold"
fi

"$PG_BIN/pg_ctl" -D "$DATA" stop >/dev/null 2>&1
sudo umount "$MNT" && echo "unmounted cleanly" || rc=1

echo
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
