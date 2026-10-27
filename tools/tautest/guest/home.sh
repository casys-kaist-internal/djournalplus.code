#!/bin/bash
# New blocks go home, not to the journal (kernel plan.md §12.5).  Layout: README.
#   basic   a fresh 160 MiB, past a segment: written home, not journaled; an
#           overwrite of 4 MiB is; both survive a power cut.  Then on B one tx
#           of both, new blocks and overwritten ones, checkpointed
#   race    an 8 KiB rewrite while the commit that writes the page home is
#           held up: it waits, is journaled after, and survives
#   reuse   a block's journal copy, a punch the host has, the block given back
#           by a rewrite that goes home: the copy is not replayed over it
# usage: home.sh <xfs|ext4> <basic|race|reuse> write|verify
#   HOME_NOWAIT=1 (race): the control, the rewrite goes in place -- must fail
#   HOME_NOREVOKE=1 (reuse, verify): the control, recovery replays the copy -- must fail
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; CASE=$2; MODE=$3
A=$TAU_MNT/a; B=$TAU_MNT/b
MAP=$HOME/home-pblk.txt
P=/sys/module/tau_journal/parameters
KB=1024
export TAU_FS_SIZE=${TAU_FS_SIZE:-8g}

case "$CASE" in
basic|race|reuse) ;;
*) die "usage: $0 <xfs|ext4> <basic|race|reuse> write|verify" ;;
esac

probe() { cat $P/tau_probe_$1 2>/dev/null || echo 0; }
setparam() { echo "$2" | sudo tee "$P/$1" >/dev/null || die "cannot set $1"; }
[ -r "$P/tau_home" ] || die "no tau_home: this test needs CONFIG_TAU_PROBE_TORN=y and kernel #372 or later"
rc=0
fail() { echo "  FAIL: $*"; rc=1; }
# none since boot: the guest console does not print them
warnings() {
	local n

	n=$(sudo dmesg | grep -c 'WARNING:')
	[ "$n" = 0 ] && return 0
	sudo dmesg | grep -A4 'WARNING:' | head -15 | sed 's/^/  /'
	return 1
}

# pw <path> <off> <len> <byte> [fsync]: one tau write, timed (ms on stdout)
pw() {
	sudo python3 - "$@" <<'EOF'
import os, sys, time
path, off, ln, byte = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4], 0)
fd = os.open(path, os.O_CREAT | os.O_RDWR | 0o40000000, 0o644)
t = time.monotonic()
os.pwrite(fd, bytes([byte]) * ln, off)
if len(sys.argv) > 5:
    os.fsync(fd)
print(int((time.monotonic() - t) * 1000))
os.close(fd)
EOF
}

