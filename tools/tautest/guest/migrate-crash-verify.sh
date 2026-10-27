#!/bin/bash
# migrate-crash-verify.sh [files] [file_mb]
# B, second half, after the power cut: mount (recovery replays the journal) and
# hold every page to the manifest written after the last fsync.
cd ~/tautest/guest || exit 1
. ./common.sh
FILES=${1:-8}; FILE_MB=${2:-1024}
PAGE_KB=8
TAUTORN=$TAU_BIN/tautorn
MANIFEST_DIR=/var/tmp/tautorn-mig
PAGES=$(( FILE_MB * 1024 / PAGE_KB ))

export TAU_MOUNT_OPTS="tjournal,tjournal_size=1"
ls "$MANIFEST_DIR"/t1.gen >/dev/null 2>&1 || die "no manifest survived"
mount_tau xfs
echo "-- recovery --"
echo "  files replayed: $(sudo dmesg | grep -ac 'TAU: replay done')"
sudo dmesg | grep -a "TAU: replay done" | sed -n 's/.*replayed \([0-9]*\) blocks, revoked \([0-9]*\) blocks.*/\1 \2/p' |
	awk '{a+=$1; b+=$2} END {print "  blocks replayed: " a+0 ", revoked: " b+0}'
echo "-- verifying against the manifests --"
loss=0
for i in $(seq 1 "$FILES"); do
	sudo "$TAUTORN" verify "$TAU_MNT/t$i" "$PAGES" "$i" "$PAGE_KB" \
		"$MANIFEST_DIR/t$i.gen" || loss=1
done
n=$(kernel_faults)
echo "== kernel faults: $n =="
[ "$n" -eq 0 ] || show_kernel_faults
sudo umount "$TAU_MNT"
if [ $loss -ne 0 ]; then echo "RESULT: FAIL -- a page does not hold its fsynced generation"; exit 1; fi
if [ "$n" -ne 0 ]; then echo "RESULT: FAIL -- the kernel faulted"; exit 3; fi
echo "RESULT: PASS"
