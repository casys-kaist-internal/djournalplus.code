#!/bin/bash
# A tau file's timestamps are lazytime: a write moves them in memory, a clean
# umount or a sync writes them, and fsync makes the data durable without a host
# journal commit per call (#24).
# Layout: README.  usage: mtime.sh <xfs|ext4> live|write|verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; MODE=$2
A=$TAU_MNT/a; S=$TAU_MNT/s; F=$TAU_MNT/f
REC=$HOME/mtime-rec.txt
rc=0
fail() { echo "  FAIL: $*"; rc=1; }

mt() { sudo python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"; }

# host journal commits (ext4) or log forces (XFS) so far
hostcommits() {
	local d=${TAU_DEV##*/}

	if [ "$FS" = ext4 ]; then
		awk 'NR == 1 { print $1 }' "/proc/fs/jbd2/$d-8/info"
	else
		awk '$1 == "log" { print $5 }' "/sys/fs/xfs/$d/stats/stats"
	fi
}

# first block and the rest of <file> read back as <b0> and <b1>
content() {
	sudo python3 - "$1" "$2" "$3" <<-'EOF'
		import sys
		d = open(sys.argv[1], 'rb').read()
		b0, b1 = int(sys.argv[2], 0), int(sys.argv[3], 0)
		ok = d[:4096] == bytes([b0]) * 4096 and d[4096:] == bytes([b1]) * (len(d) - 4096)
		sys.exit(0 if ok and len(d) == 4 << 20 else 1)
	EOF
}

case "$MODE" in
live)
	mkfs_mount "$FS"
	sudo dmesg -C
	echo "== a write moves mtime =="
	sudo "$TAUWRITE" "$A" $((4 * MB)) $((0xA1)) >/dev/null || die "A"
	m0=$(mt "$A")
	sleep 1.1
	sudo "$TAUWRITE_NOFSYNC" "$A" 4096 $((0xA2)) 0 >/dev/null || die "A rewrite"
	m1=$(mt "$A")
	[ "$m1" -gt "$m0" ] && echo "  moved by $(( (m1 - m0) / 1000000 )) ms" ||
		fail "mtime did not move ($m0 -> $m1)"

	echo "== a clean umount keeps it =="
	sudo umount "$TAU_MNT" || fail "umount"
	mount_tau "$FS"
	m2=$(mt "$A")
	[ "$m2" = "$m1" ] && echo "  kept" || fail "mtime after umount $m2, want $m1"

	echo "== 200 x (rewrite + fsync): no host commit per fsync =="
	c0=$(hostcommits)
	for i in $(seq 1 200); do
		sudo "$TAUWRITE" "$A" 4096 $((i % 256)) 0 >/dev/null || die "rewrite $i"
	done
	c=$(( $(hostcommits) - c0 ))
	echo "  $c host $( [ "$FS" = ext4 ] && echo "journal commits" || echo "log forces")"
	[ "$c" -lt 50 ] || fail "$c host commits for 200 fsyncs"

	sudo umount "$TAU_MNT" || fail "umount"
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; fail "kernel fault"; }
	[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
	exit $rc
	;;
write)
	mkfs_mount "$FS"
	sudo "$TAUWRITE" "$S" $((4 * MB)) $((0xC1)) >/dev/null || die "S"
	sudo "$TAUWRITE" "$F" $((4 * MB)) $((0xD1)) >/dev/null || die "F"
	sleep 1.1
	echo "== S: rewrite, fsync, syncfs =="
	sudo "$TAUWRITE" "$S" 4096 $((0xC2)) 0 >/dev/null || die "S rewrite"
	sudo sync -f "$S" || die "syncfs"
	ms=$(mt "$S")
	fo=$(mt "$F")
	sleep 1.1
	echo "== F: rewrite, fsync only =="
	sudo "$TAUWRITE" "$F" 4096 $((0xD2)) 0 >/dev/null || die "F rewrite"
	fn=$(mt "$F")
	echo "$ms $fo $fn" > "$REC"
	sync -f "$REC"
	echo WRITTEN
	;;
verify)
	mount_tau "$FS"
	read -r ms fo fn < "$REC" || die "no record"
	content "$S" 0xC2 0xC1 && echo "  S: data intact" || fail "S: data"
	content "$F" 0xD2 0xD1 && echo "  F: data intact" || fail "F: data"
	m=$(mt "$S")
	[ "$m" = "$ms" ] && echo "  S: mtime kept by the sync" || fail "S: mtime $m, want $ms"
	m=$(mt "$F")
	if [ "$m" = "$fn" ]; then
		echo "  F: mtime the new one (a host commit came first)"
	elif [ "$m" = "$fo" ]; then
		echo "  F: mtime the old one (lazytime, as documented)"
	else
		fail "F: mtime $m, neither $fo nor $fn"
	fi
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; fail "kernel fault"; }
	sudo umount "$TAU_MNT" || fail "umount"
	[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
	exit $rc
	;;
*)
	die "usage: $0 <xfs|ext4> live|write|verify"
	;;
esac
