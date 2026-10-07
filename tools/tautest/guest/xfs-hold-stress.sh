#!/bin/bash
# XFS-only hunt for a deadlock in the tau commit ordering bracket.
#
# The claim under test (fs/xfs/xfs_log_cil.c, above xlog_cil_tau_hold_begin):
#   "Deadlock-free: the bracket never blocks on the log (tau only converts +
#    writes its own journal device)."
# But converting IS a log operation: tau_commit_publish() calls
# xfs_iomap_write_unwritten(), which loops on xfs_trans_alloc_inode(tr_write)
# (fs/xfs/xfs_iomap.c) and so can wait in xlog_grant_head_wait for grant space.
# Meanwhile the hold pins commit iclogs, which keeps their items out of the AIL
# and so keeps the log tail from moving. If the tail sits behind an iclog this
# hold pinned, the wait cannot be satisfied:
#
#   hold_begin -> pin commit iclog -> publish -> trans_alloc -> grant wait
#     -> needs tail to move -> needs AIL insert -> needs iclog IO completion
#     -> needs the pin dropped -> needs publish to finish.
#
# The xc_tau_pinned cap (l_iclog_bufs/2) bounds how many iclogs are pinned, not
# how much log space publish needs, so it does not break the cycle.
#
# What actually makes it reproduce (measured 2026-08-17):
#   - metadata churn alongside  -> fills the CIL, so pushes are large and frequent
#   - concurrent fsync racers   -> several holds open at once
#   - big delayed-alloc writers -> publish loops over many transactions per hold
# NOT needed: a small log.  mkfs refuses anything under 64MB on a device this size
# ("Log size must be at least 64MB"), and the cycle closes on iclog space well
# before the log's grant space runs low.  logbufs only tunes the pinned fraction;
# it wedges at the default 8 just as it does at 2.
#
#   usage: xfs-hold-stress.sh [rounds] [racers] [bigwriters] [secs] [logsize] [logbufs]
#
# WARNING: runs mkfs on $TAU_DEV.

cd "$(dirname "$0")" || exit 1
. ./common.sh

ROUNDS=${1:-20}
RACERS=${2:-8}
BIGW=${3:-2}
SECS=${4:-5}
LOGSIZE=${5:-64m}	# mkfs refuses smaller on this device; see header
LOGBUFS=${6:-8}		# the default -- it wedges here too
# A wedge leaves tasks in uninterruptible sleep, where SIGKILL does nothing, so
# `timeout` cannot rescue us and `wait` would never return. Poll instead.
DEADLINE=${DEADLINE:-120}
CHURNERS=${CHURNERS:-3}

check_tools

echo "== mkfs xfs (log size=$LOGSIZE, logbufs=$LOGBUFS) =="
sudo umount "$TAU_MNT" 2>/dev/null || true
[ -x "$MKFS_XFS" ] || die "missing patched mkfs.xfs at $MKFS_XFS"
# TAU_MKFS_XFS_OPTS carries the tau segment size, which is an on-disk parameter
# and must match the kernel's TAU_SEGMENT_SIZE (see common.sh).
sudo "$MKFS_XFS" -f ${TAU_MKFS_XFS_OPTS:-} -l "size=$LOGSIZE" "$TAU_DEV" >/dev/null ||
	die "mkfs.xfs -l size=$LOGSIZE failed"
sudo mkdir -p "$TAU_MNT"
sudo mount -t xfs -o "tjournal,logbufs=$LOGBUFS" "$TAU_DEV" "$TAU_MNT" ||
	die "mount failed (tjournal,logbufs=$LOGBUFS)"
xfs_info "$TAU_MNT" 2>/dev/null | grep -E '^log' || true

sudo dmesg -C
# Let the hung-task detector dump stacks on its own if we miss the window.
sudo sysctl -w kernel.hung_task_timeout_secs=30 >/dev/null 2>&1 || true

D=$TAU_MNT
RCDIR=/tmp/tauhold.rc
rm -rf "$RCDIR"; mkdir -p "$RCDIR"

