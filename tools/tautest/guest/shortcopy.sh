#!/bin/bash
# A write whose source faults partway leaves the rest of the block alone (#24).
# Layout: README.  usage: shortcopy.sh <xfs|ext4> write|verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; MODE=$2
A=$TAU_MNT/a
OFF=$((8 * 4096)); HEAD=100

# 64 KiB of 0xC3, HEAD bytes of 0x5A at OFF
check() {
	sudo python3 - "$A" "$OFF" "$HEAD" "$1" <<-'EOF'
		import sys
		path, off, head, label = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
		d = open(path, 'rb').read()
		want = bytearray(b'\xc3' * (64 << 10))
		want[off:off + head] = b'\x5a' * head
		if d == bytes(want):
		    print("  %s: PASS" % label); sys.exit(0)
		bad = [i // 4096 for i in range(0, len(want), 4096) if d[i:i + 4096] != want[i:i + 4096]]
		blk = d[off:off + 4096]
		print("  %s: FAIL (size %d, bad blocks %s; block %d: head %s, rest %d of %d 0xc3, %d zero)" % (
		    label, len(d), bad, off // 4096, blk[:head] == b'\x5a' * head,
		    blk[head:].count(0xc3), 4096 - head, blk[head:].count(0)))
		sys.exit(1)
	EOF
}

if [ "$MODE" = write ]; then
	mkfs_mount "$FS"
	# not journaled yet, so its pages can leave the cache
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"\xc3" * (64 << 10))
os.fsync(fd)
os.close(fd)' "$A" || die "plain write"
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo "$TAU_BIN/taushort" "$A" $OFF $HEAD $((0x5a)) || die "taushort"
	sudo dmesg | grep "partial write" | tail -2 | sed 's/^/  /'
	check runtime || exit 1
	echo WRITTEN
else
	mount_tau "$FS"
	check recovered
	rc=$?
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	sudo umount "$TAU_MNT" || rc=1
	exit $rc
fi
