#!/bin/bash
# Blocks a tau file freed and another file reused are not replayed over (#20);
# a free the host lost in a power cut leaves the file as it was (gate,
# gatepunch: kernel plan.md §12.4).  Layout: README.
# usage: trunc-reuse.sh <xfs|ext4> <trunc|truncr|punch|collapse|keep|gate|gatepunch> write|verify
#   FREE_UNCOND=1 / FREE_NOHOLD=1 (gate*): the controls, which must fail
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; CASE=$2; MODE=$3
A=$TAU_MNT/a; B=$TAU_MNT/b; FILL=$TAU_MNT/filler
MAP=$HOME/trunc-reuse-freed.txt
P=/sys/module/tau_journal/parameters
export TAU_FS_SIZE=${TAU_FS_SIZE:-8g}

case "$CASE" in
trunc|truncr|punch|collapse|keep|gate|gatepunch) ;;
*) die "usage: $0 <xfs|ext4> <trunc|truncr|punch|collapse|keep|gate|gatepunch> write|verify" ;;
esac

probe() { cat $P/tau_probe_$1 2>/dev/null || echo 0; }
rc=0
fail() { echo "  FAIL: $*"; rc=1; }

# the host commits only when asked: ext4 every 600 s, XFS's log worker likewise
slow_host() {
	case "$FS" in
	ext4) TAU_MOUNT_OPTS="${TAU_MOUNT_OPTS:-tjournal},commit=600" ;;
	xfs) echo 60000 | sudo tee /proc/sys/fs/xfs/xfssyncd_centisecs >/dev/null ;;
	esac
}

# fill <path> <MiB> <byte> [<offset MiB>]: tau writes of 4 MiB, then fsync
fill() {
	local i off=$(( ${4:-0} * MB ))

	for i in $(seq 0 $(( $2 / 4 - 1 ))); do
		sudo "$TAUWRITE_NOFSYNC" "$1" $((4 * MB)) "$3" $((off + i * 4 * MB)) >/dev/null ||
			die "write $1"
	done
	sudo "$TAUWRITE" "$1" 4096 "$3" "$off" >/dev/null || die "fsync $1"
}

# wait_dropped <base> <n>: up to 20 s for tx_dropped to pass <base> + <n>
wait_dropped() {
	local i

	for i in $(seq 0 20); do
		[ $(( $(probe tx_dropped) - $1 )) -ge "$2" ] && return 0
		sleep 1
	done
	return 1
}

