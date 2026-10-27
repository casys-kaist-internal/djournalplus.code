#!/bin/bash
# migrate-crash-write.sh [secs] [files] [file_mb] [threads]
# B, first half: the same workload under compaction, run to its end -- the
# churn's last act is an fsync, then the manifest of every page's generation.
# The file system is left mounted for the power cut, so what the journal holds
# is replayed and must match the manifest.
cd ~/tautest/guest || exit 1
. ./common.sh
SECS=${1:-180}; FILES=${2:-8}; FILE_MB=${3:-1024}; THREADS=${4:-4}
PAGE_KB=8; FSYNC_EVERY=16; HOT_PCT=60
TAUTORN=$TAU_BIN/tautorn
MANIFEST_DIR=/var/tmp/tautorn-mig
PAGES=$(( FILE_MB * 1024 / PAGE_KB ))
vm() { grep -E "^(pgmigrate_success|pgmigrate_fail|compact_isolated) " /proc/vmstat | tr '\n' ' '; }

export TAU_MOUNT_OPTS="tjournal,tjournal_size=1"
sudo rm -rf "$MANIFEST_DIR"; sudo mkdir -p "$MANIFEST_DIR" || die "manifest dir"
mkfs_mount xfs
sudo dmesg -C
sudo bash ./migrate-probes.sh on || die "cannot set the kprobes"

echo "-- laying out $FILES files x ${FILE_MB}MB --"
pids=""
for i in $(seq 1 "$FILES"); do
	sudo "$TAUTORN" init "$TAU_MNT/t$i" "$PAGES" "$i" "$PAGE_KB" fallocate &
	pids="$pids $!"
done
for p in $pids; do wait "$p" || die "init failed"; done
sync

sudo rm -f /tmp/mig.stop
echo "vmstat before: $(vm)"
sudo bash -c 'while [ ! -e /tmp/mig.stop ]; do echo 1 > /proc/sys/vm/compact_memory; sleep 0.2; done' &
cpid=$!
echo "-- churning ${SECS}s under compaction --"
pids=""
for i in $(seq 1 "$FILES"); do
	sudo "$TAUTORN" churn "$TAU_MNT/t$i" "$PAGES" "$i" "$SECS" $((1000 + i)) \
		"$THREADS" "$PAGE_KB" "$FSYNC_EVERY" "$HOT_PCT" "$MANIFEST_DIR/t$i.gen" &
	pids="$pids $!"
done
alive=1
while [ "$alive" = 1 ]; do
	alive=0
	for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
	[ "$alive" = 1 ] && sleep 5
done
rc=0
for p in $pids; do wait "$p" || rc=1; done
sudo touch /tmp/mig.stop; wait $cpid
[ $rc -eq 0 ] || die "a churn process failed"
sudo sync -f "$MANIFEST_DIR"		# the manifests, on the guest's own disk
echo "vmstat after:  $(vm)"
echo "-- migrate hook --"
sudo bash ./migrate-probes.sh report
echo "kernel faults so far: $(kernel_faults)"
echo "READY-FOR-CRASH"
