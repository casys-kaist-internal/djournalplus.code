#!/bin/bash
# An unlinked tau file is let go once nothing holds it -- its tau_t freed and
# its blocks back to the FS -- instead of at unmount (#24).
# Layout: README.  usage: unlink.sh <xfs|ext4> live|write|verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; MODE=$2
P=/sys/module/tau_journal/parameters
A=$TAU_MNT/a; B=$TAU_MNT/b; FILL=$TAU_MNT/filler
MAP=$HOME/unlink-freed.txt
O_TAU=0o40000000

probe() { cat $P/tau_probe_$1 2>/dev/null || echo 0; }
# files tau holds a tau_t for
held() { echo $(( $(probe tau_alloced) - $(probe tau_freed) )); }
avail() { df --output=avail -B1 "$TAU_MNT" | tail -1; }
rc=0
fail() { echo "  FAIL: $*"; rc=1; }

# host log force: fsync a file tau does not journal
logforce() {
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x")
os.fsync(fd)
os.close(fd)' "$TAU_MNT/logforce" || die "log force"
}

# wait_held <n>: up to 30 s for held() to come down to <n>; prints the seconds
wait_held() {
	local i

	for i in $(seq 0 30); do
		[ "$(held)" -le "$1" ] && { echo "$i"; return 0; }
		sleep 1
	done
	return 1
}

# fill <path> <MiB> <byte>: a tau file in 4 MiB writes, then fsync
fill() {
	local i

	for i in $(seq 0 $(( $2 / 4 - 1 ))); do
		sudo "$TAUWRITE_NOFSYNC" "$1" $((4 * MB)) "$3" $((i * 4 * MB)) >/dev/null ||
			die "write $1"
	done
	sudo "$TAUWRITE" "$1" 4096 "$3" 0 >/dev/null || die "fsync $1"
}

# physical blocks of <file> in [<first>, <end>) logical blocks, one per line
pblocks() {
	sudo filefrag -b4096 -v "$1" | awk -v s="$2" -v e="$3" '
		/^[[:space:]]*[0-9]+:/ {
			gsub(/\.\./, " "); gsub(/:/, " ");
			for (l = $2; l <= $3; l++)
				if (l >= s && l < e) print $4 + (l - $2);
		}'
}

