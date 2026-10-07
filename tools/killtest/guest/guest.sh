#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# killtest, guest side: one boot of one trial.  The init stub in the rootfs
# mounts this tools disk at /kt and execs this script as PID 1, so it must
# never return; every path ends in poweroff_now or in waiting to be killed.
#
#   kt.phase=write    format the test device, lay down zeros, check them,
#                     start the overwrite -- and wait for the host's SIGKILL
#   kt.phase=verify   mount (the file system's own recovery runs here), check
#                     every chunk, fsck, power off
#   kt.phase=probe    report the guest environment and power off
#   kt.phase=db*      the database test (below)
#
# The steps are those of taujournal-test.code scripts/exp/run.exp, which drove
# the same sequence over the serial console with expect.  The run's settings
# come from /kt/run.conf, written by killtest.py.  Results and markers go to
# /dev/ttyS1, which the host reads as a file; the console (ttyS0) keeps the
# kernel log and the commands' own output.

KT=/kt
PATH=$KT/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

. $KT/run.conf

PROTO=/dev/ttyS1
TEST_DEV=/dev/nvme0n1
TEST_DIR=/mnt/test
QUEUE=/sys/block/nvme0n1/queue

say() { echo "@@KT $*" > $PROTO; }
stamp() { say "TIME $1 $(cut -d' ' -f1 /proc/uptime)"; }
# kt.<name>=<value> from the kernel command line, set per boot by killtest.py
kt_arg() { tr ' ' '\n' < /proc/cmdline | sed -n "s/^kt\.$1=//p"; }

poweroff_now() {
	sync
	echo o > /proc/sysrq-trigger
	while :; do sleep 3600; done
}

fail() {
	say "FAIL $*"
	poweroff_now
}

# Modules come from the host's /lib/modules/<release>, copied onto the tools
# disk, so they always match the kernel being booted.  The vanilla kernel has
# nvme, xfs, btrfs and f2fs as modules; the tau kernel builds most of them in.
setup_modules() {
	if [ -d $KT/modules/$(uname -r) ]; then
		mount --bind $KT/modules /lib/modules || fail "bind /lib/modules"
	fi
	[ -b $TEST_DEV ] || modprobe nvme 2>/dev/null
	i=0
	while [ ! -b $TEST_DEV ] && [ $i -lt 100 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ -b $TEST_DEV ] || fail "no test device $TEST_DEV"
	for m in $MODPROBE; do
		modprobe $m || fail "modprobe $m"
	done
}

# Only for configurations that need it (UDEV=1): zpool create partitions the
# disk and then waits for udev to settle the new partition, which never
# happens without udevd.  The SOSP round's guest ran systemd and had it.
start_udev() {
	[ "$UDEV" = 1 ] || return 0
	/usr/lib/systemd/systemd-udevd --daemon --resolve-names=never ||
		fail "systemd-udevd (mkrootfs.sh WITH_ZFS=1 installs it)"
	udevadm trigger --action=add --type=subsystems
	udevadm trigger --action=add --type=devices
	udevadm settle --timeout=30 || say "NOTE udevadm settle timed out"
}

dev_info() {
	say "DEV write_cache=$(tr ' ' '_' < $QUEUE/write_cache)" \
	    "max_sectors_kb=$(cat $QUEUE/max_sectors_kb)" \
	    "max_hw_sectors_kb=$(cat $QUEUE/max_hw_sectors_kb)" \
	    "logical_block_size=$(cat $QUEUE/logical_block_size)" \
	    "physical_block_size=$(cat $QUEUE/physical_block_size)" \
	    "scheduler=$(sed 's/.*\[\(.*\)\].*/\1/' $QUEUE/scheduler)" \
	    "wbt_lat_usec=$(cat $QUEUE/wbt_lat_usec 2>/dev/null || echo none)" \
	    "blockdevs=$(ls /sys/block | tr '\n' ',')"
}

remount() {
	cd / &&
	eval "$UMOUNT_CMD" &&
	eval "$MOUNT_CMD" &&
	cd $TEST_DIR
}