# host log force: fsync a file tau does not journal
logforce() {
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x")
os.fsync(fd)
os.close(fd)' "$TAU_MNT/logforce" || die "log force"
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

if [ "$MODE" = write ] && [ "$CASE" = keep ]; then
	# the truncate must not be durable at the power cut: ext4 commits every 60 s
	[ "$FS" = ext4 ] && export TAU_MOUNT_OPTS=${TAU_MOUNT_OPTS:-tjournal,commit=60}
	echo 1 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"
	c0=$(probe commits); d0=$(probe tx_dropped)
	echo "== T0: 8 MiB of 0xA0, checkpointed and dropped =="
	sudo "$TAUWRITE" "$A" $((8 * MB)) $((0xA0)) >/dev/null || die "T0"
	for w in $(seq 1 20); do
		sleep 1
		[ $(( $(probe tx_dropped) - d0 )) -ge $(( $(probe commits) - c0 )) ] && break
	done
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
	echo "== T1: 8 MiB of 0xA1 (TauRedo over home 0xA0), truncate to 4 MiB =="
	sudo "$TAUWRITE" "$A" $((8 * MB)) $((0xA1)) >/dev/null || die "T1"
	h0=$(probe free_home)
	sudo truncate -s $((4 * MB)) "$A" || die "truncate"
	echo "== written home before the free: $(( $(probe free_home) - h0 )) blocks =="
	echo WRITTEN
elif [ "$MODE" = write ] && [ "${CASE#gate}" != "$CASE" ]; then
	# A's newest copies of the range only in the journal, its homes older,
	# and the host never told to commit the free
	echo "${FREE_UNCOND:-0}" | sudo tee $P/tau_free_uncond >/dev/null || die "no tau_free_uncond"
	echo "${FREE_NOHOLD:-0}" | sudo tee $P/tau_free_nohold >/dev/null || die "no tau_free_nohold"
	slow_host
	echo 1 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"
	d0=$(probe tx_dropped); c0=$(probe commits)
	echo "== T0: 64 MiB of 0xA0, checkpointed and dropped: the homes =="
	fill "$A" 64 $((0xA0))
	wait_dropped "$d0" $(( $(probe commits) - c0 )) || die "T0 not dropped"
	echo 0 | sudo tee $P/tau_cp_small_tx >/dev/null
	# a tx's age is fixed at its commit
	echo "== T1: the first 32 MiB 0xA1, checkpointed; T2: the last 32 MiB 0xA2, journal only =="
	d1=$(probe tx_dropped); c1=$(probe commits)
	fill "$A" 32 $((0xA1))
	t1=$(( $(probe commits) - c1 ))		# a background commit may split it
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
	fill "$A" 32 $((0xA2)) 32
	wait_dropped "$d1" "$t1" || die "T1 not dropped"
	o0=$(probe free_old); h0=$(probe free_home); t0=$(probe free_cond); k0=$(probe free_hold)
	case $CASE in
	gate) sudo truncate -s $((32 * MB)) "$A" || die "truncate" ;;
	# not fallocate(1): it fsyncs before the close, and the punch is durable
	gatepunch) sudo python3 -c 'import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong]
fd = os.open(sys.argv[1], os.O_RDWR)
if libc.fallocate(fd, 3, int(sys.argv[2]), int(sys.argv[3])):	# PUNCH_HOLE | KEEP_SIZE
    raise OSError(ctypes.get_errno(), "fallocate")
os.close(fd)' "$A" $((32 * MB)) $((32 * MB)) || die "punch" ;;
	esac
	tags=$(( $(probe free_cond) - t0 )); held=$(( $(probe free_hold) - k0 ))
	echo "== the last 32 MiB freed, the host not told to commit: $tags tags, $held held, old path $(( $(probe free_old) - o0 )), home writes $(( $(probe free_home) - h0 )) =="
	[ "$(( $(probe free_old) - o0 ))" = 0 ] || fail "took the old path"
	[ "$(( $(probe free_home) - h0 ))" = 0 ] || fail "wrote the range home"
	[ "$tags" = 8192 ] || fail "$tags tags, want 8192"
	[ "$held" = $(( 1 - ${FREE_NOHOLD:-0} )) ] || fail "held $held"
	d2=$(probe tx_dropped)
	sleep 3
	n=$(( $(probe tx_dropped) - d2 ))
	echo "== txs dropped since the free: $n (held: T2 and the free's own) =="
	[ "${FREE_NOHOLD:-0}" = 1 ] || [ "$n" = 0 ] || fail "$n txs dropped, want 0"
	echo "== block 0 rewritten with 0xA3, no fsync: a background commit moves the tail =="
	c1=$(probe commits)
	sudo "$TAUWRITE_NOFSYNC" "$A" 4096 $((0xA3)) 0 >/dev/null || die "write block 0"
	for w in $(seq 1 15); do
		sleep 1
		[ $(( $(probe commits) - c1 )) -ge 1 ] && break
	done
	[ $(( $(probe commits) - c1 )) -ge 1 ] || { echo "INCONCLUSIVE: no background commit"; exit 3; }
	[ $rc -eq 0 ] || exit $rc
	echo WRITTEN