case "$MODE" in
live)
	mkfs_mount "$FS"
	sudo dmesg -C
	h0=$(held); r0=$(probe dead_released); y0=$(probe dead_retry)

	echo "== closed: 256 MiB tau file, 64 MiB rewritten, unlink =="
	fill "$A" 256 $((0xA1))
	fill "$A" 64 $((0xA2))
	[ "$(held)" -eq $((h0 + 1)) ] || fail "held $(held), want $((h0 + 1))"
	logforce; a0=$(avail)
	sudo rm "$A"
	if t=$(wait_held "$h0"); then
		# XFS frees the blocks in the background (inodegc)
		for i in $(seq 1 10); do
			logforce
			gain=$(( ($(avail) - a0) / MB ))
			[ "$gain" -ge 250 ] && break
			sleep 1
		done
		echo "  let go after ${t}s, $gain MiB back"
		[ "$gain" -ge 250 ] || fail "only $gain MiB came back"
	else
		fail "still held 30 s after the unlink"
	fi

	echo "== open: unlink while open, keep writing, then close =="
	h1=$(held)
	sudo rm -f "$HOME/unlink-go"
	sudo python3 - "$A" "$HOME/unlink-go" $O_TAU <<-'EOF' &
		import os, sys, time
		path, go, flag = sys.argv[1], sys.argv[2], int(sys.argv[3], 8)
		fd = os.open(path, os.O_CREAT | os.O_RDWR | flag, 0o644)
		mb = 1 << 20
		for i in range(64):
		    os.pwrite(fd, bytes([0xB1]) * mb, i * mb)
		os.fsync(fd)
		os.unlink(path)
		for i in range(64):
		    os.pwrite(fd, bytes([0xB2]) * mb, i * mb)
		os.fsync(fd)
		bad = sum(os.pread(fd, mb, i * mb) != bytes([0xB2]) * mb for i in range(64))
		print("  unlinked, rewritten and read back: %d MiB wrong" % bad)
		open(go + ".ready", "w").close()
		while not os.path.exists(go):
		    time.sleep(0.1)
		os.close(fd)
		sys.exit(1 if bad else 0)
	EOF
	py=$!
	for i in $(seq 1 60); do [ -e "$HOME/unlink-go.ready" ] && break; sleep 1; done
	sleep 3	# three reaper passes
	[ "$(held)" -eq $((h1 + 1)) ] ||
		fail "an open file was let go (held $(held), want $((h1 + 1)))"
	sudo touch "$HOME/unlink-go"
	wait $py || fail "the unlinked file read back wrong"
	sudo rm -f "$HOME/unlink-go" "$HOME/unlink-go.ready"
	if t=$(wait_held "$h1"); then
		echo "  let go ${t}s after the close"
	else
		fail "still held 30 s after the close"
	fi

	echo "== many: 200 files, half truncated to 0 first (as PostgreSQL drops) =="
	h2=$(held)
	sudo mkdir -p "$TAU_MNT/many"
	for i in $(seq 1 200); do
		sudo "$TAUWRITE" "$TAU_MNT/many/f$i" $MB $((i % 256)) >/dev/null || die "many f$i"
	done
	[ "$(held)" -eq $((h2 + 200)) ] || fail "held $(held), want $((h2 + 200))"
	for i in $(seq 1 100); do sudo truncate -s 0 "$TAU_MNT/many/f$i"; done
	sudo rm -rf "$TAU_MNT/many"
	if t=$(wait_held "$h2"); then
		echo "  all 200 let go after ${t}s"
	else
		fail "$(( $(held) - h2 )) of 200 still held after 30 s"
	fi

	echo "== links: the second name keeps it; rename over the last one lets it go =="
	h3=$(held)
	sudo "$TAUWRITE" "$A" $((4 * MB)) $((0xC1)) >/dev/null || die "links"
	sudo ln "$A" "$TAU_MNT/a2"
	sudo rm "$A"
	sleep 3
	[ "$(held)" -eq $((h3 + 1)) ] || fail "let go while a link remained"
	sudo touch "$TAU_MNT/c"
	sudo mv "$TAU_MNT/c" "$TAU_MNT/a2"
	if t=$(wait_held "$h3"); then
		echo "  let go ${t}s after the rename"
	else
		fail "still held 30 s after the rename replaced it"
	fi

	y=$(( $(probe dead_retry) - y0 ))
	echo "== released $(( $(probe dead_released) - r0 )), put back $y =="
	[ "$y" = 0 ] || fail "a release stalled"
	sudo umount "$TAU_MNT" || fail "umount"
	mount_tau "$FS"
	sudo umount "$TAU_MNT" || fail "second umount"
	warn=$(sudo dmesg | grep -c "WARNING: CPU")
	[ "$warn" = 0 ] || { sudo dmesg | grep -A8 "WARNING: CPU" | head -30; fail "kernel warning"; }
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; fail "kernel fault"; }
	[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
	exit $rc
	;;
write)
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"
	echo "== A: 128 MiB of 0xA1, 32 MiB rewritten with 0xA2, fsync =="
	fill "$A" 128 $((0xA1))
	fill "$A" 32 $((0xA2))
	# from here the journal must not hand segments back to the full FS
	echo 0 | sudo tee $P/tau_reclaim_margin_mb $P/tau_fs_margin_pct >/dev/null
	avail=$(avail)
	fill=$(( (avail - 16 * MB) / MB * MB ))
	echo "== filler: fallocate $((fill / MB)) MiB, leaving ~16 MiB =="
	sudo fallocate -l "$fill" "$FILL" || die "fallocate filler"
	pblocks "$A" 0 32768 > "$MAP"
	h0=$(held); r0=$(probe dead_released)
	sudo rm "$A"
	t=$(wait_held $((h0 - 1))) || die "A still held 30 s after the unlink"
	echo "== A let go after ${t}s (released $(( $(probe dead_released) - r0 ))) =="
	# freed extents stay busy until the host log commits
	logforce

	echo "== B: 0xBB until ENOSPC, fsync =="
	sudo python3 - "$B" <<-'EOF' || die "B"
		import os, sys
		buf = bytes([0xBB]) * (1 << 20)
		fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
		n = 0
		try:
		    while True:
		        os.write(fd, buf)
		        n += 1
		except OSError:
		    pass                    # ENOSPC is the goal
		os.fsync(fd)
		os.close(fd)
		print("  B: %d MiB" % n)
	EOF
	nb=$(( $(stat -c %s "$B") / 4096 ))
	over=$(pblocks "$B" 0 "$nb" | awk 'NR == FNR { a[$1] = 1; next } a[$1] { n++ } END { print n + 0 }' "$MAP" -)
	echo "== B holds $over of the blocks A freed =="
	[ "$over" -gt 0 ] || { echo "INCONCLUSIVE: B reused none of A's blocks"; exit 3; }
	logforce
	echo WRITTEN
	;;
verify)
	mount_tau "$FS"
	[ -e "$A" ] && fail "A is back"
	sudo python3 - "$B" <<-'EOF' || rc=1
		import sys, collections
		d = open(sys.argv[1], 'rb').read()
		full = len(d) // 4096
		wrong = collections.Counter()
		for i in range(full):
		    blk = d[i * 4096:(i + 1) * 4096]
		    if blk != b'\xbb' * 4096:
		        wrong[blk[0]] += 1
		if wrong:
		    print("  B: %d of %d blocks not 0xBB (%s)" % (sum(wrong.values()), full,
		          " ".join("%#04x:%d" % kv for kv in sorted(wrong.items()))))
		    sys.exit(1)
		print("  B: all %d blocks 0xBB" % full)
	EOF
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	sudo umount "$TAU_MNT" || rc=1
	[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
	exit $rc
	;;
*)
	die "usage: $0 <xfs|ext4> live|write|verify"
	;;
esac