# ---- workloads (run.exp do_write_*) ----------------------------------------
#
# Every unit starts all zeros and is overwritten once with a pattern, so after
# the crash each 16 KiB chunk must read back all zeros or all pattern.

workload_prepare() {
	case "$WORKLOAD" in
	seq|rand)
		fs $TEST_OPT -Z || fail "zero fill rc=$?"
		remount || fail "remount"
		fs $TEST_OPT -Z -V > /tmp/zv.out 2>&1
		rc=$?
		cat /tmp/zv.out
		say "ZERO_VERIFY rc=$rc torn_threads=$(grep -c 'torn_write=YES' /tmp/zv.out)"
		[ $rc = 0 ] || fail "zero verify"
		;;
	rand_single)
		fs_single $TEST_OPT -Z || fail "zero fill rc=$?"
		remount || fail "remount"
		fs_single $TEST_OPT -Z -V > /tmp/zv.out 2>&1
		rc=$?
		cat /tmp/zv.out
		say "ZERO_VERIFY rc=$rc torn_threads=$(grep -c 'torn_write=YES' /tmp/zv.out)"
		[ $rc = 0 ] || fail "zero verify"
		;;
	append)
		# fragment free space first, then let the workload's files grow
		fs -t 256 -s 4M -b 4k -F 1 -C -p ./tmp.out || fail "fragment rc=$?"
		rm -f ./tmp.out*0 ./tmp.out*2 ./tmp.out*4 ./tmp.out*6 ./tmp.out*8
		remount || fail "remount"
		;;
	*)
		fail "unknown workload $WORKLOAD"
		;;
	esac
}

workload_overwrite() {
	case "$WORKLOAD" in
	seq|append)	fs $TEST_OPT ;;
	rand)		fs $TEST_OPT -R ;;
	rand_single)	fs_single $TEST_OPT -R ;;
	esac
}

verify_bin() {
	case "$WORKLOAD" in
	rand_single)	echo fs_single ;;
	*)		echo fs ;;
	esac
}

# ---- phases ------------------------------------------------------------------

phase_write() {
	say "BOOT phase=write release=$(uname -r) version=$(uname -v | tr ' ' '_')"
	setup_modules
	start_udev
	dev_info
	if [ -n "$MAX_SECTORS_KB" ] && [ "$MAX_SECTORS_KB" != 0 ]; then
		echo "$MAX_SECTORS_KB" > $QUEUE/max_sectors_kb ||
			fail "max_sectors_kb=$MAX_SECTORS_KB"
	fi
	say "DEV max_sectors_kb_now=$(cat $QUEUE/max_sectors_kb)"
	# Writeback throttling.  The SOSP round's guest kernel was built without
	# it (CONFIG_BLK_WBT=n); a kernel that has it caps how many writes are
	# in flight, and in-flight writes are what a kill tears.  0 turns it off.
	if [ -n "$WBT_LAT_USEC" ]; then
		echo "$WBT_LAT_USEC" > $QUEUE/wbt_lat_usec ||
			fail "wbt_lat_usec=$WBT_LAT_USEC"
	fi
	say "DEV wbt_lat_usec_now=$(cat $QUEUE/wbt_lat_usec 2>/dev/null || echo none)"

	stamp mkfs
	eval "$MKFS_CMD" > /tmp/mkfs.out 2>&1
	rc=$?
	cat /tmp/mkfs.out
	[ $rc = 0 ] || fail "mkfs rc=$rc"
	mkdir -p $TEST_DIR
	eval "$MOUNT_CMD" || fail "mount"
	cd $TEST_DIR || fail "cd $TEST_DIR"

	stamp prepare
	workload_prepare

	# The host kills the VM WAIT_MS after this line.  run.exp counted from
	# the moment it typed the command, which differs by the time to start
	# the program -- a few milliseconds.
	stamp overwrite
	say "WRITE_START"
	workload_overwrite
	say "WRITE_DONE rc=$?"
	while :; do sleep 3600; done
}

