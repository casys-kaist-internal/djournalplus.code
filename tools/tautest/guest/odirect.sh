#!/bin/bash
# O_DIRECT on a tjournal mount: a plain file does real direct I/O, a tau file's
# direct I/O goes through tau (buffered), O_TAU_UNTORN|O_DIRECT is refused.
# And mmap: a tau file's shared mapping never becomes writable (#42).
# Layout: README.  usage: odirect.sh <xfs|ext4> write|verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; MODE=$2
A=$TAU_MNT/a
P=/sys/module/tau_journal/parameters
R=$((4 * MB))

probe() { cat $P/tau_probe_$1 2>/dev/null || echo 0; }

# <label> <byte>: A is R bytes of <byte>, read with O_DIRECT
check() {
	sudo python3 - "$A" "$2" "$1" <<-'EOF'
		import os, mmap, sys
		path, byte, label = sys.argv[1], int(sys.argv[2], 0), sys.argv[3]
		fd = os.open(path, os.O_RDONLY | os.O_DIRECT)
		buf = mmap.mmap(-1, 4 << 20)
		n = os.readv(fd, [buf])
		os.close(fd)
		ok = n == len(buf) and buf[:] == bytes([byte]) * len(buf)
		print("  %s: %s (%d bytes, first %#04x)" % (label, "PASS" if ok else "FAIL", n, buf[0]))
		sys.exit(0 if ok else 1)
	EOF
}

if [ "$MODE" = write ]; then
	mkfs_mount "$FS"
	rc=0
	echo "== a file tau does not journal: real O_DIRECT =="
	sudo dd if=/dev/zero of="$TAU_MNT/plain" bs=4k count=16 oflag=direct status=none &&
		echo "  plain: PASS" || { echo "  plain: FAIL (O_DIRECT write refused)"; rc=1; }
	echo "== O_TAU_UNTORN | O_DIRECT is refused =="
	sudo python3 -c 'import os, sys
try:
    os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY | os.O_DIRECT | 0o40000000, 0o644)
except OSError as e:
    print("  untorn+direct: PASS (%s)" % os.strerror(e.errno)); sys.exit(0)
print("  untorn+direct: FAIL (opened)"); sys.exit(1)' "$TAU_MNT/b" || rc=1

	echo "== tau file: O_DIRECT reads and writes go through tau =="
	sudo "$TAUWRITE" "$A" $R $((0x31)) >/dev/null || die "tauwrite"
	check "direct read after a tau write" 0x31 || rc=1
	c0=$(probe commits)
	sudo python3 - "$A" <<-'EOF' || die "direct write"
		import os, mmap, sys
		fd = os.open(sys.argv[1], os.O_WRONLY | os.O_DIRECT)
		buf = mmap.mmap(-1, 4 << 20)
		buf.write(b'\x32' * len(buf))
		os.pwritev(fd, [buf], 0)
		os.fsync(fd)
		os.close(fd)
	EOF
	c=$(( $(probe commits) - c0 ))
	[ "$c" -gt 0 ] && echo "  direct write committed by tau: PASS ($c commits)" ||
		{ echo "  direct write committed by tau: FAIL (no tau commit)"; rc=1; }
	check "direct read after a direct write" 0x32 || rc=1

	echo "== mmap: no writable shared mapping of a tau file, ever =="
	sudo python3 - "$A" "$TAU_MNT/c" <<-'EOF' || rc=1
		import ctypes, ctypes.util, errno, os, sys
		libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
		libc.mmap.restype = ctypes.c_void_p
		libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
		                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
		libc.mprotect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
		libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
		FAILED = ctypes.c_void_p(-1).value
		RD, WR, SHARED, PRIVATE, N = 1, 2, 1, 2, 4096
		a, c = sys.argv[1], sys.argv[2]
		bad = 0
		def mapit(fd, prot, flags):
		    p = libc.mmap(None, N, prot, flags, fd, 0)
		    return (None, ctypes.get_errno()) if p == FAILED else (p, 0)
		def say(ok, what):
		    global bad
		    print("  %s: %s" % (what, "PASS" if ok else "FAIL"))
		    bad += not ok
		fd = os.open(a, os.O_RDWR)
		p, e = mapit(fd, RD | WR, SHARED)
		say(p is None and e == errno.EOPNOTSUPP, "tau file, writable shared mmap refused")
		p, e = mapit(fd, RD, SHARED)
		say(p is not None, "tau file, read-only shared mmap allowed")
		if p is not None:
		    r = libc.mprotect(p, N, RD | WR)
		    e = ctypes.get_errno()
		    say(r != 0 and e == errno.EACCES, "  ...mprotect() cannot make it writable")
		    libc.munmap(p, N)
		before = os.pread(fd, N, 0)
		p, e = mapit(fd, RD | WR, PRIVATE)
		say(p is not None, "tau file, private writable mmap allowed")
		if p is not None:
		    ctypes.memset(p, 0x7e, N)
		    libc.munmap(p, N)
		say(os.pread(fd, N, 0) == before, "  ...and the file is unchanged")
		os.close(fd)
		fd = os.open(c, os.O_CREAT | os.O_RDWR, 0o644)
		os.pwrite(fd, b'\x55' * N, 0)
		p, e = mapit(fd, RD | WR, SHARED)
		say(p is not None, "plain file, writable shared mmap allowed")
		try:
		    os.close(os.open(c, os.O_RDWR | 0o40000000))
		    say(False, "  ...O_TAU_UNTORN refused while it is mapped")
		except OSError as ex:
		    say(ex.errno == errno.EBUSY, "  ...O_TAU_UNTORN refused while it is mapped")
		if p is not None:
		    libc.munmap(p, N)
		try:
		    os.close(os.open(c, os.O_RDWR | 0o40000000))
		    say(True, "  ...and allowed once unmapped")
		except OSError as ex:
		    say(False, "  ...and allowed once unmapped (%s)" % os.strerror(ex.errno))
		os.close(fd)
		sys.exit(1 if bad else 0)
	EOF

	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	[ $rc -eq 0 ] || exit 1
	echo WRITTEN
else
	mount_tau "$FS"
	check recovered 0x32
	rc=$?
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	sudo umount "$TAU_MNT" || rc=1
	exit $rc
fi
