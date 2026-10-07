#!/bin/bash
# Steady-state torn-write hunt: no power cut anywhere in this script.
#
# The bug being chased (CLAUDE.md, OPEN entry of 2026-08-25) dropped one 4 KiB
# block of an 8 KiB write while the machine kept running, so every other test
# here is structurally blind to it -- they all verify after a crash.  This one
# writes, unmounts cleanly, remounts, and demands the data back.  A clean
# unmount flushes everything, so *any* difference is a real loss.
#
# It reproduces the conditions the failure actually needed, not just the shape
# of the workload:
#
#   - files laid out with fallocate(), like PG's mdzeroextend(), so writes land
#     on unwritten extents that read as zeroes when lost
#   - a journal small enough that it stays near full and tau_journald is
#     checkpointing and reclaiming segments continuously (the bare-metal
#     failure sat at 80% of 32 GB for twenty minutes)
#   - a working set well over guest RAM, so clean folios really do get reclaimed
#
# If the journal never fills, a clean run proves nothing -- the script says so
# rather than reporting a pass.
#
# MODE picks which half of the picture is under test:
#   churn  lay the files out first, then only ever rewrite them.  Every write
#          lands on a written extent -- the steady state of a loaded database.
#   grow   extend with fallocate() and fill while rewriting what is already
#          there, so commit-time allocation (unwritten -> written) keeps running
#          for the whole test.  This is what the load phase looks like, and the
#          corrupted page was on a fallocate-backed extent.
#
#   usage: torn-write.sh <xfs|ext4> [secs] [files] [file_mb] [threads]
#
# WARNING: runs mkfs on $TAU_DEV (default /dev/nvme0n1). Destroys it.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-ext4}
SECS=${2:-300}
FILES=${3:-8}
FILE_MB=${4:-1024}
THREADS=${5:-4}

# Journal small enough to stay under pressure for the whole run.
TAU_JOURNAL_GB=${TAU_JOURNAL_GB:-1}
PAGE_KB=${PAGE_KB:-8}
FSYNC_EVERY=${FSYNC_EVERY:-16}
HOT_PCT=${HOT_PCT:-60}
PREALLOC=${PREALLOC:-fallocate}
MODE=${MODE:-churn}
CHUNK_PAGES=${CHUNK_PAGES:-256}
case "$MODE" in churn|grow) ;; *) die "MODE must be churn or grow" ;; esac

TAUTORN=$TAU_BIN/tautorn
# Off the filesystem under test on purpose: a manifest stored on $TAU_MNT would
# be subject to the very bug it is meant to adjudicate.
MANIFEST_DIR=${MANIFEST_DIR:-/var/tmp/tautorn}
P=/sys/module/tau_journal/parameters
COUNTERS="tau_probe_revoke_taken tau_probe_revoke_dirty_skip \
	  tau_probe_revoke_notag tau_probe_ckpt_raw_dirty \
	  tau_probe_flush_unmapped tau_probe_flush_onwrite \
	  tau_probe_flush_onwrite_rev tau_probe_cpdrop_infer \
	  tau_probe_cpdrop_orphan"

[ -x "$TAUTORN" ] || die "missing $TAUTORN (build with tools/tautest/Makefile)"

PAGES=$(( FILE_MB * 1024 / PAGE_KB ))
[ "$PAGES" -gt 0 ] || die "file_mb $FILE_MB / page_kb $PAGE_KB gives no pages"

have_probes=1
for c in $COUNTERS; do
	[ -f "$P/$c" ] || have_probes=0
done
[ "$have_probes" = 1 ] ||
	echo "note: kernel has no tau_probe_* counters; running without them"

read_counters() {
	local c
	for c in $COUNTERS; do
		printf '  %-28s %s\n' "$c" "$(cat "$P/$c" 2>/dev/null || echo -)"
	done
}

echo "== $FS/$MODE: $FILES files x ${FILE_MB}MB ($PAGES pages of ${PAGE_KB}K), \
${THREADS} threads each, ${SECS}s, journal ${TAU_JOURNAL_GB}GB =="

case "$FS" in
ext4)	TAU_MOUNT_OPTS="tjournal,tjournal_size=$TAU_JOURNAL_GB" ;;
xfs)	TAU_MOUNT_OPTS="tjournal,tjournal_size=$TAU_JOURNAL_GB" ;;
*)	die "unknown fs '$FS'" ;;
esac
export TAU_MOUNT_OPTS

sudo rm -rf "$MANIFEST_DIR"
sudo mkdir -p "$MANIFEST_DIR" || die "cannot create $MANIFEST_DIR"
mkfs_mount "$FS"
sudo dmesg -C

