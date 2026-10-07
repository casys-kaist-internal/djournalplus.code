#!/bin/bash
# Bring a real database up on a tau filesystem and run a small workload.
#
# This is a "does the patch survive real software" check, not a benchmark:
# initdb / start / load / run / clean shutdown, then look for anything the
# kernel complained about. It mirrors what bench/scripts does, at tiny scale.
#
#   usage: db-smoke.sh <ext4-tau|xfs-tau> [postgres|mysql|both] [scale]
#
# Filesystem names and mount options follow bench/scripts/common.sh:
#   ext4-tau : patched mke2fs, mount -o tjournal,tjournal_size=32
#   xfs-tau  : patched mkfs.xfs -l tjmaxsize=1G, mount -o tjournal

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
WHICH=${2:-both}
SCALE=${3:-10}
[ -n "$FS" ] || die "usage: $0 <ext4-tau|xfs-tau> [postgres|mysql|both] [scale]"

BENCH=${BENCH:-$TAU_SRCTREE/bench}
PG_BIN=${PG_BIN:-$BENCH/workspace/pg_install/bin}
PG_LIB=${PG_LIB:-$BENCH/workspace/pg_install/lib}
MYSQL_BUILD=${MYSQL_BUILD:-$BENCH/mysql-server/build}
# Extra mysqld flags. Note XFS+tjournal currently refuses O_DIRECT opens
# (xfs_file_open clears FMODE_CAN_ODIRECT for the whole mount), so
# --innodb-flush-method=O_DIRECT makes InnoDB log a startup error there.
MYSQL_EXTRA_ARGS=${MYSQL_EXTRA_ARGS:-}
MNT=$TAU_MNT
USER_NAME=$(whoami)

export LD_LIBRARY_PATH="$PG_LIB:$MYSQL_BUILD/lib:${LD_LIBRARY_PATH:-}"

rc=0

# --- filesystem -------------------------------------------------------------
tau_mkfs_mount() {
	sudo umount "$MNT" 2>/dev/null || true
	case "$FS" in
	ext4-tau)
		[ -x "$MKE2FS" ] || die "missing patched mke2fs at $MKE2FS"
		sudo "$MKE2FS" -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 \
			-F "$TAU_DEV" >/dev/null 2>&1 || die "mke2fs failed"
		sudo mkdir -p "$MNT"
		sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$MNT" ||
			die "mount ext4 -o tjournal failed"
		;;
	xfs-tau)
		[ -x "$MKFS_XFS" ] || die "missing patched mkfs.xfs at $MKFS_XFS"
		sudo "$MKFS_XFS" "$TAU_DEV" -f -l tjmaxsize=1G >/dev/null 2>&1 ||
			die "mkfs.xfs failed"
		sudo mkdir -p "$MNT"
		sudo mount -t xfs -o tjournal "$TAU_DEV" "$MNT" ||
			die "mount xfs -o tjournal failed"
		;;
	*)
		die "unknown fs '$FS' (want ext4-tau or xfs-tau)"
		;;
	esac
	echo "[+] $FS mounted on $MNT"
}

# --- postgres ---------------------------------------------------------------
run_postgres() {
	local data="$MNT/postgre" db="pgbench_s$SCALE" fail=0

	echo
	echo "===== PostgreSQL on $FS ====="
	[ -x "$PG_BIN/initdb" ] || { echo "SKIP: no postgres build at $PG_BIN"; return 0; }

	sudo mkdir -p "$data"
	sudo chown -R "$USER_NAME:$USER_NAME" "$data"

	echo "[+] initdb"
	"$PG_BIN/initdb" -D "$data" >/tmp/pg-initdb.log 2>&1 ||
		{ echo "FAIL: initdb"; tail -20 /tmp/pg-initdb.log; return 1; }

	# full_page_writes off is what the bench scripts use: it is the setting tau
	# is meant to make safe, so it is the interesting one to exercise.
	sed -i -E 's|^[[:space:]]*#?[[:space:]]*(full_page_writes)[[:space:]]*=.*|\1 = off|' \
		"$data/postgresql.conf"

	echo "[+] start"
	"$PG_BIN/pg_ctl" -D "$data" -l /tmp/pg-server.log start >/dev/null 2>&1 ||
		{ echo "FAIL: pg_ctl start"; tail -30 /tmp/pg-server.log; return 1; }

	echo "[+] createdb + load (scale $SCALE)"
	"$PG_BIN/createdb" "$db" >/tmp/pg-load.log 2>&1 &&
	"$PG_BIN/pgbench" -i -s "$SCALE" "$db" >>/tmp/pg-load.log 2>&1 ||
		{ echo "FAIL: load"; tail -20 /tmp/pg-load.log; fail=1; }

	if [ $fail -eq 0 ]; then
		echo "[+] pgbench 20s, 8 clients"
		"$PG_BIN/pgbench" -c 8 -j 4 -T 20 -P 10 "$db" >/tmp/pg-run.log 2>&1 ||
			{ echo "FAIL: pgbench run"; tail -20 /tmp/pg-run.log; fail=1; }
		grep -E '^(tps|latency average)' /tmp/pg-run.log | sed 's/^/    /'
	fi

	echo "[+] checkpoint + stop"
	"$PG_BIN/psql" -d postgres -c "CHECKPOINT;" >/dev/null 2>&1
	"$PG_BIN/pg_ctl" -D "$data" stop >/dev/null 2>&1 ||
		{ echo "FAIL: pg_ctl stop"; fail=1; }

	# The server log is the real verdict: PANIC/FATAL/corruption complaints.
	if grep -qE 'PANIC|FATAL|could not|corrupt|invalid page' /tmp/pg-server.log 2>/dev/null; then
		echo "FAIL: postgres logged errors"
		grep -E 'PANIC|FATAL|could not|corrupt|invalid page' /tmp/pg-server.log | head -10
		fail=1
	fi

	[ $fail -eq 0 ] && echo "PostgreSQL: PASS" || echo "PostgreSQL: FAIL"
	return $fail
}

