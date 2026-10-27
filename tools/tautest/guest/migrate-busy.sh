#!/bin/bash
# migrate-busy.sh [secs] [files] [file_mb] [threads]
# A: the torn workload (8K rewrites + fsync on a 1 GB journal: commits and
# checkpoints all the time) while compaction keeps trying to move the files'
# folios.  A folio whose slot is in use must be refused, and after a clean
# unmount every block must hold its last generation.
cd ~/tautest/guest || exit 1
SECS=${1:-180}; FILES=${2:-8}; FILE_MB=${3:-1024}; THREADS=${4:-4}
vm() { grep -E "^(pgmigrate_success|pgmigrate_fail|compact_isolated) " /proc/vmstat | tr '\n' ' '; }

sudo bash ./migrate-probes.sh on || { echo "ERROR: cannot set the kprobes"; exit 1; }
sudo rm -f /tmp/mig.stop
echo "vmstat before: $(vm)"
sudo bash -c 'while [ ! -e /tmp/mig.stop ]; do echo 1 > /proc/sys/vm/compact_memory; sleep 0.2; done' &
cpid=$!
TAU_JOURNAL_GB=1 ./torn-write.sh xfs "$SECS" "$FILES" "$FILE_MB" "$THREADS"
rc=$?
sudo touch /tmp/mig.stop; wait $cpid
echo "vmstat after:  $(vm)"
echo "-- migrate hook --"
sudo bash ./migrate-probes.sh report
exit $rc
