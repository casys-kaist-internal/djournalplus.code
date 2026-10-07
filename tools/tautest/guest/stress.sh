#!/bin/bash
# Concurrency stress: hunt for asserts and hangs in the write-during-commit
# paths. No crash involved — this looks for kernel BUGs, not data loss.
#
# Several taurace processes hammer separate files while large writes keep the
# checkpoint daemon busy. Each round is checked against dmesg; the run stops at
# the first kernel complaint.
#
# The bugs this found took anywhere from 30 seconds to ~30 minutes to show up,
# so give it time before calling a tree clean.
#
#   usage: stress.sh <xfs|ext4> [rounds] [racers] [seconds-per-round]

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
ROUNDS=${2:-200}
RACERS=${3:-6}
SECS=${4:-5}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> [rounds] [racers] [seconds]"
check_tools

echo "== preparing $FS =="
mkfs_mount "$FS"
sudo dmesg -C

# Lower the hung-task threshold so a stuck task is reported instead of just
# sitting there. Blocked-task stacks land in dmesg / the serial console.
sudo sysctl -w kernel.hung_task_timeout_secs=60 >/dev/null 2>&1 || true

D=$TAU_MNT

echo "== background pressure =="
(
	for i in $(seq 1 100000); do
		sudo "$TAUWRITE" "$D/p$((i % 6))" $((100 * MB)) $((i % 200)) >/dev/null 2>&1
	done
) &
PRESSURE=$!
trap 'kill $PRESSURE 2>/dev/null' EXIT

echo "== $ROUNDS rounds x $RACERS racers ($SECS s each) =="
for round in $(seq 1 "$ROUNDS"); do
	pids=""
	for r in $(seq 1 "$RACERS"); do
		(
			timeout 60 sudo "$TAURACE" "$D/y$r" $((1 * MB)) "$SECS" >/dev/null 2>&1
			echo $? > "/tmp/taurace.rc.$r"
		) &
		pids="$pids $!"
	done
	# Wait for the racers only — a bare `wait` would also wait for the
	# background pressure loop, which never finishes on its own.
	wait $pids

	for r in $(seq 1 "$RACERS"); do
		rc=$(cat "/tmp/taurace.rc.$r" 2>/dev/null)
		if [ "$rc" != "0" ]; then
			echo "round $round: racer $r exited $rc (timeout means it hung)"
			echo w | sudo tee /proc/sysrq-trigger >/dev/null	# dump blocked tasks
			sleep 3
			show_kernel_faults
			echo "RESULT: FAIL (hang)"
			exit 1
		fi
	done

	if [ "$(kernel_faults)" != "0" ]; then
		echo "round $round: kernel complained"
		show_kernel_faults
		echo "RESULT: FAIL (kernel fault)"
		exit 1
	fi

	printf 'round %d/%d ok\n' "$round" "$ROUNDS"
done

echo "RESULT: PASS ($ROUNDS rounds, no kernel faults)"
