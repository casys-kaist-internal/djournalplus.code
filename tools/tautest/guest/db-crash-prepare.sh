#!/bin/bash
# Set a database up on a tau filesystem and leave a write workload running, so
# the host can pull the power out from under it.
#
#   usage: db-crash-prepare.sh <ext4-tau|xfs-tau> <postgres|mysql> [scale]
#
# Returns as soon as the workload is running; the workload keeps going until
# the machine dies. Pair with db-crash-verify.sh after the reboot.

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
USER_NAME=$(whoami)
SOCK=/tmp/tau-mysql.sock
RUNTIME=${RUNTIME:-600}		# workload keeps going well past the crash
SETTLE=${SETTLE:-20}		# seconds of traffic before we let the host crash us
MYSQL_ACCOUNTS=100
MYSQL_TOTAL=$((MYSQL_ACCOUNTS * 1000))	# transfers must preserve this exactly

export LD_LIBRARY_PATH="$BENCH/workspace/pg_install/lib:$MYSQL_BUILD/lib:${LD_LIBRARY_PATH:-}"

. ./db-common.sh

echo "== preparing $FS for a $WHICH crash test =="
tau_mkfs_mount

case "$WHICH" in
postgres)
	data="$MNT/postgre"; db="pgbench_s$SCALE"
	sudo mkdir -p "$data"; sudo chown -R "$USER_NAME:$USER_NAME" "$data"

	"$PG_BIN/initdb" -D "$data" >/tmp/pg-initdb.log 2>&1 || die "initdb failed"
	sed -i -E 's|^[[:space:]]*#?[[:space:]]*(full_page_writes)[[:space:]]*=.*|\1 = off|' \
		"$data/postgresql.conf"
	"$PG_BIN/pg_ctl" -D "$data" -l /tmp/pg-server.log start >/dev/null 2>&1 ||
		die "pg_ctl start failed"
	"$PG_BIN/createdb" "$db" || die "createdb failed"
	"$PG_BIN/pgbench" -i -s "$SCALE" "$db" >/tmp/pg-load.log 2>&1 || die "load failed"

	echo "[+] starting pgbench (${RUNTIME}s, 16 clients)"
	setsid nohup "$PG_BIN/pgbench" -c 16 -j 8 -T "$RUNTIME" "$db" \
		>/tmp/pg-crashload.log 2>&1 < /dev/null &
	;;
mysql)
	data="$MNT/mysql"
	sudo mkdir -p "$data"; sudo chown -R "$USER_NAME:$USER_NAME" "$data"

	"$MYSQL_BUILD/bin/mysqld" --no-defaults --initialize-insecure \
		--basedir="$MYSQL_BUILD" --datadir="$data" --user="$USER_NAME" \
		>/tmp/mysql-init.log 2>&1 || die "mysqld --initialize failed"

	setsid nohup "$MYSQL_BUILD/bin/mysqld" --no-defaults \
		--basedir="$MYSQL_BUILD" --datadir="$data" --user="$USER_NAME" \
		--socket="$SOCK" --port=3307 --innodb-doublewrite=0 \
		>/tmp/mysql-server.log 2>&1 < /dev/null &

	mysql_wait_ready || die "mysqld did not become ready"

	# A transfer workload: money only moves between rows, so SUM(bal) must be
	# the same after a crash as it was at load time. That is the invariant
	# db-crash-verify.sh checks.
	"$MYSQL_BUILD/bin/mysql" --socket="$SOCK" -u root <<-SQL >/tmp/mysql-load.log 2>&1 || die "load failed"
		CREATE DATABASE tautest;
		USE tautest;
		CREATE TABLE acct (id INT PRIMARY KEY, bal BIGINT) ENGINE=InnoDB;
		INSERT INTO acct (id, bal) SELECT n, 1000 FROM
		  (SELECT a.n + b.n*10 + 1 AS n FROM
		     (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
		      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
		     (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
		      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b) t;
		SELECT SUM(bal) AS total_at_load FROM acct;
	SQL
	echo "[+] total at load: $(grep -A1 total_at_load /tmp/mysql-load.log | tail -1) (expected $MYSQL_TOTAL)"

	# RAND() inside a WHERE clause is re-evaluated per row, which would match
	# zero or many rows and let the total drift. Draw the two ids into session
	# variables first so each statement touches exactly one row.
	echo "[+] starting transfer workload"
	setsid nohup bash -c "
		while :; do
		  echo 'USE tautest;
		        SET @a = 1 + FLOOR(RAND()*100), @b = 1 + FLOOR(RAND()*100);
		        START TRANSACTION;
		        UPDATE acct SET bal = bal - 1 WHERE id = @a;
		        UPDATE acct SET bal = bal + 1 WHERE id = @b;
		        COMMIT;'
		done | $MYSQL_BUILD/bin/mysql --socket=$SOCK -u root
	" >/tmp/mysql-crashload.log 2>&1 < /dev/null &
	;;
*)
	die "unknown target '$WHICH'"
	;;
esac

echo "[+] letting it run for ${SETTLE}s"
sleep "$SETTLE"
echo "READY-FOR-CRASH $WHICH on $FS"
