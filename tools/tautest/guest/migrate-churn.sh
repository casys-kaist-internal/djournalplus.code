#!/bin/bash
# migrate-churn.sh [rounds]: an XFS tau file's folios through compaction, then
# rewritten.  Each round: remount (nothing cached), read the file through an
# O_TAU_UNTORN fd (folios with no slot), compact, rewrite every block with the
# round's byte, remount, check the data.
cd ~/tautest/guest || exit 1
. ./common.sh
R=${1:-5}
SZ=$((256 * MB))
F=$TAU_MNT/mig

# tauio read <path> | write <path> <size> <byte>: through an O_TAU_UNTORN fd
tauio() {
	sudo python3 - "$@" <<-'PY'
		import os, sys
		O_TAU_UNTORN = 0o40000000
		op, path = sys.argv[1], sys.argv[2]
		if op == 'read':
		    fd = os.open(path, os.O_RDONLY | O_TAU_UNTORN)
		    while os.read(fd, 1 << 20):
		        pass
		else:
		    size, byte = int(sys.argv[3]), int(sys.argv[4])
		    fd = os.open(path, os.O_WRONLY | os.O_CREAT | O_TAU_UNTORN, 0o644)
		    buf = bytes([byte]) * (1 << 20)
		    for _ in range(size >> 20):
		        os.write(fd, buf)
		    os.fsync(fd)
		os.close(fd)
	PY
}

mkfs_mount xfs
tauio write $F $SZ 255 || die "first write"
sudo dmesg -C
rc=0
m0=$(awk '/^pgmigrate_success/{print $2}' /proc/vmstat)
for r in $(seq 1 $R); do
	sudo umount $TAU_MNT; mount_tau xfs
	tauio read $F || die "read $r"
	for k in 1 2 3; do sudo sh -c 'echo 1 > /proc/sys/vm/compact_memory'; done
	m=$(awk '/^pgmigrate_success/{print $2}' /proc/vmstat)
	tauio write $F $SZ $r || die "rewrite $r"
	sudo umount $TAU_MNT; mount_tau xfs
	expect_md5 "round$r" $F "$(md5_of_repeat $r $SZ)" || rc=1
	echo "round $r: pages migrated so far $((m - m0)), kernel faults $(kernel_faults)"
done
sudo umount $TAU_MNT
n=$(kernel_faults)
echo "== kernel faults: $n =="
[ "$n" -eq 0 ] || { show_kernel_faults; rc=1; }
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
