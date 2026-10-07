#!/bin/bash
# Reachability probe for the tau/XFS commit-time allocation path (see
# xfs-hold-stress.sh).  This workload used to wedge the whole filesystem in
# ~25s: the ordering bracket pinned CIL commit iclogs and then waited for a CIL
# push that needed the space those pins denied.  The bracket is gone -- publish
# now runs after the tau record is durable, so nothing pins the log -- and this
# probe both checks the wedge is gone and measures that the path still runs:
#
#   xfs_log_tau_epoch            a commit took a host watermark (CIL force)
#   xfs_tau_publish              unwritten->written conversion ran
#   xfs_iomap_write_unwritten    which takes XFS transactions
#   xlog_grant_head_wait         and those actually WAIT for log space
#
# The last one is the interesting one.  Under the old design that wait, taken
# while holding pins, was the cycle; now it is just an ordinary log wait, so
# hitting it and still finishing is exactly what the fix predicts.
#
#   usage: xfs-hold-probe.sh [secs] [racers] [bigwriters] [churners] [logsize] [logbufs]
#
# WARNING: runs mkfs on $TAU_DEV.

cd "$(dirname "$0")" || exit 1
. ./common.sh

SECS=${1:-20}
RACERS=${2:-8}
BIGW=${3:-3}
CHURNERS=${4:-4}
LOGSIZE=${5:-64m}	# mkfs refuses anything smaller on a device this size
LOGBUFS=${6:-2}		# fewer iclogs -> a hold pins a larger fraction of them

check_tools
T=/sys/kernel/tracing
FUNCS="xfs_log_tau_epoch xfs_tau_publish xfs_bmapi_convert_delalloc xfs_iomap_write_unwritten xlog_grant_head_wait"

echo "== mkfs xfs (log=$LOGSIZE, logbufs=$LOGBUFS) =="
sudo umount "$TAU_MNT" 2>/dev/null || true
[ -x "$MKFS_XFS" ] || die "missing patched mkfs.xfs at $MKFS_XFS"
sudo "$MKFS_XFS" -f ${TAU_MKFS_XFS_OPTS:-} -l "size=$LOGSIZE" "$TAU_DEV" >/dev/null ||
	die "mkfs.xfs -l size=$LOGSIZE failed"
sudo mkdir -p "$TAU_MNT"
sudo mount -t xfs -o "tjournal,logbufs=$LOGBUFS" "$TAU_DEV" "$TAU_MNT" ||
	die "mount failed"

# NB: trace_stat/ is root-only, so every glob over it must expand *inside* sudo
# (a bare "sudo cat dir/*" expands in the caller's shell, finds nothing, and
# silently reports zero for everything).
echo "== arming ftrace profiler =="
sudo sh -c "echo 0 > $T/function_profile_enabled"
sudo sh -c "echo > $T/set_ftrace_filter"
for f in $FUNCS; do sudo sh -c "echo $f >> $T/set_ftrace_filter"; done
sudo sh -c "echo 1 > $T/function_profile_enabled" || die "cannot enable function profiler"

D=$TAU_MNT
sudo dmesg -C

# Metadata churn burns log space.  No per-file fsync on purpose: we want log
# VOLUME (the CIL pushes on its own once it fills), and fsync would throttle
# the churner to the disk instead of letting it run the head toward the tail.
churn() {
	sudo mkdir -p "$1"
	sudo python3 - "$1" "$2" <<-'EOF'
		import os, sys, time
		d, secs = sys.argv[1], float(sys.argv[2])
		end, i = time.time() + secs, 0
		while time.time() < end:
		    names = []
		    for k in range(2000):
		        p = os.path.join(d, "m%d_%d" % (i, k))
		        fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o644)
		        os.write(fd, b"x" * 64)
		        os.close(fd)
		        names.append(p)
		        if time.time() > end:
		            break
		    for p in names:
		        os.unlink(p)
		    i += 1
	EOF
}

echo "== workload: ${SECS}s, $RACERS racers + $BIGW big writers + $CHURNERS churners =="
pids=""
for r in $(seq 1 "$RACERS"); do
	sudo "$TAURACE" "$D/y$r" $((1 * MB)) "$SECS" >/dev/null 2>&1 & pids="$pids $!"
done
for w in $(seq 1 "$BIGW"); do
	( sudo "$TAUWRITE" "$D/big$w" $((512 * MB)) $w >/dev/null 2>&1 ) & pids="$pids $!"
done
for c in $(seq 1 "$CHURNERS"); do
	( churn "$D/churn$c" "$SECS" >/dev/null 2>&1 ) & pids="$pids $!"
done
wait $pids 2>/dev/null

sudo sh -c "echo 0 > $T/function_profile_enabled"

echo
echo "== call counts (summed over cpus) =="
for f in $FUNCS; do
	n=$(sudo sh -c "cat $T/trace_stat/function*" 2>/dev/null |
		awk -v f="$f" '$1 == f { s += $2 } END { print s + 0 }')
	printf '  %-30s %s\n' "$f" "$n"
done

echo
echo "== verdict =="
waits=$(sudo sh -c "cat $T/trace_stat/function*" 2>/dev/null |
	awk '$1 == "xlog_grant_head_wait" { s += $2 } END { print s + 0 }')
pub=$(sudo sh -c "cat $T/trace_stat/function*" 2>/dev/null |
	awk '$1 == "xfs_tau_publish" { s += $2 } END { print s + 0 }')
if [ "$pub" = "0" ]; then
	echo "  publish never ran: the bracket is not exercised at all -- fix the workload"
elif [ "$waits" = "0" ]; then
	echo "  publish ran ($pub) but the log never made anyone wait for grant space."
	echo "  The cycle cannot close in this regime; squeeze the log harder."
else
	echo "  publish ran ($pub) AND grant waits happened ($waits): the deadlock"
	echo "  regime is reachable. Worth running xfs-hold-stress.sh."
fi

sudo umount "$TAU_MNT" 2>/dev/null || echo "  (note: umount failed)"
sudo sh -c "echo > $T/set_ftrace_filter"
