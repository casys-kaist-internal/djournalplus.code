#!/bin/bash
# Journal segments a crashed mount left mapped past a hole are taken by the
# next mount, so a full filesystem gets its margin back while mounted (#37).
# Layout: README.  usage: seg-adopt.sh xfs arm|check
cd ~/tautest/guest || exit 1
. ./common.sh
FS=${1:-xfs}; MODE=$2
J=$TAU_MNT/tjournal_dummy
SEG=$((128 * MB))
export TAU_FS_SIZE=${TAU_FS_SIZE:-16g}
export TAU_MKFS_XFS_OPTS=${TAU_MKFS_XFS_OPTS:--l tjmaxsize=2g}

[ "$FS" = xfs ] || die "xfs only: the journal file is reachable without -o tjournal there"

logforce() {
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x")
os.fsync(fd)
os.close(fd)' "$TAU_MNT/logforce" || die "log force"
}

# MiB the journal file holds
jmib() { sudo du --block-size=1M "$J" | awk '{print $1}'; }

if [ "$MODE" = arm ]; then
	mkfs_mount xfs
	sudo dmesg | grep -E "TAU: .*segment" | tail -3 | sed 's/^/  /'
	logforce
	echo WRITTEN
	exit 0
fi

sudo mount -t xfs "$TAU_DEV" "$TAU_MNT" || die "plain mount"
before=$(jmib)
echo "== the crashed mount left $before MiB in the journal file =="
[ "$before" -ge $((10 * 128)) ] || { echo "INCONCLUSIVE: journal file holds only $before MiB"; exit 3; }
# a hole at segment 8: the first eight come back without the FS margin check
sudo fallocate -p -o $((8 * SEG)) -l $SEG "$J" || die "punch"
avail=$(df --output=avail -B1 "$TAU_MNT" | tail -1)
sudo fallocate -l $(( (avail - 1024 * MB) / MB * MB )) "$TAU_MNT/filler" || die "filler"
f0=$(df --output=avail -B1M "$TAU_MNT" | tail -1)
echo "== hole at segment 8, $(jmib) MiB left, $f0 MiB free =="
sudo umount "$TAU_MNT" || die "umount"

mount_tau xfs
sleep 5		# journald gives free segments back inside the FS margin
a1=$(df --output=avail -B1M "$TAU_MNT" | tail -1)
sudo dmesg | grep -E "TAU: took|TAU: .*journal segment" | tail -2 | sed 's/^/  /'
echo "== tjournal mount: $a1 MiB free after 5 s =="
sudo umount "$TAU_MNT" || die "tjournal umount"
if [ $((a1 - f0)) -gt 1024 ]; then
	echo "RESULT: PASS (the segments past the hole came back to the filesystem)"
	rc=0
else
	echo "RESULT: FAIL (segments past the hole stay dead while mounted)"
	rc=1
fi
[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
exit $rc
