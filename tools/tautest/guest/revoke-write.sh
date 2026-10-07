#!/bin/bash
# Set up one revoke-tag case (see README) and arm; the host crashes the VM and
# revoke-verify.sh checks recovery.  Writes ARMED or INCONCLUSIVE to $STATUS_FILE.
#
#   gap        T1 + fsync -> rewrite block 0 -> idle until a background commit
#              takes running_tx -> fsync
#   stale      T1 + fsync -> rewrite block 0 -> T1 checkpointed -> rewrite the
#              range (block 0 journaled again) -> fsync
#   gap-ctl    gap without the idle
#   stale-ctl  stale with T1 kept alive
#
#   usage: revoke-write.sh <xfs|ext4> <gap|gap-ctl|stale|stale-ctl> [hold-s]

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}
CASE=${2:-}
HOLD=${3:-120}
STATUS_FILE=${STATUS_FILE:-$HOME/revoke-status}
P=/sys/module/tau_journal/parameters
SIZE=$((4 * MB))
F=$TAU_MNT/revoke

case "$CASE" in
gap|gap-ctl|stale|stale-ctl) ;;
*) die "usage: $0 <xfs|ext4> <gap|gap-ctl|stale|stale-ctl> [hold-seconds]" ;;
esac
[ -n "$FS" ] || die "usage: $0 <xfs|ext4> <case> [hold-seconds]"
[ -r "$P/tau_probe_commits" ] ||
	die "no tau_probe_* counters: this test needs CONFIG_TAU_PROBE_TORN=y"

rm -f "$STATUS_FILE"
status() { echo "$*" > "$STATUS_FILE"; sync "$STATUS_FILE" 2>/dev/null; echo "== $* =="; }
inconclusive() { status "INCONCLUSIVE $*"; exit 0; }

probe() { cat "$P/tau_probe_$1"; }
setparam() { echo "$2" | sudo tee "$P/$1" >/dev/null || die "cannot set $1"; }

# counters each step is judged by, printed as deltas
WATCH="revoke_taken commits jwrite_revoke jwrite_record tx_dropped cpdrop_cpdone"
declare -A SNAP
snap() { local c; for c in $WATCH; do SNAP[$c]=$(probe "$c"); done; }
delta() { echo $(( $(probe "$1") - ${SNAP[$1]} )); }
show() {
	local c line="  [$1]"
	for c in $WATCH; do line+=" $c+$(delta "$c")"; done
	echo "$line"
}

# home block of logical block <lblk>
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

# mkfs leaves the last case's data in place; safe while block 0 is TauRedo
zero_home() {
	local pblk
	pblk=$(home_pblk 0) || return 1
	sudo dd if=/dev/zero of="$TAU_DEV" bs=4096 seek="$pblk" count=1 \
		oflag=direct conv=notrunc 2>/dev/null
}

fsync_only() {
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.fsync(fd)
os.close(fd)' "$F" || die "fsync failed"
}

# Everything before the step under test.  A failed precondition returns 1 with
# the reason in $WHY; it is timing, so the caller retries.
setup() {
	mkfs_mount "$FS"
	case "$CASE" in
	stale) setparam tau_max_transaction_age 1 ;;	# T1 checkpointed 1 s after commit
	*)     setparam tau_max_transaction_age 120 ;;	# T1 outlives the whole test
	esac

	echo "== T1: 4 MiB of 0x41, fsync =="
	sudo "$TAUWRITE" "$F" "$SIZE" $((0x41)) >/dev/null || die "tauwrite T1 failed"
	zero_home || { WHY="cannot locate block 0"; return 1; }
	echo "  home block 0 zeroed as a baseline: 0x$(inplace_byte 0)"

	# while block 0 is still TauRedo (stale: within T1's 1 s)
	snap
	echo "== block 0 := 0x42, no fsync (TauRedo -> TauUndo, tag pending) =="
	sudo "$TAUWRITE_NOFSYNC" "$F" 4096 $((0x42)) 0 >/dev/null || die "rewrite failed"
	show rewrite
	[ "$(delta revoke_taken)" -ge 1 ] ||
		{ WHY="block 0 was not TauRedo at the rewrite (revoke_taken+0)"; return 1; }

	case "$CASE" in
	gap)
		snap
		echo "== idle $((COMMIT_AGE + 2)) s: background commit takes running_tx =="
		sleep $((COMMIT_AGE + 2))
		show idle
		[ "$(delta commits)" -ge 1 ] ||
			{ WHY="no background commit happened while idle"; return 1; }
		[ "$(delta jwrite_revoke)" -eq 0 ] ||
			{ WHY="a revoke block was written before the fsync"; return 1; }
		;;
	stale)
		snap
		echo "== wait 4 s: T1 checkpoint writes block 0 home and drops it =="
		sleep 4
		show checkpoint
		[ "$(delta tx_dropped)" -ge 1 ] ||
			{ WHY="T1 was not checkpointed (tx_dropped+0)"; return 1; }
		b=$(inplace_byte 0)
		echo "  home block 0 now: 0x$b"
		[ "$b" = "42" ] || { WHY="home block 0 is 0x$b, not 0x42"; return 1; }
		setparam tau_max_transaction_age 120	# the next tx must stay in the journal
		;;
	stale-ctl)
		snap
		sleep 4
		show wait
		# Not tx_dropped: the rewrite's own tag-only tx drops on commit too.
		b=$(inplace_byte 0)
		echo "  home block 0 now: 0x$b"
		[ "$b" = "00" ] ||
			{ WHY="T1's checkpoint wrote block 0 home anyway (0x$b)"; return 1; }
		;;
	esac
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
gap|gap-ctl)
	echo "== fsync =="
	fsync_only
	;;
stale|stale-ctl)
	echo "== 4 MiB of 0x43 over the same range, fsync =="
	sudo "$TAUWRITE" "$F" "$SIZE" $((0x43)) >/dev/null || die "tauwrite T3 failed"
	;;
esac
show fsync
echo "  home block 0 after fsync: 0x$(inplace_byte 0)"

status ARMED
sleep "$HOLD"
echo "== hold expired =="