elif [ "$MODE" = write ]; then
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"

	if [ "$CASE" = truncr ]; then
		# the range's blocks get theirs from the truncate's own commit
		echo "== A: 64 MiB of 0xA1, fsync; 64 MiB more of 0xA2, no fsync =="
		for i in $(seq 0 15); do
			sudo "$TAUWRITE_NOFSYNC" "$A" $((4 * MB)) $((0xA1)) $((i * 4 * MB)) >/dev/null ||
				die "tauwrite A"
		done
		sudo "$TAUWRITE" "$A" 4096 $((0xA1)) 0 >/dev/null || die "fsync A"
		for i in $(seq 16 31); do
			sudo "$TAUWRITE_NOFSYNC" "$A" $((4 * MB)) $((0xA2)) $((i * 4 * MB)) >/dev/null ||
				die "tauwrite A"
		done
	else
		echo "== A: 128 MiB of 0xA1 in 4 MiB writes, fsync =="
		for i in $(seq 0 31); do
			sudo "$TAUWRITE_NOFSYNC" "$A" $((4 * MB)) $((0xA1)) $((i * 4 * MB)) >/dev/null ||
				die "tauwrite A"
		done
		sudo "$TAUWRITE" "$A" 4096 $((0xA1)) 0 >/dev/null || die "fsync A"
	fi
	# from here the journal must not hand segments back to the full FS
	echo 0 | sudo tee $P/tau_reclaim_margin_mb $P/tau_fs_margin_pct >/dev/null

	avail=$(df --output=avail -B1 "$TAU_MNT" | tail -1)
	fill=$(( (avail - 16 * MB) / MB * MB ))
	echo "== filler: fallocate $((fill / MB)) MiB, leaving ~16 MiB =="
	sudo fallocate -l "$fill" "$FILL" || die "fallocate filler"

	case "$CASE" in
	trunc) first=0;    end=32768 ;;
	truncr) first=16384; end=32768 ;;
	*)     first=8192; end=24576 ;;
	esac
	pblocks "$A" $first $end > "$MAP"
	echo "== A frees logical blocks [$first, $end): $(wc -l < "$MAP") blocks mapped =="
	t0=$(probe free_cond)
	case "$CASE" in
	trunc) sudo truncate -s 0 "$A" || die "truncate" ;;
	truncr) sudo truncate -s $((64 * MB)) "$A" || die "truncate" ;;
	punch) sudo fallocate -p -o $((32 * MB)) -l $((64 * MB)) "$A" || die "punch" ;;
	collapse) sudo fallocate -c -o $((32 * MB)) -l $((64 * MB)) "$A" || die "collapse" ;;
	esac
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
	tags=$(( $(probe free_cond) - t0 ))
	echo "== conditional tags for the range: $tags =="
	if [ "$CASE" = truncr ]; then
		# their blocks came after the map above: B's share of them unknown
		[ "$tags" = 16384 ] || { echo "  FAIL: $tags tags, want 16384"; exit 1; }
	else
		over=$(pblocks "$B" 0 "$nb" | awk 'NR == FNR { a[$1] = 1; next } a[$1] { n++ } END { print n + 0 }' "$MAP" -)
		echo "== B holds $over of the blocks A freed =="
		[ "$over" -gt 0 ] || { echo "INCONCLUSIVE: B reused none of A's blocks"; exit 3; }
	fi
	logforce
	echo WRITTEN
