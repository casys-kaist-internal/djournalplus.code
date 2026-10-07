#!/bin/bash
# Stale transactions in a reused segment (bug #25).  Run by
# host/seg-reuse-test.sh.   usage: seg-reuse.sh <fs> write|verify
#
# 4 MiB segments, handed out lowest entry first:
#   E0: 50 small txs (X = 0xaa) | B1 (0x11) ->E1
#   E1: B1 tail | B2 (0x22) ->E2;  all checkpointed, E0/E1 freed
#   E2: X rewritten (0xcc), checkpointed | B3 (Y = 0x77, fsync'd) ->E0 prefix
#   G takes E1, overwriting B1's tail.  Power cut.
# E0 still holds the old small txs behind B3's spill-over.  Recovery must replay
# B3 and nothing older: X stays 0xcc and Y is 0x77.
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; F=$TAU_MNT/seg-reuse; G=$TAU_MNT/other; K=4096
P=/sys/module/tau_journal/parameters
probe() { cat $P/tau_probe_$1; }
X=0; B=$((1<<20)); C=$((8<<20)); Y=$((16<<20))
wait_drained() {	# every segment free but the running one
	local i
	for i in $(seq 60); do
		[ $(probe seg_free) -ge $(( $(probe seg_total) - 1 )) ] && return 0
		sleep 1
	done
	die "checkpoint did not drain ($1): seg_free=$(probe seg_free) seg_total=$(probe seg_total)"
}
if [ "$2" = write ]; then
	echo 1 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"
	sudo dmesg | grep -i 'segment size' | tail -1
	for i in $(seq 0 49); do
		sudo "$TAUWRITE" "$F" $((2*K)) $((0xaa)) $((X + i*2*K)) >/dev/null || die small
	done
	sudo "$TAUWRITE" "$F" $((1024*K)) $((0x11)) $B >/dev/null || die B1
	sudo "$TAUWRITE" "$F" $((1024*K)) $((0x22)) $C >/dev/null || die B2
	wait_drained B2
	sudo "$TAUWRITE" "$F" $((100*K)) $((0xcc)) $X >/dev/null || die X
	sleep 3; wait_drained X
	echo 600 | sudo tee $P/tau_max_transaction_age >/dev/null
	sudo "$TAUWRITE" "$F" $((750*K)) $((0x77)) $Y >/dev/null || die B3
	sudo "$TAUWRITE" "$G" $((16*K)) $((0x55)) 0 >/dev/null || die G
	echo "seg_free=$(probe seg_free) seg_total=$(probe seg_total)"
	echo WRITTEN
else
	mount_tau "$FS"
	sudo dmesg | grep -E 'TAU: (found valid descriptor|replay done|ino [0-9]+: replaying|no more segment|.*tail)' | sed 's/^/  /'
	sudo python3 - "$F" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read(); K = 4096; M = 1 << 20
def h(a, n): return {hex(k): v for k, v in collections.Counter(d[a:a+n]).items()}
want = [("X", 0, 100*K, 0xcc), ("B", M, 1024*K, 0x11), ("C", 8*M, 1024*K, 0x22), ("Y", 16*M, 750*K, 0x77)]
ok = True
for name, off, n, v in want:
    got = h(off, n)
    good = got == {hex(v): n}
    ok &= good
    print("  %s %s %s" % (name, "ok " if good else "BAD", got))
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
	rc=$?
	sudo umount "$TAU_MNT"
	exit $rc
fi
