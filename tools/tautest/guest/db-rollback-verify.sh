#!/bin/bash
# After the cut: tau recovery must have rolled a commit back, and the database
# must recover over it and keep its transactional invariant.
#
#   usage: db-rollback-verify.sh <postgres|mysql> [scale]
#
# Exit 0 PASS, 1 FAIL, 2 INCONCLUSIVE (no rollback happened; the database
# was still checked).

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=xfs-tau
WHICH=${1:-postgres}
SCALE=${2:-20}
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
echo "--- tau recovery ---"
sudo dmesg | grep -E 'TAU: (replay done|.*rolled back|.*not durable)' | sed 's/^/    /'
rolled=$(sudo dmesg | grep -c 'rolled back')

verify_postgres() {
	local data="$MNT/postgre" db="pgbench_s$SCALE" a t b hist rows

	"$PG_BIN/pg_ctl" -D "$data" -l /tmp/pg-recovery.log start >/dev/null 2>&1 ||
		{ echo "FAIL: postgres would not start"; tail -40 /tmp/pg-recovery.log; return 1; }
	grep -E 'redo|recovery|ready to accept' /tmp/pg-recovery.log | head -6 | sed 's/^/    /'
	if grep -qE 'PANIC|FATAL|corrupt|invalid page|could not read' /tmp/pg-recovery.log; then
		echo "FAIL: postgres logged errors during recovery"
		grep -E 'PANIC|FATAL|corrupt|invalid page|could not read' /tmp/pg-recovery.log | head -10
		return 1
	fi
	q() { "$PG_BIN/psql" -d "$db" -t -A -c "$1" 2>/dev/null; }
	a=$(q "SELECT COALESCE(sum(abalance),0) FROM pgbench_accounts")
	t=$(q "SELECT COALESCE(sum(tbalance),0) FROM pgbench_tellers")
	b=$(q "SELECT COALESCE(sum(bbalance),0) FROM pgbench_branches")
	hist=$(q "SELECT COALESCE(sum(delta),0) FROM pgbench_history")
	rows=$(q "SELECT count(*) FROM pgbench_accounts")
	echo "    accounts=$a tellers=$t branches=$b history=$hist rows=$rows"
	if [ -z "$a" ] || [ "$a" != "$t" ] || [ "$a" != "$b" ] || [ "$a" != "$hist" ] ||
	   [ "$rows" != "$((SCALE * 100000))" ]; then
		echo "FAIL: invariant broken"
		return 1
	fi
	echo "    invariant holds (accounts == tellers == branches == history)"
	"$PG_BIN/pgbench" -c 4 -j 2 -T 10 "$db" >/tmp/pg-post.log 2>&1 ||
		{ echo "FAIL: cannot run against the recovered database"; return 1; }
	"$PG_BIN/pg_ctl" -D "$data" stop >/dev/null 2>&1
	return 0
}

verify_mysql() {
	local data="$MNT/mysql" total bad n

	setsid nohup "$MYSQL_BUILD/bin/mysqld" --no-defaults \
		--basedir="$MYSQL_BUILD" --datadir="$data" --user="$(whoami)" \
		--socket="$SOCK" --port=3307 --innodb-doublewrite=0 \
		>/tmp/mysql-recovery.log 2>&1 < /dev/null &
	mysql_wait_ready || { echo "FAIL: mysqld did not come back"; tail -40 /tmp/mysql-recovery.log; return 1; }
	if grep -qiE '\[ERROR\]|corrupt|assertion|signal 11' /tmp/mysql-recovery.log; then
		echo "FAIL: mysqld logged errors during recovery"
		grep -iE '\[ERROR\]|corrupt|assertion|signal 11' /tmp/mysql-recovery.log | head -10
		return 1
	fi
	m() { "$MYSQL_BUILD/bin/mysql" --socket="$SOCK" -u root -N -B -e "$1" 2>/dev/null; }
	total=$(m "SELECT SUM(bal) FROM tautest.acct")
	n=$(m "SELECT COUNT(*) FROM tautest.hist")
	# every account's balance is what its hist rows say
	bad=$(m "SELECT COUNT(*) FROM tautest.acct x
		 LEFT JOIN (SELECT a AS id, COUNT(*) AS c FROM tautest.hist GROUP BY a) o ON o.id = x.id
		 LEFT JOIN (SELECT b AS id, COUNT(*) AS c FROM tautest.hist GROUP BY b) i ON i.id = x.id
		 WHERE x.bal <> 1000 - COALESCE(o.c, 0) + COALESCE(i.c, 0)")
	echo "    SUM(bal)=$total (want 100000), hist rows=$n, accounts off their hist=$bad"
	if [ -z "$total" ] || [ "$total" != 100000 ] || [ "$bad" != 0 ]; then
		echo "FAIL: invariant broken"
		return 1
	fi
	echo "    invariant holds (balances match hist, total preserved)"
	m "CHECK TABLE tautest.acct, tautest.hist" | sed 's/^/    /'
	m "CHECK TABLE tautest.acct, tautest.hist" | grep -qi error &&
		{ echo "FAIL: CHECK TABLE reported a problem"; return 1; }
	"$MYSQL_BUILD/bin/mysqladmin" --socket="$SOCK" -u root shutdown >/dev/null 2>&1
	return 0
}

case "$WHICH" in
postgres) verify_postgres || rc=1 ;;
mysql)    verify_mysql    || rc=1 ;;
*)        die "unknown target '$WHICH'" ;;
esac

faults=$(kernel_faults)
echo "== kernel faults: $faults =="
[ "$faults" = 0 ] || { show_kernel_faults; rc=1; }
sudo umount "$MNT" || rc=1

if [ $rc -ne 0 ]; then
	echo "RESULT: FAIL"
	exit 1
elif [ "$rolled" -eq 0 ]; then
	echo "RESULT: INCONCLUSIVE (database consistent, but no commit was rolled back)"
	exit 2
fi
echo "RESULT: PASS ($rolled commit(s) rolled back, database consistent)"
exit 0