# --- mysql ------------------------------------------------------------------
run_mysql() {
	local data="$MNT/mysql" sock=/tmp/tau-mysql.sock fail=0

	echo
	echo "===== MySQL on $FS ====="
	[ -x "$MYSQL_BUILD/bin/mysqld" ] || { echo "SKIP: no mysql build at $MYSQL_BUILD"; return 0; }

	sudo mkdir -p "$data"
	sudo chown -R "$USER_NAME:$USER_NAME" "$data"

	echo "[+] initialize"
	"$MYSQL_BUILD/bin/mysqld" --no-defaults --initialize-insecure \
		--basedir="$MYSQL_BUILD" --datadir="$data" \
		--user="$USER_NAME" >/tmp/mysql-init.log 2>&1 ||
		{ echo "FAIL: mysqld --initialize"; tail -20 /tmp/mysql-init.log; return 1; }

	echo "[+] start"
	"$MYSQL_BUILD/bin/mysqld" --no-defaults \
		--basedir="$MYSQL_BUILD" --datadir="$data" --user="$USER_NAME" \
		--socket="$sock" --port=3307 --skip-networking=0 \
		${MYSQL_EXTRA_ARGS:-} \
		--innodb-doublewrite=0 \
		>/tmp/mysql-server.log 2>&1 &
	local pid=$!

	local waited=0
	while [ $waited -lt 60 ]; do
		"$MYSQL_BUILD/bin/mysqladmin" --socket="$sock" -u root ping >/dev/null 2>&1 && break
		kill -0 $pid 2>/dev/null || { echo "FAIL: mysqld died"; tail -30 /tmp/mysql-server.log; return 1; }
		sleep 2; waited=$((waited + 2))
	done
	[ $waited -lt 60 ] || { echo "FAIL: mysqld did not become ready"; tail -30 /tmp/mysql-server.log; return 1; }

	echo "[+] create + write workload"
	"$MYSQL_BUILD/bin/mysql" --socket="$sock" -u root <<-SQL >/tmp/mysql-work.log 2>&1
		CREATE DATABASE tautest;
		USE tautest;
		CREATE TABLE t (id INT PRIMARY KEY AUTO_INCREMENT, pad CHAR(200)) ENGINE=InnoDB;
		SET autocommit=1;
		INSERT INTO t (pad) SELECT REPEAT('x', 200) FROM
			(SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) a,
			(SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) b,
			(SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) c,
			(SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) d,
			(SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) e;
		SELECT COUNT(*) AS rows_loaded FROM t;
		FLUSH TABLES;
	SQL
	if [ $? -ne 0 ]; then
		echo "FAIL: sql workload"; tail -20 /tmp/mysql-work.log; fail=1
	else
		grep -A1 rows_loaded /tmp/mysql-work.log | tail -1 | sed 's/^/    rows: /'
	fi

	echo "[+] shutdown"
	"$MYSQL_BUILD/bin/mysqladmin" --socket="$sock" -u root shutdown >/dev/null 2>&1
	wait $pid 2>/dev/null

	if grep -qiE '\[ERROR\]|corrupt|assertion|signal 11' /tmp/mysql-server.log 2>/dev/null; then
		echo "FAIL: mysqld logged errors"
		grep -iE '\[ERROR\]|corrupt|assertion|signal 11' /tmp/mysql-server.log | head -10
		fail=1
	fi

	[ $fail -eq 0 ] && echo "MySQL: PASS" || echo "MySQL: FAIL"
	return $fail
}

# --- main -------------------------------------------------------------------
echo "== $FS / $WHICH / scale $SCALE =="
tau_mkfs_mount
sudo dmesg -C

case "$WHICH" in
postgres) run_postgres || rc=1 ;;
mysql)    run_mysql    || rc=1 ;;
both)     run_postgres || rc=1; run_mysql || rc=1 ;;
*)        die "unknown target '$WHICH'" ;;
esac

echo
faults=$(kernel_faults)
echo "== kernel faults: $faults =="
if [ "$faults" != "0" ]; then
	show_kernel_faults
	rc=1
fi

sudo umount "$MNT" && echo "unmounted cleanly" || rc=1

echo
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
