#!/bin/bash
# After a crash: mount the tau filesystem, restart the database, and check that
# it recovered into a consistent state.
#
#   usage: db-crash-verify.sh <ext4-tau|xfs-tau> <postgres|mysql> [scale]
#
# Two layers of recovery run here, and both have to be clean:
#   1. tau replays its journal at mount time
#   2. the database replays its own WAL/redo at startup
#
# The verdict is a transactional invariant, not just "it started":
#   postgres  every pgbench transaction moves the same delta through accounts,
#             tellers and branches, so those three sums must be equal, and must
#             match SUM(delta) in pgbench_history.
#   mysql     the workload only moves balance between rows, so SUM(bal) must
#             still be the value recorded at load time.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
WHICH=${2:-postgres}
SCALE=${3:-20}
[ -n "$FS" ] || die "usage: $0 <ext4-tau|xfs-tau> <postgres|mysql> [scale]"

BENCH=${BENCH:-$TAU_SRCTREE/bench}
PG_BIN=${PG_BIN:-$BENCH/workspace/pg_install/bin}
MYSQL_BUILD=${MYSQL_BUILD:-$BENCH/mysql-server/build}
MNT=$TAU_MNT
SOCK=/tmp/tau-mysql.sock
rc=0

export LD_LIBRARY_PATH="$BENCH/workspace/pg_install/lib:$MYSQL_BUILD/lib:${LD_LIBRARY_PATH:-}"

. ./db-common.sh

echo "== recovery mount =="
tau_mount_only

verify_postgres() {
	local data="$MNT/postgre" db="pgbench_s$SCALE" fail=0
	local a t b hist rows

	echo "[+] restarting postgres (WAL recovery)"
	"$PG_BIN/pg_ctl" -D "$data" -l /tmp/pg-recovery.log start >/dev/null 2>&1 ||
		{ echo "FAIL: postgres would not start"; tail -40 /tmp/pg-recovery.log; return 1; }

	echo "--- recovery log ---"
	grep -E 'redo|recovery|ready to accept' /tmp/pg-recovery.log | head -6 | sed 's/^/    /'

	if grep -qE 'PANIC|FATAL|corrupt|invalid page|could not read' /tmp/pg-recovery.log; then
		echo "FAIL: postgres logged errors during recovery"
		grep -E 'PANIC|FATAL|corrupt|invalid page|could not read' /tmp/pg-recovery.log | head -10
		fail=1
	fi

	a=$("$PG_BIN/psql" -d "$db" -t -A -c "SELECT COALESCE(sum(abalance),0) FROM pgbench_accounts" 2>/dev/null)
	t=$("$PG_BIN/psql" -d "$db" -t -A -c "SELECT COALESCE(sum(tbalance),0) FROM pgbench_tellers" 2>/dev/null)
	b=$("$PG_BIN/psql" -d "$db" -t -A -c "SELECT COALESCE(sum(bbalance),0) FROM pgbench_branches" 2>/dev/null)
	hist=$("$PG_BIN/psql" -d "$db" -t -A -c "SELECT COALESCE(sum(delta),0) FROM pgbench_history" 2>/dev/null)
	rows=$("$PG_BIN/psql" -d "$db" -t -A -c "SELECT count(*) FROM pgbench_accounts" 2>/dev/null)

	echo "--- consistency ---"
	echo "    accounts=$a tellers=$t branches=$b history=$hist rows=$rows"

	if [ -z "$a" ] || [ -z "$t" ] || [ -z "$b" ]; then
		echo "FAIL: could not read the tables back"
		fail=1
	elif [ "$a" != "$t" ] || [ "$a" != "$b" ]; then
		echo "FAIL: balances diverged — a committed transaction was torn"
		fail=1
	elif [ "$a" != "$hist" ]; then
		echo "FAIL: history does not match balances ($a vs $hist)"
		fail=1
	elif [ "$rows" != "$((SCALE * 100000))" ]; then
		echo "FAIL: expected $((SCALE * 100000)) accounts, found $rows"
		fail=1
	else
		echo "    invariant holds (accounts == tellers == branches == history)"
	fi

	echo "[+] short workload on the recovered database"
	"$PG_BIN/pgbench" -c 4 -j 2 -T 10 "$db" >/tmp/pg-post.log 2>&1 &&
		grep -E '^tps' /tmp/pg-post.log | sed 's/^/    /' ||
		{ echo "FAIL: cannot run against the recovered database"; fail=1; }

	"$PG_BIN/pg_ctl" -D "$data" stop >/dev/null 2>&1
	return $fail
}

verify_mysql() {
	local data="$MNT/mysql" fail=0 total want

	echo "[+] restarting mysqld (InnoDB redo recovery)"
	setsid nohup "$MYSQL_BUILD/bin/mysqld" --no-defaults \
		--basedir="$MYSQL_BUILD" --datadir="$data" --user="$(whoami)" \
		--socket="$SOCK" --port=3307 --innodb-doublewrite=0 \
		>/tmp/mysql-recovery.log 2>&1 < /dev/null &

	mysql_wait_ready || { echo "FAIL: mysqld did not come back"; tail -40 /tmp/mysql-recovery.log; return 1; }

	echo "--- recovery log ---"
	grep -iE 'recover|rollback|crash|starting' /tmp/mysql-recovery.log | head -6 | sed 's/^/    /'

	if grep -qiE '\[ERROR\]|corrupt|assertion|signal 11' /tmp/mysql-recovery.log; then
		echo "FAIL: mysqld logged errors during recovery"
		grep -iE '\[ERROR\]|corrupt|assertion|signal 11' /tmp/mysql-recovery.log | head -10
		fail=1
	fi

	total=$("$MYSQL_BUILD/bin/mysql" --socket="$SOCK" -u root -N -B \
		-e "SELECT SUM(bal) FROM tautest.acct" 2>/dev/null)
	# Constant, not a file: /tmp does not survive the reboot, and an unreadable
	# expectation used to make this check pass silently.
	want=$((100 * 1000))
	echo "--- consistency ---"
	echo "    SUM(bal)=$total  expected=$want"
	if [ -z "$total" ]; then
		echo "FAIL: could not read the table back"; fail=1
	elif [ "$total" != "$want" ]; then
		echo "FAIL: balance total changed — a transfer was torn"; fail=1
	else
		echo "    invariant holds (transfers preserved the total)"
	fi

	"$MYSQL_BUILD/bin/mysql" --socket="$SOCK" -u root -N -B \
		-e "CHECK TABLE tautest.acct" 2>/dev/null | sed 's/^/    /'
	"$MYSQL_BUILD/bin/mysql" --socket="$SOCK" -u root -N -B \
		-e "CHECK TABLE tautest.acct" 2>/dev/null | grep -qi "error" &&
		{ echo "FAIL: CHECK TABLE reported a problem"; fail=1; }

	"$MYSQL_BUILD/bin/mysqladmin" --socket="$SOCK" -u root shutdown >/dev/null 2>&1
	return $fail
}

case "$WHICH" in
postgres) verify_postgres || rc=1 ;;
mysql)    verify_mysql    || rc=1 ;;
*)        die "unknown target '$WHICH'" ;;
esac

echo
faults=$(kernel_faults)
echo "== kernel faults: $faults =="
if [ "$faults" != "0" ]; then
	show_kernel_faults
	rc=1
fi

echo "--- tau recovery ---"
sudo dmesg | grep -E 'TAU: (replay done|found revoke|no valid|invalid)' | tail -6 | sed 's/^/    /'

sudo umount "$MNT" && echo "unmounted cleanly" || rc=1

echo
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
