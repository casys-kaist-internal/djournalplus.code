#!/bin/bash
# Flush order (taudocs/plan.md §10): every crash state a volatile write cache
# can leave, rebuilt from a dm-log-writes log and recovered (guest/flushorder.sh).
#   usage: flushorder-test.sh [xfs|ext4|both] [cases, comma list] [fsyncs]
# cases: append falloc subappend overwrite cpappend cpsub fsoverwrite fscpover
# reuse unlink truncate (default: all; fs* sync with fsync(2), the rest with
# fdatasync).
# CONTROL=0 skips the control runs (records FUA without PREFLUSH, and the segment
# map FUA without PREFLUSH: overwrite must FAIL in both; a freed segment reused
# while the disk map still names it: reuse must FAIL; an unlinked file's segments
# given back before the host has the unlink: unlink must FAIL; a truncate's revoke
# tags unconditional, or its txs not held for the host: truncate must FAIL; a
# record without a flush that keeps the allocation epoch, or recovery that takes
# the tail of a record its gate refuses: cpsub must FAIL; a refused orphan
# commit that still sets a floor: reuse must FAIL; an fsync(2) commit that
# leaves the inode out: fsoverwrite must FAIL).
# Loop devices on the guest's /dev/shm: no real disk is written.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
CASES=${2:-append,falloc,subappend,overwrite,cpappend,cpsub,fsoverwrite,fscpover,reuse,unlink,truncate}
N=${3:-24}
[ "$FSLIST" = both ] && FSLIST="xfs ext4"
CASES=${CASES//,/ }
MOD=$TAUFS_KERNEL/drivers/md/dm-log-writes.ko
[ -f "$MOD" ] || { echo "no $MOD: make drivers/md/dm-log-writes.ko in the kernel tree" >&2; exit 2; }
export VM_MEM=${VM_MEM:-16G}

vm_boot_tested || exit 1
vm_sync_tests || exit 1
vm_scp "$MOD" "$SSH_HOST:~/tautest/" || exit 1

rc=0
summary=""
for fs in $FSLIST; do
	for c in $CASES; do
		echo; echo "############ $fs $c ############"
		out=$(vm_ssh "~/tautest/guest/flushorder.sh $fs $c $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: PASS"*) summary+="$fs $c: PASS\n" ;;
		*) summary+="$fs $c: FAIL\n"; rc=1 ;;
		esac
	done
done
if [ "${CONTROL:-1}" = 1 ]; then
	for fs in $FSLIST; do
		echo; echo "############ $fs control: records FUA without PREFLUSH ############"
		out=$(vm_ssh "RECORD_FUA_ONLY=1 ~/tautest/guest/flushorder.sh $fs overwrite $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: FAIL"*) summary+="$fs control (FUA-only records, overwrite): FAIL, as it must\n" ;;
		*) summary+="$fs control: did not fail -- the test cannot see a missing flush\n"; rc=1 ;;
		esac
		echo; echo "############ $fs control: segment map FUA without PREFLUSH ############"
		out=$(vm_ssh "SEGMAP_FUA_ONLY=1 ~/tautest/guest/flushorder.sh $fs overwrite $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: FAIL"*) summary+="$fs control (FUA-only segment map, overwrite): FAIL, as it must\n" ;;
		*) summary+="$fs segment map control: did not fail -- the unmount is not covered\n"; rc=1 ;;
		esac
		echo; echo "############ $fs control: segment reused before the map stops naming it ############"
		out=$(vm_ssh "REUSE_FLUSH_ONLY=1 ~/tautest/guest/flushorder.sh $fs reuse $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: FAIL"*) summary+="$fs control (reuse without the map write): FAIL, as it must\n" ;;
		*) summary+="$fs reuse control: did not fail -- the reuse case does not see it\n"; rc=1 ;;
		esac
		echo; echo "############ $fs control: dead file's segments back before the host has the unlink ############"
		out=$(vm_ssh "DEAD_NOGATE=1 ~/tautest/guest/flushorder.sh $fs unlink $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: FAIL"*) summary+="$fs control (dead segments back at once, unlink): FAIL, as it must\n" ;;
		*) summary+="$fs unlink control: did not fail -- the unlink case does not see the gate\n"; rc=1 ;;
		esac
		for knob in FREE_UNCOND FREE_NOHOLD; do
			echo; echo "############ $fs control: truncate with $knob ############"
			out=$(vm_ssh "$knob=1 ~/tautest/guest/flushorder.sh $fs truncate $N" 2>&1)
			echo "$out"
			case "$out" in
			*"RESULT: FAIL"*) summary+="$fs control ($knob, truncate): FAIL, as it must\n" ;;
			*) summary+="$fs truncate control $knob: did not fail -- the truncate case does not see it\n"; rc=1 ;;
			esac
		done
		for knob in NOFLUSH_OLD_EPOCH GATE_TAIL; do
			echo; echo "############ $fs control: cpsub with $knob ############"
			out=$(vm_ssh "$knob=1 ~/tautest/guest/flushorder.sh $fs cpsub $N" 2>&1)
			echo "$out"
			case "$out" in
			*"RESULT: FAIL"*) summary+="$fs control ($knob, cpsub): FAIL, as it must\n" ;;
			*) summary+="$fs cpsub control $knob: did not fail -- the cpsub case does not see it\n"; rc=1 ;;
			esac
		done
		echo; echo "############ $fs control: a refused orphan commit sets a floor ############"
		out=$(vm_ssh "GATE_FLOOR=1 ~/tautest/guest/flushorder.sh $fs reuse $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: FAIL"*) summary+="$fs control (GATE_FLOOR, reuse): FAIL, as it must\n" ;;
		*) summary+="$fs reuse control GATE_FLOOR: did not fail -- the reuse case does not see it\n"; rc=1 ;;
		esac
		echo; echo "############ $fs control: fsync(2) without the inode ############"
		out=$(vm_ssh "FSYNC_NOINODE=1 ~/tautest/guest/flushorder.sh $fs fsoverwrite $N" 2>&1)
		echo "$out"
		case "$out" in
		*"RESULT: FAIL"*) summary+="$fs control (FSYNC_NOINODE, fsoverwrite): FAIL, as it must\n" ;;
		*) summary+="$fs fsoverwrite control FSYNC_NOINODE: did not fail -- the fsoverwrite case does not see it\n"; rc=1 ;;
		esac
	done
fi
vm_kill

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
