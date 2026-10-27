#!/bin/bash
# Page migration of an XFS tau file's folios (plan.md §6.7).  README.
#   churn: folios with no slot are moved by compaction, then rewritten
#   busy:  compaction runs through a rewrite + fsync workload; a folio whose
#          slot is in use must be refused -- checked after a clean unmount (A)
#          and after a power cut taken right after the last fsync (B)
#   usage: migrate-test.sh [churn|busy] [rounds | secs]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1

CASE=${1:-churn}
case "$CASE" in
churn) ;;
busy)
	# the working set has to exceed RAM, as in torn-test.sh
	export VM_MEM=${VM_MEM:-8G}
	export NVME_PCIE_ADDR=${NVME_PCIE_ADDR:-86:00.0}	# PM173x, the test device
	;;
*) echo "usage: $0 [churn|busy] [rounds | secs]" >&2; exit 2 ;;
esac
. ./vm.sh

FAULTS='kernel BUG|invalid opcode|soft lockup|WARNING: CPU'
# console faults since line $1 of the console log
faults_since() { tail -n +$(($1 + 1)) "$VM_LOG" | grep -aE "$FAULTS"; }

vm_boot_tested || exit 1
vm_sync_tests || exit 1
start=$(wc -l < "$VM_LOG")

if [ "$CASE" = churn ]; then
	R=${2:-5}
	# a done marker and our own deadline: a wedged guest ignores SIGKILL
	vm_ssh "rm -f /tmp/mig.done; nohup sh -c 'bash ~/tautest/guest/migrate-churn.sh $R > /tmp/mig.log 2>&1; echo \$? > /tmp/mig.done' >/dev/null 2>&1 &"
	end=$((SECONDS + 1500))
	while [ $SECONDS -lt $end ]; do
		vm_ssh_timeout 15 'test -e /tmp/mig.done' && break
		faults_since "$start" | grep -aqE 'kernel BUG|invalid opcode' &&
			{ echo "guest BUG on the console"; sleep 5; break; }
		sleep 15
	done
	vm_ssh_timeout 30 'cat /tmp/mig.log'
	rc=$(vm_ssh_timeout 30 'cat /tmp/mig.done 2>/dev/null')
	n=$(faults_since "$start" | wc -l)
	echo "console faults in this boot: $n"
	[ "$n" -eq 0 ] || faults_since "$start" | head -5
	if [ "${rc:-1}" = 0 ] && [ "$n" -eq 0 ]; then
		echo "ALL PASS"
		exit 0
	fi
	echo "FAILURES (guest rc=${rc:-none}, console faults $n; console log: $VM_LOG)"
	exit 1
fi

SECS=${2:-180}
T=$(mktemp)

echo
echo "############ A: churn under compaction, clean unmount, verify ############"
vm_ssh_timeout $((SECS + 1800)) "bash ~/tautest/guest/migrate-busy.sh $SECS" | tee "$T"
a=${PIPESTATUS[0]}
ra=$(sed -n 's/.*MIG_REFUSED_BUSY=\([0-9]*\).*/\1/p' "$T" | tail -1)
echo "A: rc=$a, refused for a busy slot: ${ra:-?}"

echo
echo "############ B: churn under compaction, power cut after the last fsync, recover, verify ############"
vm_ssh_timeout $((SECS + 1800)) "bash ~/tautest/guest/migrate-crash-write.sh $SECS" | tee "$T"
w=${PIPESTATUS[0]}
rb=$(sed -n 's/.*MIG_REFUSED_BUSY=\([0-9]*\).*/\1/p' "$T" | tail -1)
rm -f "$T"
b=1
if [ "$w" -eq 0 ]; then
	echo "--- power cut ---"
	vm_crash
	echo "--- rebooting ---"
	if vm_boot; then
		vm_ssh_timeout 1800 "bash ~/tautest/guest/migrate-crash-verify.sh"
		b=$?
	else
		echo "VM did not come back"
	fi
else
	echo "B: the write half failed (rc=$w)"
fi
echo "B: rc=$b, refused for a busy slot: ${rb:-?}"

n=$(faults_since "$start" | wc -l)
echo "console faults in this test's boots: $n"
[ "$n" -eq 0 ] || faults_since "$start" | head -5

if [ "$b" -ne 0 ] || [ "$n" -ne 0 ] || { [ "$a" -ne 0 ] && [ "$a" -ne 2 ]; }; then
	echo "FAILURES (A rc=$a, B rc=$b, console faults $n; console log: $VM_LOG)"
	exit 1
fi
# a run that never refused a busy folio, or never filled the journal, tested nothing
if [ "$a" -eq 2 ] || [ "${ra:-0}" -eq 0 ] || [ "${rb:-0}" -eq 0 ]; then
	echo "RESULT: INCONCLUSIVE -- A rc=$a, busy refusals A=${ra:-0} B=${rb:-0}"
	exit 2
fi
echo "ALL PASS"
exit 0
