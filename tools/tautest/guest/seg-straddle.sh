#!/bin/bash
# The newest tx straddles two segments and is checkpointed (bug #27).  Run by
# host/seg-straddle-test.sh.   usage: seg-straddle.sh <fs> write|verify
#
# A file rewritten in a loop cycles its journal between two segments, so the
# one it gets back still holds its own older txs -- same inode, same mount.
# Settle rewrites until one commit enters a new segment (seg_published), then
# let it checkpoint: its first segment is freed and another file's commit
# takes it off the disk map, while the second -- [its tail and commit][older
# txs of the same file] -- stays.  Recovery must replay nothing older than the
# commit: the file stays all 0x2a.
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; F=$TAU_MNT/straddle; G=$TAU_MNT/other; SIZE=${SIZE:-$((1<<20))}
P=/sys/module/tau_journal/parameters
probe() { cat $P/tau_probe_$1; }
if [ "$2" = write ]; then
	echo 1 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"
	sudo dmesg | grep -i 'segment size' | tail -1
	for i in $(seq ${ROUNDS:-300}); do
		sudo "$TAURACE" "$F" $SIZE 1 >/dev/null || die taurace
		c=$(probe seg_published)
		sudo "$TAURACE" "$F" $SIZE settle >/dev/null || die settle
		[ "$(probe seg_published)" -gt "$c" ] && break
	done
	[ "$(probe seg_published)" -gt "$c" ] ||
		die "no settle entered a new segment in $i rounds"
	echo "round $i: the settle commit entered a new segment"
	sleep 5		# checkpointed and dropped: its first segment is freed
	sudo "$TAUWRITE" "$G" $((16*1024)) $((0x55)) 0 >/dev/null || die G
	echo WRITTEN
else
	mount_tau "$FS"
	ino=$(stat -c %i "$F")
	sudo dmesg | grep -E "TAU: .*ino $ino[: ]" | grep -v 'found revoke' | sed 's/^/  /'
	sudo python3 - "$F" <<'PY'
import sys, collections
d = open(sys.argv[1], 'rb').read()
bad = [i for i in range(len(d) // 4096) if d[i*4096:(i+1)*4096] != b'\x2a' * 4096]
print("  size %d, %d bad blocks" % (len(d), len(bad)))
for i in bad[:8]:
    print("    lblk %d %s" % (i, dict(collections.Counter(d[i*4096:(i+1)*4096]))))
sys.exit(1 if bad else 0)
PY
	rc=$?
	sudo umount "$TAU_MNT"
	if [ $rc != 0 ]; then
		echo "RESULT: FAIL"
	elif sudo dmesg | grep -q "TAU: ino $ino: orphan commit"; then
		echo "RESULT: PASS"
	else
		# the commit started a segment rather than straddling into it:
		# nothing was at stake
		echo "RESULT: INCONCLUSIVE (no orphan commit seen)"
	fi
	[ $rc = 0 ]
fi
