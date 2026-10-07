#!/bin/bash
# Steady-state torn-write hunt, driven from the host.
#
#   boot -> lay out -> churn -> clean umount/remount -> verify
#
# There is deliberately no power cut: the bug this chases (CLAUDE.md, OPEN entry
# of 2026-08-25) lost a 4 KiB block while the machine kept running, which is
# exactly why the crash-recovery tests never saw it.
#
#   usage: torn-test.sh [xfs|ext4|both] [rounds] [secs]
#
# Knobs (environment): MODE (churn|grow), TAU_JOURNAL_GB, TORN_FILES,
# TORN_FILE_MB, TORN_THREADS, PAGE_KB, FSYNC_EVERY, HOT_PCT, CHUNK_PAGES,
# PREALLOC, VM_MEM, NVME_PCIE_ADDR.
#
# WARNING: runs mkfs on $TAU_DEV inside the guest. Everything on the passed
# -through NVMe is destroyed. NVME_PCIE_ADDR selects which one.

set -u
cd "$(dirname "$0")" || exit 1

# A small guest is the point, not an accident: the working set has to exceed
# RAM or clean folios are never reclaimed and the loss cannot show.
export VM_MEM=${VM_MEM:-8G}
export NVME_PCIE_ADDR=${NVME_PCIE_ADDR:-86:00.0}	# PM173x, the test device

. ./vm.sh

FSLIST=${1:-ext4}
ROUNDS=${2:-1}
SECS=${3:-300}
case "$FSLIST" in
both) FSLIST="ext4 xfs" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [rounds] [secs]" >&2; exit 2 ;;
esac

echo "passthrough NVMe: $NVME_PCIE_ADDR   guest RAM: $VM_MEM"
echo "(everything on that device will be destroyed)"

rc=0
inconclusive=0

vm_boot_tested || exit 1
vm_sync_tests || exit 1

for round in $(seq 1 "$ROUNDS"); do
	for fs in $FSLIST; do
		echo
		echo "############ $fs  round $round/$ROUNDS ############"

		# Deadline, not wait: a wedged guest ignores SIGKILL, and a host
		# that blocks on it gets no diagnosis at all (see CLAUDE.md).
		# Generous -- verify has to read the whole working set back.
		vm_ssh_timeout $((SECS + 1800)) \
			"TAU_JOURNAL_GB='${TAU_JOURNAL_GB:-1}' \
			PAGE_KB='${PAGE_KB:-8}' \
			FSYNC_EVERY='${FSYNC_EVERY:-16}' \
			HOT_PCT='${HOT_PCT:-60}' \
			PREALLOC='${PREALLOC:-fallocate}' \
			MODE='${MODE:-churn}' \
			CHUNK_PAGES='${CHUNK_PAGES:-256}' \
			~/tautest/guest/torn-write.sh $fs $SECS \
			${TORN_FILES:-8} ${TORN_FILE_MB:-1024} ${TORN_THREADS:-4}"
		case $? in
		0)	echo "RESULT[$fs r$round]: PASS" ;;
		2)	echo "RESULT[$fs r$round]: INCONCLUSIVE (see note above)"
			inconclusive=1 ;;
		3)	echo "RESULT[$fs r$round]: FAIL (kernel fault; data intact)"
			vm_console_faults
			rc=1 ;;
		124)	echo "RESULT[$fs r$round]: TIMEOUT -- guest never finished"
			vm_console_faults
			rc=1 ;;
		*)	echo "RESULT[$fs r$round]: FAIL"
			vm_console_faults
			rc=1 ;;
		esac

		# The guest can wedge rather than fail; get a known-good VM back
		# before the next round instead of chaining onto a sick one.
		vm_is_up || { vm_boot || { echo "VM did not come back" >&2; exit 1; }; }
	done
done

echo
if [ $rc -ne 0 ]; then
	echo "FAILURES (console log: $VM_LOG)"
	exit 1
fi
if [ $inconclusive -ne 0 ]; then
	echo "NO LOSS SEEN, but at least one round never put the journal under"
	echo "pressure -- that round tested nothing. Raise TORN_FILES/TORN_FILE_MB"
	echo "or lower TAU_JOURNAL_GB."
	exit 2
fi
echo "ALL PASS"
