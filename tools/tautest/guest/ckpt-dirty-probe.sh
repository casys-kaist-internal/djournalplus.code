#!/bin/bash
# Measure the two unproven windows around the checkpoint's in-place flush
# (CLAUDE.md Known Bug #2). Needs a kernel built with the tau_probe_* counters.
#
#   tau_probe_flush_onwrite     window 2: tau_flush_batch locked a buffer that a
#                               writer had re-entered get_write_access on, i.e.
#                               tau is about to submit a buffer being copied into
#   tau_probe_ckpt_folio_dirty  window 1 precondition: checkpoint dirtied a
#                               tx-owned buffer whose folio was still tagged dirty
#   tau_probe_wb_taudirty       window 1 actual harm: generic writeback selected a
#                               block a tau tx owns
#
# The last one is the one that would mean real exposure. The first two are
# preconditions -- nonzero there means the window is open, not that it was taken.
#
#   usage: ckpt-dirty-probe.sh <xfs|ext4> [secs] [racers] [bigwriters]
#
# WARNING: runs mkfs on $TAU_DEV.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-ext4}
SECS=${2:-60}
RACERS=${3:-6}
BIGW=${4:-2}
P=/sys/module/tau_journal/parameters
COUNTERS="tau_probe_wb_taudirty tau_probe_flush_onwrite tau_probe_ckpt_folio_dirty"

check_tools
for c in $COUNTERS; do
	[ -f "$P/$c" ] || die "no $P/$c -- kernel lacks the probe patch"
done

echo "== mkfs/mount $FS =="
mkfs_mount "$FS"
sudo dmesg -C

# Zero them here, not at boot: mount itself does journal work we don't want to
# attribute to the workload.
for c in $COUNTERS; do echo 0 | sudo tee "$P/$c" >/dev/null; done

D=$TAU_MNT
echo "== workload: ${SECS}s, $RACERS racers + $BIGW big writers =="
pids=""
for r in $(seq 1 "$RACERS"); do
	sudo "$TAURACE" "$D/y$r" $((1 * MB)) "$SECS" >/dev/null 2>&1 & pids="$pids $!"
done
# Big writers exist to force checkpoints: the flush we are probing only runs
# when the journal is under enough pressure to reclaim segments.
for w in $(seq 1 "$BIGW"); do
	( while :; do
		sudo rm -f "$D/big$w"
		sudo "$TAUWRITE" "$D/big$w" $((512 * MB)) $w >/dev/null 2>&1 || break
	  done ) & pids="$pids $!"
	bgpids="${bgpids:-} $!"
done

for p in $pids; do
	case " ${bgpids:-} " in *" $p "*) continue ;; esac
	wait "$p" 2>/dev/null
done
for p in ${bgpids:-}; do kill "$p" 2>/dev/null; done
sleep 2
sudo pkill -f "$TAUWRITE" 2>/dev/null
wait 2>/dev/null

echo
echo "== counters after workload =="
for c in $COUNTERS; do printf '  %-28s %s\n' "$c" "$(cat "$P/$c")"; done

echo "== unmount (drains the checkpoint list) =="
sudo umount "$TAU_MNT" || echo "  (umount failed)"

echo
echo "== counters after unmount =="
for c in $COUNTERS; do printf '  %-28s %s\n' "$c" "$(cat "$P/$c")"; done

echo
wb=$(cat "$P/tau_probe_wb_taudirty")
fo=$(cat "$P/tau_probe_flush_onwrite")
echo "== verdict =="
if [ "$wb" != "0" ]; then
	echo "  EXPOSED: generic writeback selected $wb tx-owned block(s) -- window 1 is real"
elif [ "$fo" != "0" ]; then
	echo "  window 1 closed (writeback never saw a tx-owned block), but window 2 is"
	echo "  open: $fo submit(s) raced a writer mid-copy. Whether that tears anything"
	echo "  depends on replay covering it -- not settled by this run."
else
	echo "  neither window was entered in this run ($SECS s, $FS)."
fi
[ "$(kernel_faults)" = "0" ] || { echo "  NOTE: kernel complained"; show_kernel_faults; }