if [ "$have_probes" = 1 ]; then
	for c in $COUNTERS; do echo 0 | sudo tee "$P/$c" >/dev/null; done
fi

if [ "$MODE" = churn ]; then
	echo "-- laying out $FILES files with $PREALLOC --"
	pids=""
	for i in $(seq 1 "$FILES"); do
		sudo "$TAUTORN" init "$TAU_MNT/t$i" "$PAGES" "$i" \
			"$PAGE_KB" "$PREALLOC" &
		pids="$pids $!"
	done
	for p in $pids; do wait "$p" || die "init failed"; done
	sync
fi

echo "-- ${MODE}ing ${SECS}s --"
pids=""
for i in $(seq 1 "$FILES"); do
	if [ "$MODE" = churn ]; then
		sudo "$TAUTORN" churn "$TAU_MNT/t$i" "$PAGES" "$i" "$SECS" \
			$((1000 + i)) "$THREADS" "$PAGE_KB" "$FSYNC_EVERY" \
			"$HOT_PCT" "$MANIFEST_DIR/t$i.gen" &
	else
		sudo "$TAUTORN" grow "$TAU_MNT/t$i" "$PAGES" "$i" "$SECS" \
			$((1000 + i)) "$THREADS" "$PAGE_KB" "$FSYNC_EVERY" \
			"$CHUNK_PAGES" "$MANIFEST_DIR/t$i.gen" &
	fi
	pids="$pids $!"
done

# Sample the journal while the workload runs: a run where it never filled has
# not tested the path this is aimed at, and must not be reported as a pass.
# Poll rather than wait(1) on the workers -- a wedged guest ignores SIGKILL, so
# nothing here may block on them without a deadline of its own.
peak=0
alive=1
while [ "$alive" = 1 ]; do
	alive=0
	for p in $pids; do
		kill -0 "$p" 2>/dev/null && alive=1
	done
	used=$(sudo dmesg | grep -a 'Tau_Daemon: Used journal' | tail -1 |
	       sed -n 's/.*Used journal \([0-9]*\)MB.*/\1/p')
	[ -n "$used" ] && [ "$used" -gt "$peak" ] && peak=$used
	[ "$alive" = 1 ] && sleep 5
done
rc=0
for p in $pids; do wait "$p" || rc=1; done
[ $rc -eq 0 ] || echo "WARNING: a churn process failed"

echo "-- unmount (clean; no crash) and remount --"
sudo umount "$TAU_MNT" || die "umount failed"
mount_tau "$FS"

echo "-- verifying --"
dataloss=0
for i in $(seq 1 "$FILES"); do
	sudo "$TAUTORN" verify "$TAU_MNT/t$i" "$PAGES" "$i" "$PAGE_KB" \
		"$MANIFEST_DIR/t$i.gen" || dataloss=1
done

echo
echo "-- probe counters --"
[ "$have_probes" = 1 ] && read_counters || echo "  (none)"

cap_mb=$((TAU_JOURNAL_GB * 1024))
pct=$((peak * 100 / cap_mb))
echo
echo "-- journal pressure: peak ${peak}MB of ${cap_mb}MB (${pct}%) --"

# Kept apart from the data verdict on purpose.  This test pins the journal at
# 100% deliberately, and a writer waiting on segment reclaim then trips the
# hung-task detector -- which says the pressure worked, not that anything was
# lost.  Reporting the two together made a clean run print "data was lost".
stalls=$(sudo dmesg | grep -ac 'blocked for more than' || true)
faults=$(sudo dmesg | grep -icE 'kernel BUG|invalid opcode|soft lockup' || true)
kfail=0
if [ "$stalls" != 0 ]; then
	echo "-- $stalls writer stall warning(s) (>122s waiting on the journal) --"
	sudo dmesg | grep -a 'blocked for more than' | head -3
fi
if [ "$faults" != 0 ]; then
	echo "kernel complained $faults time(s):"
	show_kernel_faults
	kfail=1
fi

sudo umount "$TAU_MNT" 2>/dev/null

if [ "$dataloss" != 0 ]; then
	echo "RESULT: FAIL -- data was lost with no crash involved"
	exit 1
fi
if [ "$kfail" != 0 ]; then
	echo "RESULT: FAIL -- data verified intact, but the kernel faulted"
	exit 3
fi
if [ "$pct" -lt 50 ]; then
	echo "RESULT: INCONCLUSIVE -- journal peaked at ${pct}%, the checkpoint and"
	echo "        reclaim paths this targets were never under pressure."
	echo "        Raise files/file_mb or lower TAU_JOURNAL_GB and run again."
	exit 2
fi
echo "RESULT: PASS (journal held at ${pct}%, no loss)${stalls:+, $stalls writer stalls}"
exit 0
