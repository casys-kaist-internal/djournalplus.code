#!/bin/bash
# Start a database on xfs-tau with a growing table, then hold the next
# allocating tau commit right after its record (before the conversion) and
# force the host log, so a power cut leaves exactly the window recovery rolls
# back (bug.md #44).  The host cuts the power when this prints READY.
#
#   usage: db-rollback-prepare.sh <postgres|mysql> [scale]
#
# Pair with db-rollback-verify.sh after the reboot.  WARNING: runs mkfs.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=xfs-tau
WHICH=${1:-postgres}
SCALE=${2:-20}
BENCH=${BENCH:-$TAU_SRCTREE/bench}
PG_BIN=${PG_BIN:-$BENCH/workspace/pg_install/bin}
MYSQL_BUILD=${MYSQL_BUILD:-$BENCH/mysql-server/build}
MNT=$TAU_MNT
USER_NAME=$(whoami)
SOCK=/tmp/tau-mysql.sock
RUNTIME=${RUNTIME:-600}
SETTLE=${SETTLE:-20}
DELAY_MS=${DELAY_MS:-30000}
P=/sys/module/tau_journal/parameters

export LD_LIBRARY_PATH="$BENCH/workspace/pg_install/lib:$MYSQL_BUILD/lib:${LD_LIBRARY_PATH:-}"

. ./db-common.sh

[ -r "$P/tau_inject_delay" ] ||
	die "no tau_inject_delay: this test needs CONFIG_TAU_PROBE_TORN=y"

echo "== preparing $FS for a $WHICH rollback test =="
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
	# pgbench_history grows with every transaction: allocating commits
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

	# Transfers that also log themselves in hist: balances and hist must agree
	# account by account after the crash, and hist keeps the tablespace growing.
	"$MYSQL_BUILD/bin/mysql" --socket="$SOCK" -u root <<-SQL >/tmp/mysql-load.log 2>&1 || die "load failed"
		CREATE DATABASE tautest;
		USE tautest;
		CREATE TABLE acct (id INT PRIMARY KEY, bal BIGINT) ENGINE=InnoDB;
		CREATE TABLE hist (id BIGINT AUTO_INCREMENT PRIMARY KEY, a INT, b INT,
		                   pad CHAR(200)) ENGINE=InnoDB;
		INSERT INTO acct (id, bal) SELECT n, 1000 FROM
		  (SELECT a.n + b.n*10 + 1 AS n FROM
		     (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
		      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
		     (SELECT 0 n UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
		      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b) t;
	SQL
	echo "[+] starting transfer workload (with hist inserts)"
	setsid nohup bash -c "
		while :; do
		  echo 'USE tautest;
		        SET @a = 1 + FLOOR(RAND()*100), @b = 1 + FLOOR(RAND()*100);
		        START TRANSACTION;
		        UPDATE acct SET bal = bal - 1 WHERE id = @a;
		        UPDATE acct SET bal = bal + 1 WHERE id = @b;
		        INSERT INTO hist (a, b, pad) VALUES (@a, @b, REPEAT(\"x\", 200));
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

echo "[+] holding the next allocating commit after its record (${DELAY_MS} ms)"
echo "$DELAY_MS" | sudo tee "$P/tau_inject_delay_ms" >/dev/null
sudo dmesg -C
echo $((1 << 3)) | sudo tee "$P/tau_inject_delay" >/dev/null	# TAU_DELAY_RECORDED
held=
for i in $(seq 1 300); do
	sudo dmesg | grep -q "injected delay at site 3," && { held=1; break; }
	sleep 0.2
done
if [ -z "$held" ]; then
	echo 0 | sudo tee "$P/tau_inject_delay" >/dev/null
	echo "INCONCLUSIVE: no allocating commit in 60 s"
	exit 0
fi
sudo dmesg | grep "injected delay at site 3," | sed 's/^/    /'

# the allocation durable, the conversion not yet run
sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x")
os.fsync(fd)
os.close(fd)' "$MNT/logforce" || die "log force failed"
sleep 1
echo "READY-FOR-CRASH $WHICH on $FS"
