#!/bin/bash
# truncate / punch hole racing writes and fsync on one tau file.  Run by
# host/trunc-race-test.sh.   usage: trunc-race.sh <fs> [seconds]
#
# invalidate unfiles blocks from the running tx and gives back its credits;
# a commit starting at the same time reads those credits (locking.md F1, S3).
# Checks the kernel for BUG/WARNING; "taufreed" (truncate of a block its commit
# is writing, bug.md #8) is expected and counted apart.
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; SECS=${2:-60}; F=$TAU_MNT/trunc-race; K=4096; MB=$((1<<20))
mkfs_mount "$FS"
sudo dmesg -C
sudo "$TAUWRITE" "$F" $((16*MB)) 1 0 >/dev/null || die layout
end=$((SECONDS + SECS))
writer() { local i=0
	while [ $SECONDS -lt $end ]; do
		sudo "$TAUWRITE" "$F" $((16*K)) $((i % 200 + 2)) $(( (RANDOM % 1024) * 16 * K )) >/dev/null 2>&1
		i=$((i+1))
	done; }
puncher() {
	while [ $SECONDS -lt $end ]; do
		sudo fallocate -p -o $(( (RANDOM % 1024) * 16 * K )) -l $((16*K)) "$F" 2>/dev/null
		sudo truncate -s $(( (8 + RANDOM % 8) * MB )) "$F"
		sudo truncate -s $((16*MB)) "$F"
	done; }
syncer() {
	sudo python3 - "$F" "$SECS" <<'PY'
import os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
end = time.time() + float(sys.argv[2]); n = 0
while time.time() < end:
    os.fsync(fd); n += 1
print("fsyncs", n)
PY
}
writer & writer & puncher & syncer &
wait
sync
echo "writes/punches done"
bugs=$(sudo dmesg | grep -cE 'kernel BUG|invalid opcode|Oops|general protection')
warns=$(sudo dmesg | grep -cE 'WARNING:')
freed=$(sudo dmesg | grep -c 'WARNING:.* __tau_unmap_buffer')
down=$(sudo dmesg | grep -cE 'Shutting down filesystem|Tau-Journal .*aborting|Corruption of in-memory data')
bugs=$((bugs + down))
echo "kernel: BUG $bugs (fs shutdown / journal abort $down), WARNING $warns (taufreed $freed)"
sudo dmesg | grep -E 'kernel BUG|invalid opcode|Oops|WARNING:' | grep -v ' __tau_unmap_buffer' | head -12
sudo umount "$TAU_MNT" || bugs=$((bugs+1))
if [ "$bugs" = 0 ] && [ "$warns" = "$freed" ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; exit 1; fi
