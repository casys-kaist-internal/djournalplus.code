#!/bin/bash
# Arm the checkpoint in-place-flush window and hold it open until the host
# pulls the plug. See src/taucprace.c for what state is being built and why.
#
# The point is to have, at crash time:
#   - a revoke for these blocks already committed (from generation B), and
#   - generation C sitting in a transaction that has not committed, whose
#     buffers the checkpoint daemon may be flushing to their home blocks.
#
#   usage: cp-race-write.sh <xfs|ext4> [size-mb] [hold-seconds]

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
SIZE_MB=${2:-8}
HOLD=${3:-40}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> [size-mb] [hold-seconds]"
[ -x "$TAU_BIN/taucprace" ] || die "missing $TAU_BIN/taucprace"

# Kernel probes are pr_warn/pr_info; systemd lowers the console loglevel
# after boot so they never reach the serial log - and the serial log is the
# only one that survives the power cut. Raise it before doing anything.
sudo dmesg -n 8

echo "== preparing $FS on $TAU_DEV =="
mkfs_mount "$FS"

D=$TAU_MNT

echo "== arming =="
MARKER=${MARKER:-$HOME/cprace-armed}
rm -f "$MARKER"
sudo "$TAU_BIN/taucprace" "$D/cprace" $((SIZE_MB * MB)) "$HOLD" "$MARKER" &
ARMED=$!

# Do not add pressure until the three generations are down, or the pressure
# writes win the journal and the target never reaches the state we want.
for _ in $(seq 1 120); do [ -f "$MARKER" ] && break; sleep 0.5; done
[ -f "$MARKER" ] || die "taucprace never armed"

# Journal pressure: this is what makes tau_do_checkpoint() reclaim, which is
# the only thing that flushes a still-uncommitted transaction's buffers to
# their home blocks.
echo "== checkpoint pressure =="
(
	for i in $(seq 1 100000); do
		sudo "$TAUWRITE" "$D/p$((i % 4))" $((64 * MB)) $((i % 200)) >/dev/null 2>&1
	done
) &
PRESSURE=$!
trap 'kill $PRESSURE 2>/dev/null' EXIT

echo "== armed, holding =="
wait $ARMED
echo "== hold expired (host did not crash us in time) =="