# Everything we might want to know about a wedge, collected while it is wedged.
dump_wedge() {
	echo "--- D-state tasks ---"
	ps -eo pid,stat,wchan:32,comm | awk 'NR==1 || $2 ~ /D/'
	for p in $(ps -eo pid,stat | awk '$2 ~ /D/ {print $1}'); do
		echo "--- pid $p ($(cat "/proc/$p/comm" 2>/dev/null)) ---"
		sudo cat "/proc/$p/stack" 2>/dev/null
	done
	echo "--- sysrq task dump ---"
	echo w | sudo tee /proc/sysrq-trigger >/dev/null
	sleep 3
	sudo dmesg | tail -300
	echo "--- deadlock signature ---"
	# The cycle names itself: a grant wait underneath the publish pass, or
	# everyone else queued on the pin cap.
	sudo dmesg | grep -cE 'xlog_grant_head_wait|xfs_iomap_write_unwritten|xfs_log_tau_epoch|tau_commit_publish' |
		sed 's/^/  matching frames in dmesg: /'
}

# Metadata churn: keeps the log grant space genuinely scarce, which is what
# turns publish's reservation into a wait rather than an instant grant.
churn() {
	local dir=$1 secs=$2
	sudo mkdir -p "$dir"
	sudo python3 - "$dir" "$secs" <<-'EOF'
		import os, sys, time
		d, secs = sys.argv[1], float(sys.argv[2])
		end = time.time() + secs
		i = 0
		while time.time() < end:
		    names = []
		    for k in range(200):
		        p = os.path.join(d, "m%d_%d" % (i, k))
		        fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o644)
		        os.write(fd, b"x" * 64)
		        os.fsync(fd)
		        os.close(fd)
		        names.append(p)
		    for p in names:
		        os.unlink(p)
		    i += 1
	EOF
}

echo "== $ROUNDS rounds x $RACERS racers + $BIGW big writers + $CHURNERS churners ($SECS s) =="
for round in $(seq 1 "$ROUNDS"); do
	rm -f "$RCDIR"/*

	for r in $(seq 1 "$RACERS"); do
		( sudo "$TAURACE" "$D/y$r" $((1 * MB)) "$SECS" >/dev/null 2>&1
		  echo $? > "$RCDIR/racer$r" ) &
	done
	# Fresh files each round so every block is a delayed allocation that the
	# publish pass has to resolve inside the hold.
	for w in $(seq 1 "$BIGW"); do
		( sudo rm -f "$D/big$w"
		  sudo "$TAUWRITE" "$D/big$w" $((256 * MB)) $((round % 200)) >/dev/null 2>&1
		  echo $? > "$RCDIR/big$w" ) &
	done
	for c in $(seq 1 "$CHURNERS"); do
		( churn "$D/churn$c" "$SECS" >/dev/null 2>&1
		  echo $? > "$RCDIR/churn$c" ) &
	done

	want=$((RACERS + BIGW + CHURNERS))
	wedged=1
	for _ in $(seq 1 "$DEADLINE"); do
		[ "$(ls -1 "$RCDIR" 2>/dev/null | wc -l)" -ge "$want" ] && { wedged=0; break; }
		sleep 1
	done

	if [ "$wedged" -eq 1 ]; then
		echo "round $round: $(ls -1 "$RCDIR" | wc -l)/$want finished in ${DEADLINE}s -- wedged"
		dump_wedge
		echo "RESULT: FAIL (hang)"
		exit 1
	fi
	wait

	for f in "$RCDIR"/*; do
		rc=$(cat "$f" 2>/dev/null)
		[ "$rc" = "0" ] || { echo "round $round: $(basename "$f") exited $rc"; dump_wedge
			echo "RESULT: FAIL (worker error)"; exit 1; }
	done

	if [ "$(kernel_faults)" != "0" ]; then
		echo "round $round: kernel complained"
		show_kernel_faults
		dump_wedge
		echo "RESULT: FAIL (kernel fault)"
		exit 1
	fi
	# An abort does not wedge anything, but it means a commit was thrown away.
	# "no host-journal ordering" is the hold's own give-up path: not a deadlock,
	# but the same cycle relieving itself, so it is a hit worth stopping on.
	if sudo dmesg | grep -qiE 'TAU:.*(abort|no host-journal ordering)|Shutting down'; then
		echo "round $round: tau/XFS gave up on a commit"
		sudo dmesg | grep -iE 'TAU:|XFS' | tail -30
		echo "RESULT: FAIL (abort)"
		exit 1
	fi

	sudo rm -rf "$D"/churn* 2>/dev/null
	printf 'round %d/%d ok\n' "$round" "$ROUNDS"
done

echo "== unmount (checkpoint drain) =="
sudo umount "$TAU_MNT" || { echo "RESULT: FAIL (umount)"; dump_wedge; exit 1; }
echo "RESULT: PASS ($ROUNDS rounds, log=$LOGSIZE logbufs=$LOGBUFS)"
