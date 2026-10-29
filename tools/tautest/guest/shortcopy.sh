#!/bin/bash
# A write whose source faults partway leaves the rest of the block alone (#24);
# one that faults before its first byte does not let the fsync after it skip a
# commit in flight (efault, #69).
# Layout: README.  usage: shortcopy.sh <xfs|ext4> write|verify|efault|efault-verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; MODE=$2
A=$TAU_MNT/a
OFF=$((8 * 4096)); HEAD=100
P=/sys/module/tau_journal/parameters
ST=$HOME/shortcopy-status

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

if [ "$MODE" = efault ]; then
	[ -r "$P/tau_inject_delay" ] ||
		die "no tau_inject_delay: efault needs CONFIG_TAU_PROBE_TORN=y"
	rm -f "$ST"
	mkfs_mount "$FS"
	echo 8000 | sudo tee "$P/tau_inject_delay_ms" >/dev/null
	sudo dmesg -C
	echo $((1 << 2)) | sudo tee "$P/tau_inject_delay" >/dev/null	# TAU_DELAY_MAPPED
	# 64 KiB of 0xA5, no fsync: its background commit sleeps after pass 1
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY | 0o40000000, 0o644)
os.write(fd, b"\xa5" * (64 << 10))
os.close(fd)' "$A" || die "tau write"
	for i in $(seq 1 150); do
		sudo dmesg | grep -q "injected delay at site 2," && break
		sleep 0.2
	done
	if ! sudo dmesg | grep -q "injected delay at site 2,"; then
		echo 0 | sudo tee "$P/tau_inject_delay" >/dev/null
		die "no background commit reached the delay in 30 s"
	fi
	# from a PROT_NONE page: EFAULT before the first byte, nothing journaled
	sudo python3 - "$A" <<-'EOF' || die "efault write"
		import ctypes, errno, os, sys, time
		libc = ctypes.CDLL(None, use_errno=True)
		libc.mmap.restype = ctypes.c_void_p
		libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
		                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
		libc.pwrite.restype = ctypes.c_ssize_t
		libc.pwrite.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_long]
		buf = libc.mmap(None, 4096, 0, 0x22, -1, 0)	# PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS
		fd = os.open(sys.argv[1], os.O_WRONLY | 0o40000000)
		n = libc.pwrite(fd, buf, 4096, 64 << 10)
		e = ctypes.get_errno()
		if n != -1 or e != errno.EFAULT:
		    sys.exit("pwrite from a PROT_NONE page: %d, errno %d" % (n, e))
		t = time.monotonic()
		os.fdatasync(fd)
		print("  fdatasync after the EFAULT write: %d ms" % ((time.monotonic() - t) * 1000))
	EOF
	# the commit leaves its delay before it finishes
	if sudo dmesg | grep -q "injected delay at site 2 done"; then
		echo WAITED > "$ST"
	else
		echo EARLY > "$ST"
		echo "  the fdatasync returned while the commit was in its delay"
	fi
	sync "$ST"
	echo WRITTEN
elif [ "$MODE" = efault-verify ]; then
	st=$(cat "$ST" 2>/dev/null)
	mount_tau "$FS"
	sudo python3 - "$A" <<-'EOF'
		import sys
		try:
		    d = open(sys.argv[1], 'rb').read()
		except FileNotFoundError:
		    print("  recovered: FAIL (no file)"); sys.exit(1)
		if d == b'\xa5' * (64 << 10):
		    print("  recovered: PASS"); sys.exit(0)
		print("  recovered: FAIL (size %d, %d bytes of 0xa5)" % (len(d), d.count(0xa5)))
		sys.exit(1)
	EOF
	rc=$?
	if [ "$st" = WAITED ]; then
		echo "  runtime: PASS (the fdatasync waited for the commit in flight)"
	else
		echo "  runtime: FAIL (${st:-no status}: the fdatasync returned before the commit in flight)"
		rc=1
	fi
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	sudo umount "$TAU_MNT" || rc=1
	exit $rc
elif [ "$MODE" = write ]; then
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