# punch <path> <off> <len>: fallocate(2) itself -- fallocate(1) fsyncs at close
punch() {
	sudo python3 - "$@" <<'EOF'
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(sys.argv[1], os.O_RDWR | 0o40000000)
if libc.fallocate(fd, 3, ctypes.c_long(int(sys.argv[2])), ctypes.c_long(int(sys.argv[3]))):
    sys.exit("fallocate: " + os.strerror(ctypes.get_errno()))
os.close(fd)
EOF
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

# expect_range <name> <off> <len> <byte> [<file>, A by default]
expect_range() {
	local got want f=${5:-$A}

	got=$(sudo dd if="$f" bs=4096 skip=$(($2 / 4096)) count=$(($3 / 4096)) 2>/dev/null | md5sum | awk '{print $1}')
	want=$(md5_of_repeat $(($4)) "$3")
	if [ "$got" = "$want" ]; then
		printf '  PASS %-8s %d KiB at %d KiB = 0x%x\n' "$1" $(($3 / KB)) $(($2 / KB)) "$4"
	else
		printf '  FAIL %-8s %d KiB at %d KiB is not 0x%x; first bytes: %s\n' "$1" \
			$(($3 / KB)) $(($2 / KB)) "$4" \
			"$(sudo dd if="$f" bs=4096 skip=$(($2 / 4096)) count=1 2>/dev/null | od -An -tx1 -N8 | tr -s ' ')"
		rc=1
	fi
}

if [ "$MODE" = write ]; then
	setparam tau_home 1
	setparam tau_home_nowait "${HOME_NOWAIT:-0}"
	setparam tau_home_norevoke 0
	mkfs_mount "$FS"
	case "$CASE" in
	basic)
		h0=$(probe home_blocks); j0=$(probe jwrite_blocks)
		echo "== 160 MiB of 0xC1, new: more than a 128 MiB segment of room, given back at the close =="
		for i in $(seq 0 39); do
			sudo "$TAUWRITE_NOFSYNC" "$A" $((4 * MB)) $((0xC1)) $((i * 4 * MB)) >/dev/null || die "write"
		done
		sudo "$TAUWRITE" "$A" 4096 $((0xC1)) 0 >/dev/null || die "fsync"
		h1=$(probe home_blocks); j1=$(probe jwrite_blocks)
		echo "  home_blocks +$((h1 - h0)), jwrite_blocks +$((j1 - j0))"
		[ $((h1 - h0)) -ge 40960 ] || fail "only $((h1 - h0)) of 40960 new blocks went home"
		[ $((j1 - j0)) -lt 1024 ] || fail "$((j1 - j0)) journal blocks for a commit of new blocks"
		echo "== 4 MiB of 0xC2 over the start =="
		sudo "$TAUWRITE" "$A" $((4 * MB)) $((0xC2)) 0 >/dev/null || die "overwrite"
		h2=$(probe home_blocks); j2=$(probe jwrite_blocks)
		echo "  home_blocks +$((h2 - h1)), jwrite_blocks +$((j2 - j1))"
		[ $((h2 - h1)) -eq 0 ] || fail "an overwrite went home"
		[ $((j2 - j1)) -ge 1024 ] || fail "the overwrite was not journaled"
		echo "== B: 4 MiB of 0xC3, new; one tx of 4 MiB of 0xC4 over it and 4 MiB of 0xC5 appended =="
		sudo "$TAUWRITE" "$B" $((4 * MB)) $((0xC3)) 0 >/dev/null || die "B"
		setparam tau_max_transaction_age 1	# B's tx checkpointed 1 s after commit
		h3=$(probe home_blocks); j3=$(probe jwrite_blocks); d0=$(probe tx_dropped)
		sudo "$TAUWRITE_NOFSYNC" "$B" $((4 * MB)) $((0xC4)) 0 >/dev/null || die "B overwrite"
		sudo "$TAUWRITE" "$B" $((4 * MB)) $((0xC5)) $((4 * MB)) >/dev/null || die "B append"
		h4=$(probe home_blocks); j4=$(probe jwrite_blocks)
		echo "  home_blocks +$((h4 - h3)), jwrite_blocks +$((j4 - j3))"
		[ $((h4 - h3)) -ge 1024 ] && [ $((j4 - j3)) -ge 1024 ] || fail "B's tx is not one of both"
		for i in $(seq 1 30); do
			[ $(( $(probe tx_dropped) - d0 )) -ge 1 ] && break
			sleep 1
		done
		echo "  checkpointed and dropped after ${i}s: $(( $(probe tx_dropped) - d0 ))"
		[ $(( $(probe tx_dropped) - d0 )) -ge 1 ] || fail "B's tx was not checkpointed"
		;;
	race)
		setparam tau_inject_delay_ms 8000
		w0=$(probe home_wait); i0=$(probe home_inplace)
		echo "== 8 KiB of 0xD1, new; its fsync's commit held 8 s before it writes =="
		pw "$A" 0 8192 0xD1 >/dev/null || die "write"
		setparam tau_inject_delay $((1 << 2))	# TAU_DELAY_MAPPED
		pw "$A" 0 0 0 fsync > "$HOME/home-fsync.ms" &
		fpid=$!
		sleep 2
		echo "== the same 8 KiB, 0xD2, while that commit waits =="
		ms=$(pw "$A" 0 8192 0xD2) || die "rewrite"
		wait $fpid || die "fsync"
		setparam tau_inject_delay 0
		w1=$(probe home_wait); i1=$(probe home_inplace)
		echo "  rewrite took $ms ms (the fsync $(cat "$HOME/home-fsync.ms") ms); home_wait +$((w1 - w0)), home_inplace +$((i1 - i0))"
		[ $((w1 - w0)) -ge 1 ] && [ "$ms" -ge 4000 ] || fail "the rewrite did not wait for the commit"
		[ $((i1 - i0)) -eq 0 ] || fail "the rewrite went in place over a block going home"
		pw "$A" 0 0 0 fsync >/dev/null || die "fsync"
		;;
	reuse)
		setparam tau_max_transaction_age 120
		setparam tau_cp_small_tx 0
		echo "== T1: X (64 KiB at 0) and Y (64 KiB at 1 MiB) of 0xE1, new =="
		sudo "$TAUWRITE_NOFSYNC" "$A" $((64 * KB)) $((0xE1)) 0 >/dev/null || die "X"
		sudo "$TAUWRITE" "$A" $((64 * KB)) $((0xE1)) $((1 * MB)) >/dev/null || die "Y"
		j0=$(probe jwrite_blocks)
		echo "== T2: both again, 0xE2 -- journaled, kept by Y =="
		sudo "$TAUWRITE_NOFSYNC" "$A" $((64 * KB)) $((0xE2)) 0 >/dev/null || die "X"
		sudo "$TAUWRITE" "$A" $((64 * KB)) $((0xE2)) $((1 * MB)) >/dev/null || die "Y"
		[ $(( $(probe jwrite_blocks) - j0 )) -ge 32 ] || fail "T2 was not journaled"
		pblocks "$A" 0 16 > "$MAP"
		echo "== punch X; the host has it =="
		r0=$(probe hold_released)
		punch "$A" 0 $((64 * KB)) || die "punch"
		logforce
		for i in $(seq 0 30); do
			[ $(( $(probe hold_released) - r0 )) -ge 1 ] && break
			sleep 1
		done
		[ $(( $(probe hold_released) - r0 )) -ge 1 ] || die "the punch's hold never let go"
		h0=$(probe home_blocks)
		echo "== T4: X again, 0xE3, into the hole: home =="
		sudo "$TAUWRITE" "$A" $((64 * KB)) $((0xE3)) 0 >/dev/null || die "X"
		[ $(( $(probe home_blocks) - h0 )) -ge 16 ] || fail "X did not go home"
		over=$(pblocks "$A" 0 16 | grep -cxFf "$MAP")
		echo "  X got $over of its 16 blocks back"
		[ "$over" -gt 0 ] || { echo "INCONCLUSIVE: X got none of its blocks back"; exit 3; }
		;;
	esac
	[ "$(kernel_faults)" = 0 ] || { show_kernel_faults; fail "kernel faults"; }
	warnings || fail "kernel warnings"
	[ $rc -eq 0 ] && echo "== written; power cut next ==" || echo "== write phase failed =="
	exit $rc
fi

# verify
setparam tau_home_norevoke "${HOME_NOREVOKE:-0}"
mount_tau "$FS"
sudo dmesg | grep -aE 'TAU: (replay done|ino [0-9]+: replaying)' | tail -4 | sed 's/^/  /'
case "$CASE" in
basic)
	expect_range start 0 $((4 * MB)) 0xC2
	expect_range rest $((4 * MB)) $((156 * MB)) 0xC1
	expect_range B-over 0 $((4 * MB)) 0xC4 "$B"
	expect_range B-append $((4 * MB)) $((4 * MB)) 0xC5 "$B"
	[ "$(stat -c %s "$B")" = $((8 * MB)) ] || { echo "  FAIL B is $(stat -c %s "$B") bytes"; rc=1; }
	;;
race)
	expect_range page 0 8192 0xD2
	;;
reuse)
	expect_range X 0 $((64 * KB)) 0xE3
	expect_range Y $((1 * MB)) $((64 * KB)) 0xE2
	;;
esac
setparam tau_home_norevoke 0
[ "$(kernel_faults)" = 0 ] || { show_kernel_faults; rc=1; }
warnings || rc=1
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
