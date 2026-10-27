#!/bin/bash
# thp-verify.sh -- XFS tau with THP on, second half (host/thp-test.sh): after
# the power cut, mount (recovery replays the journal) and hold every file to
# what was fsynced.  t's odd pages above 32 MiB were left dirty before its
# activation; the activation wrote them back, the record's flush made them
# durable.
cd ~/tautest/guest || exit 1
. ./common.sh
THP=$TAU_BIN/tauthp
REF=/var/tmp/tauthp
NR=16

export TAU_MOUNT_OPTS=tjournal
[ -e "$REF/q" ] || die "no reference survived"
mount_tau xfs
echo "-- recovery --"
echo "  files replayed: $(sudo dmesg | grep -ac 'TAU: replay done')"
echo "-- verifying --"
bad=0
sudo "$THP" verify "$TAU_MNT/p" 64 1 1 1 1 64 || bad=1
sudo "$THP" verify "$TAU_MNT/t" 64 2 2 1 3 32 || bad=1
for i in $(seq 1 $NR); do
	sudo "$THP" verify "$TAU_MNT/r$i" 16 $((10 + i)) 2 1 1 16 || bad=1
done
if [ "$(md5_of_file "$TAU_MNT/q")" = "$(md5_of_file "$REF/q")" ]; then
	echo "  q: same as the reference"
else
	echo "  q: DIFFERS from the reference"; bad=1
fi
n=$(kernel_faults); w=$(sudo dmesg | grep -c 'WARNING:')
echo "== kernel faults: $n, warnings: $w =="
[ "$n" -eq 0 ] || show_kernel_faults
sudo umount "$TAU_MNT"
if [ $bad -ne 0 ]; then echo "RESULT: FAIL -- a file does not hold what was fsynced"; exit 1; fi
if [ "$n" -ne 0 ] || [ "$w" -ne 0 ]; then echo "RESULT: FAIL -- the kernel faulted"; exit 3; fi
echo "RESULT: PASS"
