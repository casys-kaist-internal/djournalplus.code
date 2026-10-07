#!/bin/bash
# Segment release order (bug #17): a drained transaction must not free a middle
# segment an older transaction's chain still runs through.  Run by
# host/seg-order-test.sh.   usage: seg-order.sh <fs> write|verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; F=$TAU_MNT/seg-order; G=$TAU_MNT/other; MB=$((1<<20))
P=/sys/module/tau_journal/parameters
probe() { cat $P/tau_probe_$1; }
fsync_only() { sudo python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_RDWR|0o40000000); os.fsync(fd); os.close(fd)' "$1"; }
if [ "$2" = write ]; then
	echo 600 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"
	sudo dmesg | grep -i 'segment size' | tail -1
	sudo "$TAUWRITE" "$F" $((4*MB)) $((0x11)) 0 >/dev/null || die T1
	sudo "$TAUWRITE" "$F" $((12*MB)) $((0x22)) $((8*MB)) >/dev/null || die T2
	d0=$(probe tx_dropped)
	sudo "$TAUWRITE_NOFSYNC" "$F" $((12*MB)) $((0x33)) $((8*MB)) >/dev/null || die undo
	fsync_only "$F" || die F
	sudo "$TAUWRITE" "$F" $((12*MB)) $((0x44)) $((8*MB)) >/dev/null || die T3
	echo "tx_dropped +$(( $(probe tx_dropped) - d0 )) during undo/F/T3"
	sudo "$TAUWRITE" "$G" $((8*MB)) $((0x55)) 0 >/dev/null || die other
	echo WRITTEN
else
	mount_tau "$FS"
	sudo dmesg | grep -E 'TAU: (replay done|no more segment|scan done)' | sed 's/^/  /'
	sudo python3 - "$F" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read(); M = 1 << 20
def h(a, b): return dict(collections.Counter(d[a:b]))
r1, r2 = h(0, 4*M), h(8*M, 20*M)
ok = r1 == {0x11: 4*M} and r2 == {0x44: 12*M}
print("  R1", {hex(k): v for k, v in r1.items()}, " R2", {hex(k): v for k, v in r2.items()})
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
	rc=$?
	sudo umount "$TAU_MNT"
	exit $rc
fi