phase_verify() {
	say "BOOT phase=verify release=$(uname -r) version=$(uname -v | tr ' ' '_')"
	setup_modules
	start_udev
	mkdir -p $TEST_DIR

	t0=$(date +%s%N)
	eval "${VERIFY_MOUNT_CMD:-$MOUNT_CMD}" > /tmp/mount.out 2>&1
	rc=$?
	t1=$(date +%s%N)
	cat /tmp/mount.out
	say "MOUNT rc=$rc ms=$(( (t1 - t0) / 1000000 ))"
	dmesg | grep -iE "$DMESG_PAT" | grep -v 'dev fd0' | tail -n 40 | sed 's/^/@@KT DMESG /' > $PROTO
	if [ $rc != 0 ]; then
		sed 's/^/@@KT MOUNT_ERR /' /tmp/mount.out > $PROTO
		fail "mount rc=$rc"
	fi
	cd $TEST_DIR || fail "cd $TEST_DIR"

	stamp verify
	$(verify_bin) $TEST_OPT -V > /tmp/verify.out 2>&1
	rc=$?
	cat /tmp/verify.out
	sed 's/^/@@KT V /' /tmp/verify.out > $PROTO
	say "VERIFY rc=$rc"

	cd /
	eval "$UMOUNT_CMD" || say "UMOUNT failed"
	if [ -n "$FSCK_CMD" ]; then
		stamp fsck
		eval "$FSCK_CMD" > /tmp/fsck.out 2>&1
		rc=$?
		cat /tmp/fsck.out
		say "FSCK rc=$rc"
		tail -n 20 /tmp/fsck.out | sed 's/^/@@KT FSCK_OUT /' > $PROTO
	fi
	stamp done
	say "DONE"
	poweroff_now
}

phase_probe() {
	say "BOOT phase=probe release=$(uname -r) version=$(uname -v | tr ' ' '_')"
	setup_modules
	dev_info
	for m in xfs btrfs f2fs zfs; do
		if modprobe $m 2>/dev/null; then say "MOD $m ok"; else say "MOD $m missing"; fi
	done
	say "TOOL mke2fs $(mke2fs -V 2>&1 | head -n 1)"
	say "TOOL mkfs.xfs $(mkfs.xfs -V 2>&1 | head -n 1)"
	say "TOOL mkfs.btrfs $(mkfs.btrfs --version 2>&1 | head -n 1)"
	say "TOOL mkfs.f2fs $(mkfs.f2fs -V 2>&1 | head -n 1)"
	say "TOOL zfs $(zfs version 2>&1 | tr '\n' ' ')"
	say "DONE"
	poweroff_now
}

# ---- databases (killtest.py db; exp_db.sh, exp_db/*.exp of the SOSP round) ---
#
# The SOSP round's DB test: sysbench oltp_write_only on PostgreSQL (data
# checksums on, full_page_writes off) or MySQL (doublewrite off), killed a
# minute into the run; after the crash the database recovers, runs 30 s more,
# and its log is searched for "invalid page" / "Database page corruption".
# Here every data page is also checked offline: pg_checksums after recovery,
# innochecksum before it.  Binaries come from this tree's builds, on the tools
# disk under /kt/db; the server runs as ktdb (mkrootfs.sh WITH_DB=1).

DBROOT=$KT/db
DBUSER=ktdb
PGDATA=$TEST_DIR/postgres
MYDATA=$TEST_DIR/mysql
# the WAL/redo when not with the data: ZFS's zfspool/log (killtest.py zfs_cmds)
DBLOGDIR=${DB_LOG_DIR:+$TEST_DIR/$DB_LOG_DIR}
MYSOCK=/tmp/mysql.sock
PGPORT=5432
DBLOG=/tmp/db.log

