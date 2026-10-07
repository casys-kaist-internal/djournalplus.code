#!/bin/bash
# Drive the PostgreSQL torn-write reproduction from the host.
#
# This is the workload that actually produced the 2026-08-25 corruption, at a
# scale chosen by its dataset:RAM ratio rather than absolute size (see
# guest/pg-torn.sh).  There is no power cut: the cluster is shut down cleanly
# and every relation page is scanned after a remount.
#
#   usage: pg-torn-test.sh [rounds] [secs]
#
# Knobs: PG_TABLES, PG_ROWS, TAU_JOURNAL_GB, LOAD_JOURNAL_GB, THREADS,
#        SHARED_BUFFERS, FPW, LOAD_ONLY, DATA_CHECKSUMS, FS (ext4|xfs),
#        VM_MEM, NVME_PCIE_ADDR.
#
# WARNING: runs mkfs on $TAU_DEV inside the guest. The passed-through NVMe is
# destroyed; NVME_PCIE_ADDR selects which one.

set -u
cd "$(dirname "$0")" || exit 1

# Small on purpose: the dataset has to exceed RAM or the page cache absorbs
# everything and the writeback paths under test never run.
export VM_MEM=${VM_MEM:-8G}
export NVME_PCIE_ADDR=${NVME_PCIE_ADDR:-86:00.0}	# PM173x, the test device

. ./vm.sh

ROUNDS=${1:-1}
SECS=${2:-1800}

echo "passthrough NVMe: $NVME_PCIE_ADDR   guest RAM: $VM_MEM"
echo "(everything on that device will be destroyed)"

rc=0
inconclusive=0

vm_boot_tested || exit 1
vm_sync_tests || exit 1

for round in $(seq 1 "$ROUNDS"); do
	echo
	echo "############ ${FS:-ext4}-tau postgres  round $round/$ROUNDS ############"

	# Deadline, not wait: loading plus the run plus a full-cluster scan, and
	# a wedged guest would otherwise hang the host alongside it.
	vm_ssh_timeout $((SECS + 5400)) \
		"TAU_JOURNAL_GB='${TAU_JOURNAL_GB:-32}' \
		 LOAD_JOURNAL_GB='${LOAD_JOURNAL_GB:-32}' \
		 THREADS='${THREADS:-32}' \
		 SHARED_BUFFERS='${SHARED_BUFFERS:-128MB}' \
		 FPW='${FPW:-off}' \
		 LOAD_ONLY='${LOAD_ONLY:-0}' \
		 DATA_CHECKSUMS='${DATA_CHECKSUMS:-on}' \
		 FS='${FS:-ext4}' \
		 ~/tautest/guest/pg-torn.sh $SECS ${PG_TABLES:-16} ${PG_ROWS:-2600000}"
	case $? in
	0)	echo "RESULT[r$round]: PASS" ;;
	2)	echo "RESULT[r$round]: INCONCLUSIVE (see note above)"
		inconclusive=1 ;;
	124)	echo "RESULT[r$round]: TIMEOUT -- guest never finished"
		vm_console_faults
		rc=1 ;;
	*)	echo "RESULT[r$round]: FAIL"
		vm_console_faults
		rc=1 ;;
	esac

	vm_is_up || { vm_boot || { echo "VM did not come back" >&2; exit 1; }; }
done

echo
if [ $rc -ne 0 ]; then
	echo "FAILURES (console log: $VM_LOG)"
	exit 1
fi
if [ $inconclusive -ne 0 ]; then
	echo "NO TORN PAGE SEEN, but at least one round never loaded the journal"
	echo "the way the failing run did. Raise PG_ROWS or the run time."
	exit 2
fi
echo "ALL PASS"
