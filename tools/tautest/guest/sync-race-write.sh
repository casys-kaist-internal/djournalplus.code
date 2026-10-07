#!/bin/bash
# Aim sync(2) at the in-flight background commit window, then wait to be crashed.
#
#   usage: sync-race-write.sh <xfs|ext4> [delay-us]
#
# master->running_tau is decremented in __tau_start_commit() the moment a
# transaction stops being the running one -- before tau_commit_transaction()
# has written anything. So there is a window where nothing is "running" yet a
# commit is still in flight, and a sync(2) that trusts that counter walks
# straight past it.
#
# To land inside the window on purpose:
#   * tau_max_commmit_age = 0, so journald sweeps the finished transaction into
#     an async commit on its next pass (it polls every 10 ms),
#   * one big write, so the resulting commit takes long enough to still be
#     running when we call sync(2),
#   * a short sleep between the write and the sync, long enough for the daemon
#     to have started the commit and short enough that it has not finished.
#
# Only sync(2) is used, exactly once. Calling it in a loop would mask the bug:
# a second sync would commit what the first one skipped.
#
# r_fsync is the control, and it is the whole point of the layout. It gets the
# same size, the same commit age and the same delay -- only the barrier differs.
# If r_fsync also loses data then the failure is not about sync(2) at all, it is
# whatever the aggressive commit age is stirring up, and the sync result says
# nothing. It is written first so the later sync(2) cannot be what saves it.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> [delay-us]"
DELAY=${2:-50000}
SZ=${SZ:-$((256 * MB))}
SYNCBIN=${SYNCBIN:-$TAU_BIN/tausync}
[ -x "$SYNCBIN" ] || die "missing $SYNCBIN (build with tools/tautest/Makefile)"

AGE=/sys/module/tau_journal/parameters/tau_max_commmit_age

echo "== preparing $FS on $TAU_DEV =="
mkfs_mount "$FS"
sudo dmesg -C

# COMMIT_AGE=default keeps the built-in age, which tells you whether a failure
# needs the aggressive setting or shows up in a normal configuration too.
COMMIT_AGE=${COMMIT_AGE:-0}

if [ "$COMMIT_AGE" = default ]; then
	echo "   tau_max_commmit_age: left at $(sudo cat $AGE 2>/dev/null)"
elif sudo test -w "$AGE"; then
	echo "   tau_max_commmit_age: $(sudo cat $AGE) -> $COMMIT_AGE"
	sudo sh -c "echo $COMMIT_AGE > $AGE"
else
	echo "   WARNING: $AGE not writable; using the built-in commit age," \
	     "the race window will be much harder to hit"
fi

# ONLY=fsync or ONLY=sync writes just that one file. Use it to keep the exact
# single-file shape that reproduced the loss: adding a second big write shifts
# the timing enough that the window stops being hit at all.
ONLY=${ONLY:-both}

# Never crash on the strength of a write that did not happen. A silently
# failed (or empty) writer looks exactly like a durability bug afterwards.
written() {
	local got
	got=$(sudo stat -c %s "$1" 2>/dev/null) || die "$1 was not created"
	[ "$got" = "$SZ" ] || die "$1 is $got bytes, expected $SZ"
	echo "   $1: $got bytes on disk"
}

D=$TAU_MNT
if [ "$ONLY" != sync ]; then
	echo "== control: $((SZ / MB)) MB write, ${DELAY}us, fsync =="
	sudo "$SYNCBIN" "$D/r_fsync" "$SZ" 188 fsync "$DELAY" || die "fsync writer failed"
	written "$D/r_fsync"
fi
if [ "$ONLY" != fsync ]; then
	echo "== subject: $((SZ / MB)) MB write, ${DELAY}us, single sync(2) =="
	sudo "$SYNCBIN" "$D/r_sync" "$SZ" 199 sync "$DELAY" || die "sync writer failed"
	written "$D/r_sync"
fi

echo "== written, ready to crash =="