# runuser may reset the environment; the builds need LD_LIBRARY_PATH
asdb() { runuser -u $DBUSER -- env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" "$@"; }

db_env() {
	export LD_LIBRARY_PATH=$DBROOT/mysql/lib:$DBROOT/pg/lib
	ip link set lo up || fail "loopback (mkrootfs.sh WITH_DB=1)"
	mkdir -p /dev/shm && mount -t tmpfs tmpfs /dev/shm
	ulimit -n 65536
}

my() { $DBROOT/mysql/bin/mysql -uroot --socket=$MYSOCK "$@"; }

# sysbench <test> <args...>, with this database's connection options
sb() {
	t=$1
	shift
	case "$DB" in
	postgres)
		sysbench "$t" --db-driver=pgsql --pgsql-host=127.0.0.1 \
			--pgsql-port=$PGPORT --pgsql-user=$DBUSER --pgsql-db=$DBNAME \
			--tables=$SB_TABLES --table-size=$SB_ROWS \
			${SB_RAND_TYPE:+--rand-type=$SB_RAND_TYPE} "$@" ;;
	mysql)
		sysbench "$t" --db-driver=mysql --mysql-user=root \
			--mysql-socket=$MYSOCK --mysql-db=$DBNAME \
			--tables=$SB_TABLES --table-size=$SB_ROWS \
			${SB_RAND_TYPE:+--rand-type=$SB_RAND_TYPE} "$@" ;;
	esac
}

db_start() {
	case "$DB" in
	postgres)
		# PG_START_OPTS: settings given at start, over postgresql.conf
		# (--cache-mb: shared_buffers other than the image's)
		if [ -n "$PG_START_OPTS" ]; then
			asdb $DBROOT/pg/bin/pg_ctl -D $PGDATA -l $DBLOG -w \
				-t $DB_START_TIMEOUT -o "$PG_START_OPTS" start
		else
			asdb $DBROOT/pg/bin/pg_ctl -D $PGDATA -l $DBLOG -w \
				-t $DB_START_TIMEOUT start
		fi ;;
	mysql)
		rm -f $MYSOCK $MYSOCK.lock /tmp/mysqld.pid
		$DBROOT/mysql/bin/mysqld --user=$DBUSER --basedir=$DBROOT/mysql \
			--lc-messages-dir=$DBROOT/mysql/share --datadir=$MYDATA \
			--socket=$MYSOCK --port=3306 --pid-file=/tmp/mysqld.pid \
			--bind-address=127.0.0.1 --skip-networking=0 \
			${DBLOGDIR:+--innodb_log_group_home_dir=$DBLOGDIR} \
			--log-error=$DBLOG $MY_OPTS &
		MYSQLD_PID=$!
		i=0
		torn=
		while [ ! -S $MYSOCK ]; do
			kill -0 $MYSQLD_PID 2>/dev/null || return 1
			[ $i -ge $DB_START_TIMEOUT ] && return 1
			# InnoDB's recovery does not get past a torn page: it
			# retries the read, then waits, until DB_START_TIMEOUT.
			# Give up DB_GIVEUP_S after it first says so.
			if [ -z "$torn" ] && [ -n "$DB_GIVEUP_PAT" ] &&
			    grep -q "$DB_GIVEUP_PAT" $DBLOG 2>/dev/null; then
				torn=$i
			fi
			[ -n "$torn" ] && [ $((i - torn)) -ge ${DB_GIVEUP_S:-60} ] &&
				return 1
			sleep 1
			i=$((i + 1))
		done ;;
	esac
}

# A server that did not come up within DB_START_TIMEOUT -- MySQL stays up
# but hangs on a corrupted page -- is killed, so that the offline scans can
# open its files.
db_kill() {
	case "$DB" in
	postgres)
		[ -f $PGDATA/postmaster.pid ] &&
			kill -9 "$(head -n 1 $PGDATA/postmaster.pid)" 2>/dev/null ;;
	mysql)
		kill -9 $MYSQLD_PID 2>/dev/null
		wait $MYSQLD_PID 2>/dev/null ;;
	esac
	sleep 1
}