else
	mount_tau "$FS"
	ino=$(stat -c %i "$A")
	sudo dmesg | grep -E "TAU: .*ino $ino[: ,]" | grep -v 'found revoke' | sed 's/^/  /'
	if [ "${CASE#gate}" != "$CASE" ]; then
		sudo python3 - "$A" "$CASE" <<-'EOF'
			import sys, collections
			d, case = open(sys.argv[1], 'rb').read(), sys.argv[2]
			n = len(d) // 4096
			blk = [d[i * 4096:(i + 1) * 4096] for i in range(n)]
			def hist(r):
			    c = collections.Counter(blk[i][0] if len(set(blk[i])) == 1 else -1 for i in r)
			    return " ".join("%#04x:%d" % kv if kv[0] >= 0 else "mixed:%d" % kv[1] for kv in sorted(c.items()))
			head = range(1, 8192)
			b0 = blk[0] in (b'\xa1' * 4096, b'\xa3' * 4096) if n else False
			if not b0 or any(blk[i] != b'\xa1' * 4096 for i in head):
			    print("RESULT: FAIL (the first 32 MiB: block 0 %s, the rest %s)" % (
			          "ok" if b0 else "wrong", hist(head))); sys.exit(1)
			tail = range(8192, n)
			if case == 'gate' and len(d) == 32 << 20:
			    print("RESULT: INCONCLUSIVE (the truncate was durable)"); sys.exit(3)
			if len(d) != 64 << 20:
			    print("RESULT: FAIL (size %d)" % len(d)); sys.exit(1)
			if case == 'gatepunch' and all(blk[i] == b'\0' * 4096 for i in tail):
			    print("RESULT: INCONCLUSIVE (the punch was durable)"); sys.exit(3)
			if all(blk[i] == b'\xa2' * 4096 for i in tail):
			    print("RESULT: PASS (64 MiB, the last 32 MiB 0xA2: the free not durable, content current)")
			    sys.exit(0)
			print("RESULT: FAIL (the last 32 MiB: %s)" % hist(tail)); sys.exit(1)
		EOF
		rc=$?
		[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
		sudo umount "$TAU_MNT" || rc=1
		exit $rc
	fi
	if [ "$CASE" = keep ]; then
		sudo python3 - "$A" <<-'EOF'
			import sys, collections
			d = open(sys.argv[1], 'rb').read()
			hist = " ".join("%#04x:%d" % kv for kv in sorted(collections.Counter(d[i] for i in range(0, len(d), 4096)).items()))
			if len(d) == 4 << 20 and d == b'\xa1' * len(d):
			    print("RESULT: INCONCLUSIVE (the truncate was durable)"); sys.exit(3)
			if len(d) == 8 << 20 and d == b'\xa1' * len(d):
			    print("RESULT: PASS (8 MiB of 0xA1: the truncate not durable, content current)"); sys.exit(0)
			print("RESULT: FAIL (size %d, blocks %s)" % (len(d), hist)); sys.exit(1)
		EOF
		rc=$?
		sudo umount "$TAU_MNT"
		exit $rc
	fi
	sudo python3 - "$A" "$B" "$CASE" <<-'EOF'
		import sys, collections
		a, b, case = sys.argv[1], sys.argv[2], sys.argv[3]
		bad = []
		d = open(b, 'rb').read()
		full = len(d) // 4096
		wrong = collections.Counter()
		for i in range(full):
		    blk = d[i * 4096:(i + 1) * 4096]
		    if blk != b'\xbb' * 4096:
		        wrong[blk[0]] += 1
		if wrong:
		    bad.append("B: %d of %d blocks not 0xBB (%s)" % (sum(wrong.values()), full,
		               " ".join("%#04x:%d" % kv for kv in sorted(wrong.items()))))
		d = open(a, 'rb').read()
		if case == 'trunc':
		    if d:
		        bad.append("A: %d bytes after truncate to 0" % len(d))
		elif case == 'truncr':
		    if d != b'\xa1' * (64 << 20):
		        bad.append("A: not 64 MiB of 0xA1 (size %d)" % len(d))
		elif case == 'collapse':
		    if d != b'\xa1' * (64 << 20):
		        bad.append("A: not 64 MiB of 0xA1 (size %d)" % len(d))
		else:
		    want = b'\xa1' * (32 << 20) + b'\0' * (64 << 20) + b'\xa1' * (32 << 20)
		    if d != want:
		        bad.append("A: not 32 MiB 0xA1, 64 MiB hole, 32 MiB 0xA1 (size %d)" % len(d))
		print("RESULT: " + ("FAIL (" + "; ".join(bad) + ")" if bad else
		      "PASS (B all 0xBB, %d blocks)" % full))
		sys.exit(1 if bad else 0)
	EOF
	rc=$?
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	sudo umount "$TAU_MNT" || rc=1
	exit $rc
fi
