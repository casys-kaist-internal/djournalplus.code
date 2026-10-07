#!/bin/bash
# One database on one tau filesystem, two sysbench workloads: what the
# database gets (TPS, p95) and what the device does for it per second (cache
# flushes, MB written) and per transaction (tau commits, records without a
# flush, host log forces).
#
#   usage: db-bench.sh <ext4-tau|xfs-tau|ext4|xfs> <postgres|mysql> [secs] [tables] [rows]
#   env:   FPW=on|off  the database's own torn-page protection (full_page_writes,
#                      doublewrite); default off -- tau provides it
#          SMALL=N     tau_cp_small_tx for the run (tau only)
#
# oltp_update_non_index rewrites pages in place; oltp_insert grows the tables,
# so the data-file fsyncs allocate.  ext4 / xfs are the plain filesystems
# (mounted without tjournal), the baselines: FPW=off is the unprotected ceiling,
# FPW=on the honest one.
# WARNING: runs mkfs on $TAU_DEV.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}; WHICH=${2:-}; SECS=${3:-300}; TABLES=${4:-16}; ROWS=${5:-1000000}
THREADS=${THREADS:-32}
case "$FS" in ext4-tau|xfs-tau|ext4|xfs) ;; *) die "usage: $0 <ext4-tau|xfs-tau|ext4|xfs> <postgres|mysql> [secs] [tables] [rows]" ;; esac
FPW=${FPW:-off}
case "$FPW" in on|off) ;; *) die "FPW: on or off" ;; esac
DW=0; [ "$FPW" = on ] && DW=1
case "$WHICH" in postgres|mysql) ;; *) die "database: postgres or mysql" ;; esac
BENCH=${BENCH:-$TAU_SRCTREE/bench}
PG_BIN=${PG_BIN:-$BENCH/workspace/pg_install/bin}
MYSQL_BUILD=${MYSQL_BUILD:-$BENCH/mysql-server/build}
MNT=$TAU_MNT
SOCK=/tmp/tau-mysql.sock
PORT=5433
P=/sys/module/tau_journal/parameters
DEVNAME=$(basename "$(readlink -f "$TAU_DEV")")
# a multipath head (the PM1733 shares namespaces) counts nothing: its path,
# nvme<ctrl>c<path>n<ns>, does
DEVSTAT=$(ls -d /sys/block/${DEVNAME%n*}c*n${DEVNAME##*n} 2>/dev/null | head -1)
DEVSTAT=${DEVSTAT:-/sys/block/$DEVNAME}/stat
export LD_LIBRARY_PATH="$BENCH/workspace/pg_install/lib:$MYSQL_BUILD/lib:${LD_LIBRARY_PATH:-}"
. ./db-common.sh
command -v sysbench >/dev/null || die "sysbench is not installed in this guest"

stop_db() {
	"$PG_BIN/pg_ctl" -D "$MNT/pg" -m fast stop >/dev/null 2>&1
	"$MYSQL_BUILD/bin/mysqladmin" --socket="$SOCK" -u root shutdown >/dev/null 2>&1
	sleep 1
	sudo umount "$MNT" 2>/dev/null
}
trap stop_db EXIT

# where the device writes come from, per workload (probe builds)
PROBES="jwrite_blocks revoke_taken flush_submit cpw_small cpw_aged cpw_removed cpw_pressure cpw_memory cpw_other cp_rewritten"
probes_now() { for c in $PROBES; do cat "$P/tau_probe_$c" 2>/dev/null || echo 0; done; }

# write I/Os, sectors written, flush I/Os (Documentation/block/stat.rst)
dev_stat() { awk '{print $5, $7, $16}' "$DEVSTAT"; }
probe() { cat "$P/tau_probe_$1" 2>/dev/null || echo 0; }

case "$FS" in
*-tau)	tau_mkfs_mount ;;
ext4)	sudo umount "$MNT" 2>/dev/null; sudo mkdir -p "$MNT"
	sudo /usr/sbin/mke2fs -t ext4 -F -E lazy_itable_init=0,lazy_journal_init=0 "$TAU_DEV" >/dev/null 2>&1 &&
		sudo mount -t ext4 "$TAU_DEV" "$MNT" || die "plain ext4 failed" ;;
xfs)	sudo umount "$MNT" 2>/dev/null; sudo mkdir -p "$MNT"
	# no distribution mkfs.xfs in the guest; the patched one, mounted without tjournal
	sudo "$MKFS_XFS" -f "$TAU_DEV" >/dev/null 2>&1 &&
		sudo mount -t xfs "$TAU_DEV" "$MNT" || die "plain xfs failed" ;;
esac
sudo chown -R "$(whoami)" "$MNT"

