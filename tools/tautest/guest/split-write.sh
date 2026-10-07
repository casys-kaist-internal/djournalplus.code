#!/bin/bash
# Set up one split case (README) and arm; writes ARMED or INCONCLUSIVE.
#   usage: split-write.sh <xfs|ext4> <split|split-ctl|extend|inplace> [hold-s]

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
CASE=${2:-}
HOLD=${3:-120}
STATUS_FILE=${STATUS_FILE:-$HOME/split-status}
P=/sys/module/tau_journal/parameters
F=$TAU_MNT/split

case "$CASE" in
split|split-ctl|extend|inplace) ;;
*) die "usage: $0 <xfs|ext4> <split|split-ctl|extend|inplace> [hold-seconds]" ;;
esac
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> <case> [hold-seconds]"
[ -r "$P/tau_probe_commits" ] ||
	die "no tau_probe_* counters: this test needs CONFIG_TAU_PROBE_TORN=y"

rm -f "$STATUS_FILE"
status() { echo "$*" > "$STATUS_FILE"; sync "$STATUS_FILE" 2>/dev/null; echo "== $* =="; }
inconclusive() { status "INCONCLUSIVE $*"; exit 0; }

# 0 for a counter this kernel lacks
probe() { cat "$P/tau_probe_$1" 2>/dev/null || echo 0; }
setparam() { echo "$2" | sudo tee "$P/$1" >/dev/null || die "cannot set $1"; }

WATCH="revoke_taken atoz_mixed commits jwrite_revoke tx_dropped"
declare -A SNAP
snap() { local c; for c in $WATCH; do SNAP[$c]=$(probe "$c"); done; }
delta() { echo $(( $(probe "$1") - ${SNAP[$1]} )); }
show() {
	local c line="  [$1]"
	for c in $WATCH; do line+=" $c+$(delta "$c")"; done
	echo "$line"
}

home_pblk() {
	sudo filefrag -b4096 -v "$F" | awk -v l="$1" '
		/^[[:space:]]*[0-9]+:/ {
			gsub(/\.\./, " "); gsub(/:/, " ");
			if (l >= $2 && l <= $3) { print $4 + (l - $2); found = 1; exit }
		}
		END { exit !found }'
}

# first byte of <lblk>'s home block, read off the device with O_DIRECT
inplace_byte() {
	local pblk
	pblk=$(home_pblk "$1") || { echo "??"; return; }
	sudo dd if="$TAU_DEV" bs=4096 skip="$pblk" count=1 iflag=direct 2>/dev/null |
		od -An -tx1 -N1 | tr -d ' \n'
}

fsync_only() {
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.fsync(fd)
os.close(fd)' "$F" || die "fsync failed"
}

# <size> <byte> [offset] plus 4 MiB filler: one tx over TAU_SMALL_TX, fsync'd
big_tx() {
	sudo "$TAUWRITE_NOFSYNC" "$F" $((4 * MB)) "$FILL" $((1 * MB)) >/dev/null ||
		die "filler write failed"
	FILL=$((FILL + 1))
	sudo "$TAUWRITE" "$F" "$1" "$2" "${3:-0}" >/dev/null || die "tauwrite failed"
}

# before the write under test; 1 with $WHY: retry
setup() {
	mkfs_mount "$FS"
	FILL=$((0x60))

	# fresh blocks come out TauUndo: allocate, let the checkpoint drop them
	setparam tau_max_transaction_age 1	# T0 checkpointed 1 s after commit
	snap
	echo "== T0: blocks 0-1 := 0x40, then checkpointed and dropped =="
	big_tx 8192 $((0x40))
	local w
	for w in $(seq 1 20); do
		sleep 1
		[ "$(delta tx_dropped)" -ge "$(delta commits)" ] &&
			[ "$(inplace_byte 0)$(inplace_byte 1)" = "4040" ] && break
	done
	show T0
	[ "$(delta tx_dropped)" -ge "$(delta commits)" ] ||
		{ WHY="T0 not dropped in 20 s"; return 1; }
	setparam tau_max_transaction_age 120	# T1 stays in the journal

	snap
	case "$CASE" in
	split*)
		echo "== T1: block 1 := 0x42 (block 0 stays clean) =="
		big_tx 4096 $((0x42)) 4096
		;;
	*)
		echo "== T1: blocks 0-1 := 0x41 =="
		big_tx 8192 $((0x41))
		;;
	esac
	show T1
	[ "$(delta revoke_taken)" -eq 0 ] ||
		{ WHY="T1 found a block not clean (revoke_taken+$(delta revoke_taken))"; return 1; }
	return 0
}

COMMIT_AGE=$(cat "$P/tau_max_commmit_age")
for attempt in 1 2 3; do
	echo "== preparing $FS, case $CASE, attempt $attempt =="
	WHY=""
	setup && break
	echo "  precondition failed: $WHY"
	[ "$attempt" -lt 3 ] || inconclusive "$WHY (3 attempts)"
done

snap
case "$CASE" in
extend)
	echo "== 12 KiB of 0x44, no fsync: blocks 0-1 TauRedo, block 2 a hole =="
	sudo "$TAUWRITE_NOFSYNC" "$F" 12288 $((0x44)) >/dev/null || die "write failed"
	;;
*)
	echo "== 8 KiB of 0x43, no fsync =="
	sudo "$TAUWRITE_NOFSYNC" "$F" 8192 $((0x43)) >/dev/null || die "write failed"
	;;
esac
show write
# the case happened
case "$CASE" in
split*)
	[ "$(delta revoke_taken)" -ge 1 ] || [ "$(delta atoz_mixed)" -ge 1 ] ||
		inconclusive "block 1 was not TauRedo at the write" ;;
extend)
	[ "$(delta revoke_taken)" -ge 2 ] || [ "$(delta atoz_mixed)" -ge 1 ] ||
		inconclusive "blocks 0-1 were not TauRedo at the write" ;;
inplace)
	[ "$(delta revoke_taken)" -ge 2 ] ||
		inconclusive "the write did not go in place (revoke_taken+$(delta revoke_taken))" ;;
esac

snap
if [ "$CASE" = split-ctl ]; then
	echo "== fsync =="
	fsync_only
	show fsync
else
	echo "== idle $((COMMIT_AGE + 2)) s: background commit, tags stay pending =="
	sleep $((COMMIT_AGE + 2))
	show idle
	[ "$(delta jwrite_revoke)" -eq 0 ] ||
		inconclusive "a revoke block was written while idle: nothing left to tear"
	if [ "$CASE" != inplace ] && [ "$(delta commits)" -lt 1 ]; then
		inconclusive "no background commit happened while idle"
	fi
	# host log force, or a new block reads as a hole after the crash
	echo "== fsync a plain file: the host log is forced =="
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x")
os.fsync(fd)
os.close(fd)' "$TAU_MNT/logforce" || die "log force failed"
	show logforce
	[ "$(delta jwrite_revoke)" -eq 0 ] ||
		inconclusive "a revoke block was written by the log force"
fi

status ARMED
sleep "$HOLD"
echo "== hold expired =="
