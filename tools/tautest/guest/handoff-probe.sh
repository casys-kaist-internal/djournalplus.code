#!/bin/bash
# plan.md §3 (eager remove), measurement only: how long does a checkpoint tx
# outlive the last of its blocks that went back to the journal, and do writers
# wait for journal space meanwhile?  Needs CONFIG_TAU_PROBE_TORN.
#   usage: handoff-probe.sh <xfs|ext4> pgsim|torn|pg
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; W=$2
P=/sys/module/tau_journal/parameters
C="rejournal_gate handoff handoff_drain handoff_drain_ms handoff_drain_max_ms
   handoff_drain_1s space_wait space_wait_ms tx_dropped commits revoke_taken enospc"

reset() { for c in $C; do echo 0 | sudo tee $P/tau_probe_$c >/dev/null; done; }
show() {
	for c in $C; do printf '%s=%s ' $c "$(cat $P/tau_probe_$c)"; done
	echo
}

case "$W" in
pgsim)
	# plan.md §3.3: 8 writers on one file, small journal (the mount option
	# is the cap on XFS too: mkfs tjmaxsize rounds up to a 32 GiB map block)
	export TAU_MOUNT_OPTS="tjournal,tjournal_size=1"
	mkfs_mount "$FS"
	reset
	t0=$SECONDS
	sudo python3 - "$TAU_MNT/rel" ${PAGES:-3000} ${PHASES:-12} ${PROCS:-8} <<-'EOF'
		import os, sys
		from multiprocessing import Process
		path, pages, phases, procs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
		def worker(n):
		    fd = os.open(path, os.O_CREAT | os.O_RDWR | 0o40000000, 0o644)
		    buf = bytes([n + 1]) * 8192
		    for p in range(phases):
		        for i in range(pages):
		            os.pwrite(fd, buf, i * 8192)
		        os.fsync(fd)
		    os.close(fd)
		ps = [Process(target=worker, args=(n,)) for n in range(procs)]
		for p in ps: p.start()
		for p in ps: p.join()
	EOF
	echo "pgsim $FS: $((SECONDS - t0)) s"
	show
	sudo umount "$TAU_MNT"
	;;
torn)
	# the torn-test soak configuration; torn-write.sh does its own mkfs
	reset
	TAU_JOURNAL_GB=1 PAGE_KB=8 FSYNC_EVERY=16 HOT_PCT=60 PREALLOC=fallocate \
		MODE=churn CHUNK_PAGES=256 ./torn-write.sh "$FS" 300 8 1024 4 >/dev/null 2>&1
	echo "torn $FS: rc=$?"
	show
	;;
pg)
	# PostgreSQL, sysbench oltp_update_non_index (pg-torn.sh, its defaults)
	# pg-torn zeroes every counter between the load and the run; both dumped.
	# PG_GB sizes the load journal, PG_RUN_GB the run's (default: the same)
	DUMP_ALL=1 TAU_JOURNAL_GB=${PG_RUN_GB:-${PG_GB:-16}} LOAD_JOURNAL_GB=${PG_GB:-16} \
		THREADS=32 SHARED_BUFFERS=128MB \
		FPW=off LOAD_ONLY=0 DATA_CHECKSUMS=on FS="$FS" \
		./pg-torn.sh 300 16 2600000 > /tmp/pg-$FS.log 2>&1
	echo "pg $FS: rc=$?"
	grep -E "transactions:|journal peak|^-- all counters" -A0 /tmp/pg-$FS.log
	sed -n '/^-- all counters, load --/,/^--/p;/^-- all counters, run --/,$p' /tmp/pg-$FS.log
	;;
*)
	die "usage: $0 <xfs|ext4> pgsim|torn|pg"
	;;
esac