db_stop() {
	case "$DB" in
	postgres)
		asdb $DBROOT/pg/bin/pg_ctl -D $PGDATA -w -t $DB_START_TIMEOUT stop ;;
	mysql)
		$DBROOT/mysql/bin/mysqladmin -uroot --socket=$MYSOCK shutdown &&
			wait $MYSQLD_PID ;;
	esac
}

# innochecksum over the sysbench tables; reports files and pages that fail.
# A run that fails without naming a page (the file is locked, say) is an
# error of the scan, not a bad page.
innochecksum_scan() {
	files=0
	badfiles=0
	badpages=0
	errors=0
	for f in $MYDATA/$DBNAME/sbtest*.ibd; do
		files=$((files + 1))
		$DBROOT/mysql/bin/innochecksum -a 100000000 "$f" > /tmp/ic.out 2>&1
		rc=$?
		n=$(grep -ci "invalid\|mismatch" /tmp/ic.out)
		if [ "$n" != 0 ]; then
			badfiles=$((badfiles + 1))
			badpages=$((badpages + n))
			say "SCAN_FILE $1 file=$(basename $f) rc=$rc bad=$n"
			grep -i "invalid\|mismatch" /tmp/ic.out | head -n 3 |
				sed "s/^/@@KT SCAN_OUT $1 /" > $PROTO
		elif [ $rc != 0 ]; then
			errors=$((errors + 1))
			[ $errors = 1 ] && head -n 2 /tmp/ic.out | sed "s/^/@@KT SCAN_OUT $1 error /" > $PROTO
		fi
	done
	say "SCAN $1 files=$files bad_files=$badfiles bad_pages=$badpages errors=$errors"
}

# the settings the server is running with, to check the run's profile
db_vars() {
	case "$DB" in
	postgres)
		say "PGVARS $(asdb $DBROOT/pg/bin/psql -h /tmp -d $DBNAME -Atc \
			"SELECT name || '=' || current_setting(name) FROM pg_settings
			 WHERE name IN ('shared_buffers', 'max_wal_size',
			 'full_page_writes', 'checkpoint_timeout', 'wal_init_zero',
			 'wal_recycle', 'log_checkpoints', 'data_checksums',
			 'checkpoint_flush_after', 'bgwriter_flush_after',
			 'backend_flush_after')
			 ORDER BY name" | tr '\n' ' ')" ;;
	mysql)
		say "MYVARS $(my -NBe "SELECT CONCAT(VARIABLE_NAME, '=', VARIABLE_VALUE)
			FROM performance_schema.global_variables WHERE VARIABLE_NAME IN
			('innodb_flush_method', 'innodb_buffer_pool_size',
			 'innodb_redo_log_capacity', 'innodb_doublewrite', 'log_bin',
			 'innodb_log_spin_cpu_pct_hwm', 'innodb_use_native_aio',
			 'innodb_flush_log_at_trx_commit', 'innodb_io_capacity',
			 'innodb_io_capacity_max', 'innodb_log_group_home_dir')
			 ORDER BY VARIABLE_NAME" | tr '\n' ' ')" ;;
	esac
	case "$FS" in
	zfs*) say "ZFSPROPS $(zfs get -H -r -t filesystem -o name,property,value \
		recordsize,compression,logbias zfspool | tr '\t' ':' | tr '\n' ' ')" ;;
	esac
}

# pgscan (src/pgscan.c): pg_checksums --check on the files as the crash
# left them, which pg_checksums itself refuses to look at
pg_scan() {
	pgscan $PGDATA > /tmp/pgscan.out 2>&1
	rc=$?
	files=$(sed -n 's/^BAD file=\([^ ]*\).*/\1/p' /tmp/pgscan.out | sort -u | wc -l)
	grep -E '^(BAD|SHORT|ERROR) ' /tmp/pgscan.out | head -n 5 |
		sed "s/^/@@KT SCAN_OUT $1 /" > $PROTO
	say "SCAN $1 rc=$rc bad_files=$files $(tail -n 1 /tmp/pgscan.out)"
}