case "$WHICH" in
postgres)
	"$PG_BIN/initdb" -D "$MNT/pg" >/tmp/pg-initdb.log 2>&1 || die "initdb failed"
	cat >> "$MNT/pg/postgresql.conf" <<-EOF
	port = $PORT
	listen_addresses = 'localhost'
	full_page_writes = $FPW
	shared_buffers = '1GB'
	max_wal_size = '4GB'
	checkpoint_timeout = '60s'
	checkpoint_completion_target = 0.9
	max_connections = 200
	EOF
	"$PG_BIN/pg_ctl" -D "$MNT/pg" -l /tmp/pg-server.log start >/dev/null 2>&1 ||
		die "pg start failed (see /tmp/pg-server.log)"
	"$PG_BIN/createdb" -p $PORT sb || die "createdb failed"
	SB="--db-driver=pgsql --pgsql-host=localhost --pgsql-port=$PORT --pgsql-user=$(whoami) --pgsql-db=sb"
	;;
mysql)
	"$MYSQL_BUILD/bin/mysqld" --no-defaults --initialize-insecure \
		--basedir="$MYSQL_BUILD" --datadir="$MNT/mysql" --user="$(whoami)" \
		>/tmp/mysql-init.log 2>&1 || die "mysqld --initialize failed"
	setsid nohup "$MYSQL_BUILD/bin/mysqld" --no-defaults \
		--basedir="$MYSQL_BUILD" --datadir="$MNT/mysql" --user="$(whoami)" \
		--socket="$SOCK" --port=3307 --innodb-doublewrite=$DW \
		--innodb-buffer-pool-size=1G --innodb-flush-method=O_DIRECT \
		--innodb-flush-log-at-trx-commit=1 --max-connections=200 \
		>/tmp/mysql-server.log 2>&1 < /dev/null &
	mysql_wait_ready || die "mysqld did not become ready"
	"$MYSQL_BUILD/bin/mysql" --socket="$SOCK" -u root -e "CREATE DATABASE sb" || die "create database"
	SB="--db-driver=mysql --mysql-socket=$SOCK --mysql-user=root --mysql-db=sb"
	;;
esac
SB="$SB --tables=$TABLES --table-size=$ROWS"
if [ -n "${SMALL:-}" ]; then
	echo "$SMALL" | sudo tee $P/tau_cp_small_tx >/dev/null || die "cannot set tau_cp_small_tx"
fi

t0=$(date +%s)
sysbench oltp_update_non_index $SB --threads=16 prepare >/tmp/sb-prepare.log 2>&1 ||
	{ tail -5 /tmp/sb-prepare.log; die "sysbench prepare failed"; }
echo "== $FS $WHICH fpw $FPW${SMALL:+ small_tx $SMALL}: $TABLES x $ROWS rows loaded in $(( $(date +%s) - t0 ))s, $THREADS threads, ${SECS}s per workload =="

for wl in oltp_update_non_index oltp_insert; do
	read -r w0 s0 f0 <<< "$(dev_stat)"
	c0=$(probe commits); n0=$(probe record_noflush); h0=$(probe commit_hostforce)
	pr0=($(probes_now))
	sysbench $wl $SB --threads=$THREADS --time=$SECS run >/tmp/sb-$wl.log 2>&1 ||
		{ tail -5 /tmp/sb-$wl.log; die "sysbench $wl failed"; }
	read -r w1 s1 f1 <<< "$(dev_stat)"
	c1=$(probe commits); n1=$(probe record_noflush); h1=$(probe commit_hostforce)
	pr1=($(probes_now))
	tps=$(sed -n 's/.*transactions: *[0-9]* *(\([0-9.]*\) per sec.*/\1/p' /tmp/sb-$wl.log)
	p95=$(sed -n 's/.*95th percentile: *\([0-9.]*\).*/\1/p' /tmp/sb-$wl.log)
	awk -v wl=$wl -v tps="$tps" -v p95="$p95" -v s=$SECS \
	    -v fl=$((f1 - f0)) -v sec=$((s1 - s0)) -v c=$((c1 - c0)) -v n=$((n1 - n0)) -v h=$((h1 - h0)) \
	    'BEGIN { printf "RESULT %-22s TPS %9.1f  p95 %7.2f ms  flush/s %7.1f  MB/s %7.1f  tau commits/s %6.1f  noflush/s %6.1f  hostforce/s %6.1f\n",
	             wl, tps, p95, fl / s, sec * 512 / s / 1048576, c / s, n / s, h / s }'
	case "$FS" in *-tau)
		i=0; line="PROBE  $wl  per 1000 tx:"
		for c in $PROBES; do
			line+=$(awk -v d=$((pr1[i] - pr0[i])) -v t="$tps" -v s=$SECS -v n=$c \
				'BEGIN { printf "  %s %.1f", n, (t > 0 ? d / (t * s) * 1000 : 0) }')
			i=$((i + 1))
		done
		echo "$line" ;;
	esac
done
