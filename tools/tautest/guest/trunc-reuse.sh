#!/bin/bash
# Blocks a tau file freed and another file reused are not replayed over (#20).
# Layout: README.  usage: trunc-reuse.sh <xfs|ext4> <trunc|punch|collapse|keep> write|verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; CASE=$2; MODE=$3
A=$TAU_MNT/a; B=$TAU_MNT/b; FILL=$TAU_MNT/filler
MAP=$HOME/trunc-reuse-freed.txt
P=/sys/module/tau_journal/parameters
export TAU_FS_SIZE=${TAU_FS_SIZE:-8g}

case "$CASE" in
trunc|punch|collapse|keep) ;;
*) die "usage: $0 <xfs|ext4> <trunc|punch|collapse|keep> write|verify" ;;
esac

probe() { cat $P/tau_probe_$1 2>/dev/null || echo 0; }

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
elif [ "$MODE" = write ]; then
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"

	echo "== A: 128 MiB of 0xA1 in 4 MiB writes, fsync =="
	for i in $(seq 0 31); do
		sudo "$TAUWRITE_NOFSYNC" "$A" $((4 * MB)) $((0xA1)) $((i * 4 * MB)) >/dev/null ||
			die "tauwrite A"
	done
	sudo "$TAUWRITE" "$A" 4096 $((0xA1)) 0 >/dev/null || die "fsync A"
	# from here the journal must not hand segments back to the full FS
	echo 0 | sudo tee $P/tau_reclaim_margin_mb $P/tau_fs_margin_pct >/dev/null

	avail=$(df --output=avail -B1 "$TAU_MNT" | tail -1)
	fill=$(( (avail - 16 * MB) / MB * MB ))
	echo "== filler: fallocate $((fill / MB)) MiB, leaving ~16 MiB =="
	sudo fallocate -l "$fill" "$FILL" || die "fallocate filler"

	case "$CASE" in
	trunc) first=0;    end=32768 ;;
	*)     first=8192; end=24576 ;;
	esac
	pblocks "$A" $first $end > "$MAP"
	echo "== A frees logical blocks [$first, $end): $(wc -l < "$MAP") blocks =="
	case "$CASE" in
	trunc) sudo truncate -s 0 "$A" || die "truncate" ;;
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
	over=$(pblocks "$B" 0 "$nb" | awk 'NR == FNR { a[$1] = 1; next } a[$1] { n++ } END { print n + 0 }' "$MAP" -)
	echo "== B holds $over of the blocks A freed =="
	[ "$over" -gt 0 ] || { echo "INCONCLUSIVE: B reused none of A's blocks"; exit 3; }
	logforce
	echo WRITTEN
else
	mount_tau "$FS"
	ino=$(stat -c %i "$A")
	sudo dmesg | grep -E "TAU: .*ino $ino[: ,]" | grep -v 'found revoke' | sed 's/^/  /'
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