# the database's own log, cut down to what recovery and corruption look like
db_log_report() {
	grep -iE "$DBLOG_PAT" $DBLOG | tail -n 60 | sed 's/^/@@KT DBLOG /' > $PROTO
	say "DBLOG_LINES $(wc -l < $DBLOG)"
}

phase_dbprep() {
	say "BOOT phase=dbprep release=$(uname -r) version=$(uname -v | tr ' ' '_')"
	setup_modules
	start_udev
	db_env
	dev_info
	stamp mkfs
	eval "$MKFS_CMD" > /tmp/mkfs.out 2>&1
	rc=$?
	cat /tmp/mkfs.out
	[ $rc = 0 ] || fail "mkfs rc=$rc"
	mkdir -p $TEST_DIR
	eval "$MOUNT_NEW_CMD" || fail "mount"

	stamp prepare
	case "$DB" in
	postgres)
		mkdir -p $PGDATA && chown $DBUSER $PGDATA
		# pg_wal: a symlink to the WAL's dataset, if it has one
		[ -z "$DBLOGDIR" ] || chown $DBUSER $DBLOGDIR
		asdb $DBROOT/pg/bin/initdb --data-checksums -D $PGDATA \
			${DBLOGDIR:+--waldir=$DBLOGDIR/pg_wal} || fail "initdb"
		printf '%b\n' "$PG_CONF" >> $PGDATA/postgresql.conf
		db_start || fail "postgres start"
		asdb $DBROOT/pg/bin/createdb -h /tmp $DBNAME || fail "createdb"
		sb oltp_read_write prepare || fail "sysbench prepare"
		asdb $DBROOT/pg/bin/psql -h /tmp -d $DBNAME -c "ANALYZE;"
		asdb $DBROOT/pg/bin/psql -h /tmp -d postgres -c "CHECKPOINT;"
		say "PG $(asdb $DBROOT/pg/bin/pg_controldata $PGDATA | grep -i 'checksum version' | tr -s ' ' | tr ' ' '_')"
		;;
	mysql)
		mkdir -p $MYDATA && chown $DBUSER $MYDATA
		[ -z "$DBLOGDIR" ] || chown $DBUSER $DBLOGDIR
		$DBROOT/mysql/bin/mysqld --initialize-insecure --user=$DBUSER \
			--basedir=$DBROOT/mysql --lc-messages-dir=$DBROOT/mysql/share \
			--datadir=$MYDATA \
			${DBLOGDIR:+--innodb_log_group_home_dir=$DBLOGDIR} \
			$MY_INIT_OPTS || fail "mysqld --initialize"
		db_start || { cat $DBLOG; fail "mysqld start"; }
		my -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\`;" || fail "create database"
		sb oltp_read_write prepare || fail "sysbench prepare"
		my -e "SET GLOBAL innodb_fast_shutdown=0; FLUSH LOGS;"
		;;
	esac
	db_stop || fail "stop after prepare"

	# create.exp then ran the benchmark once for 300 s and saved what it
	# left, so every trial starts from an aged database
	stamp age
	db_start || fail "start for ageing"
	db_vars
	sb $SB_WORKLOAD --threads=$SB_THREADS --time=$WARMUP_S run
	sb $SB_WORKLOAD --threads=$SB_THREADS --time=$AGE_S --report-interval=30 run \
		> /tmp/age.out 2>&1
	cat /tmp/age.out
	say "AGE $(grep -E 'transactions:' /tmp/age.out | tr -s ' ' | tr ' ' '_')"
	db_stop || fail "stop after ageing"
	say "DATASIZE $(du -sm $TEST_DIR | cut -f1)MB"
	cd /
	eval "$UMOUNT_CMD" || fail "umount"
	stamp done
	say "DONE"
	poweroff_now
}

phase_dbwrite() {
	say "BOOT phase=dbwrite release=$(uname -r) version=$(uname -v | tr ' ' '_')"
	setup_modules
	start_udev
	db_env
	dev_info
	if [ -n "$MAX_SECTORS_KB" ] && [ "$MAX_SECTORS_KB" != 0 ]; then
		echo "$MAX_SECTORS_KB" > $QUEUE/max_sectors_kb ||
			fail "max_sectors_kb=$MAX_SECTORS_KB"
	fi
	say "DEV max_sectors_kb_now=$(cat $QUEUE/max_sectors_kb)"
	if [ -n "$WBT_LAT_USEC" ]; then
		echo "$WBT_LAT_USEC" > $QUEUE/wbt_lat_usec ||
			fail "wbt_lat_usec=$WBT_LAT_USEC"
	fi
	mkdir -p $TEST_DIR
	eval "$MOUNT_CMD" || fail "mount"
	# run.sh ran innochecksum before every MySQL start
	[ "$DB" = mysql ] &&
		$DBROOT/mysql/bin/innochecksum $MYDATA/$DBNAME/sbtest*.ibd > /dev/null 2>&1
	db_start || { cat $DBLOG; fail "db start"; }
	db_vars
	stamp warmup
	sb $SB_WORKLOAD --threads=$SB_THREADS --time=$WARMUP_S run

	stamp overwrite
	say "WRITE_START"
	if [ "$KILL_ON" = time ]; then
		# run.exp waited for "Start Benchmarking", then 60 s, then WAIT_MS
		sb $SB_WORKLOAD --threads=$SB_THREADS --time=$RUN_S --report-interval=10 run
		say "WRITE_DONE rc=$?"
		while :; do sleep 3600; done
	fi

	# --kill-on writeback: ktwatch asks the host for the kill the first time
	# KILL_INFLIGHT writes have been in flight on the test device for
	# KILL_HOLD_US, once armed -- kt.delay_ms into the run, or
	# (KILL_GATE=checkpoint) that long into a PostgreSQL checkpoint.
	# KILL_INFLIGHT=0 (also --kill-on random, where the host picks the time)
	# only reports what it sees, and keeps its latest sample in the page it
	# shares with the host, which reads it after the kill.
	# the page shared with the host: QEMU's ivshmem-plain, BAR 2
	shm=
	for d in /sys/bus/pci/devices/*; do
		[ "$(cat $d/vendor)" = 0x1af4 ] && [ "$(cat $d/device)" = 0x1110 ] &&
			shm=$d
	done
	[ -n "$shm" ] || fail "no ivshmem device"
	echo 1 > $shm/enable 2>/dev/null
	sb $SB_WORKLOAD --threads=$SB_THREADS --time=$RUN_S --report-interval=10 run &
	sbpid=$!
	delay=$(kt_arg delay_ms)
	if [ "$KILL_GATE" = checkpoint ] && [ "$DB" = postgres ]; then
		ktwatch -k $KILL_INFLIGHT -d ${KILL_HOLD_US:-0} -g ${delay:-0} \
			-m $shm/resource2 -F ${WATCH_RT_PRIO:-0} -t $((RUN_S * 1000)) \
			-l $DBLOG -s "checkpoint starting" -e "checkpoint complete" > $PROTO
	else
		ktwatch -k $KILL_INFLIGHT -d ${KILL_HOLD_US:-0} -a ${delay:-0} \
			-m $shm/resource2 -F ${WATCH_RT_PRIO:-0} -t $((RUN_S * 1000)) > $PROTO
	fi
	say "WATCH_RC rc=$?"
	wait $sbpid
	rc=$?
	# what the run's checkpoints wrote (log_checkpoints), before WRITE_DONE,
	# on which the host kills the VM
	grep -E "checkpoint (starting|complete)" $DBLOG 2>/dev/null | tail -n 10 |
		sed 's/^/@@KT DBLOG /' > $PROTO
	say "WRITE_DONE rc=$rc"
	while :; do sleep 3600; done
}

phase_dbverify() {
	say "BOOT phase=dbverify release=$(uname -r) version=$(uname -v | tr ' ' '_')"
	setup_modules
	start_udev
	db_env
	mkdir -p $TEST_DIR

	t0=$(date +%s%N)
	eval "$MOUNT_CMD" > /tmp/mount.out 2>&1
	rc=$?
	t1=$(date +%s%N)
	cat /tmp/mount.out
	say "MOUNT rc=$rc ms=$(( (t1 - t0) / 1000000 ))"
	dmesg | grep -iE "$DMESG_PAT" | grep -v 'dev fd0' | tail -n 40 | sed 's/^/@@KT DMESG /' > $PROTO
	if [ $rc != 0 ]; then
		sed 's/^/@@KT MOUNT_ERR /' /tmp/mount.out > $PROTO
		fail "mount rc=$rc"
	fi

	# the data files as the crash left them, before the database touches them
	case "$DB" in
	mysql)		innochecksum_scan pre ;;
	postgres)	pg_scan pre ;;
	esac

	stamp recovery
	t0=$(date +%s%N)
	db_start
	rc=$?
	t1=$(date +%s%N)
	say "DB_START rc=$rc ms=$(( (t1 - t0) / 1000000 ))"
	if [ $rc != 0 ]; then
		# what the server was doing when it was given up on
		tail -n 25 $DBLOG | cut -c1-300 | sed 's/^/@@KT DBLOG_TAIL /' > $PROTO
		db_kill
		say "DB_KILLED"
	fi
	if [ $rc = 0 ]; then
		# run_db.sh's second run: 10 s warm-up and 30 s more after recovery
		stamp rerun
		sb $SB_WORKLOAD --threads=$SB_THREADS --time=$WARMUP_S run > /tmp/rerun.out 2>&1
		sb $SB_WORKLOAD --threads=$SB_THREADS --time=$RERUN_S run >> /tmp/rerun.out 2>&1
		rc=$?
		cat /tmp/rerun.out
		# sysbench reports failures as FATAL lines ("ignored errors" is a counter)
		say "RERUN rc=$rc errors=$(grep -c 'FATAL' /tmp/rerun.out)"
		grep "FATAL" /tmp/rerun.out | sort | uniq -c | sort -rn | head -n 5 |
			sed 's/^/@@KT RERUN_ERR /' > $PROTO
		db_stop
		say "DB_STOP rc=$?"
	fi
	db_log_report

	case "$DB" in
	postgres)
		say "PG $(asdb $DBROOT/pg/bin/pg_controldata $PGDATA | grep -iE 'checksum version|cluster state' | tr -s ' ' | tr ' ' '_' | tr '\n' ' ')"
		stamp scan
		asdb $DBROOT/pg/bin/pg_checksums --check -D $PGDATA > /tmp/pgc.out 2>&1
		rc=$?
		if grep -q "must be shut down" /tmp/pgc.out; then
			# recovery did not finish, so nothing was shut down
			pg_scan post
		else
			bad=$(sed -n 's/^Bad checksums: *//p' /tmp/pgc.out)
			say "SCAN post rc=$rc bad_pages=${bad:-?}"
			grep -v "^Checksum operation\|^Files scanned\|^Blocks scanned\|^Data checksum" /tmp/pgc.out |
				head -n 10 | sed 's/^/@@KT SCAN_OUT post /' > $PROTO
		fi
		;;
	mysql)
		stamp scan
		innochecksum_scan post
		;;
	esac

	cd /
	eval "$UMOUNT_CMD" || say "UMOUNT failed"
	stamp done
	say "DONE"
	poweroff_now
}

phase=$(sed -n 's/.*kt\.phase=\([a-z]*\).*/\1/p' /proc/cmdline)
case "$phase" in
write)		phase_write ;;
verify)		phase_verify ;;
probe)		phase_probe ;;
dbprep)		phase_dbprep ;;
dbwrite)	phase_dbwrite ;;
dbverify)	phase_dbverify ;;
*)		fail "unknown kt.phase '$phase'" ;;
esac
poweroff_now
