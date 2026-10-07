#!/bin/bash
# A block that took write access but missed the transaction at write_end is
# not dropped silently: the folio is redone, so the write is in the fsync (#41).
# Fault site 7 makes one dirty_block() fail as if the block had left the tx.
# Layout: README.  usage: writeend.sh <xfs|ext4> write|verify
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; MODE=$2
P=/sys/module/tau_journal/parameters
A=$TAU_MNT/a

probe() { cat $P/tau_probe_$1 2>/dev/null || echo 0; }

case "$MODE" in
write)
	echo 0 | sudo tee $P/tau_inject_fault >/dev/null
	mkfs_mount "$FS"
	sudo dmesg -C
	echo "== A: 8 MiB of 0xA1, fsync =="
	sudo "$TAUWRITE" "$A" $((8 * MB)) $((0xA1)) >/dev/null || die "A"
	r0=$(probe wr_end_redo)
	# an overwrite (in place, revoke tag) and an append (journaled)
	for off in 1 8; do
		echo "== fault 7 armed: 64 KiB of 0xB2 at $off MiB, fsync =="
		echo 7 | sudo tee $P/tau_inject_fault >/dev/null
		sudo "$TAUWRITE" "$A" $((64 * 1024)) $((0xB2)) $((off * MB)) >/dev/null ||
			die "the write failed"
		[ "$(cat $P/tau_inject_fault)" = 0 ] ||
			{ echo 0 | sudo tee $P/tau_inject_fault >/dev/null; die "fault 7 never fired"; }
	done
	echo "== redone folios: $(( $(probe wr_end_redo) - r0 )) =="
	# WEND_CONTROL=1: a kernel with the redo taken out, which must then fail verify
	[ -n "${WEND_CONTROL:-}" ] || [ $(( $(probe wr_end_redo) - r0 )) -ge 2 ] ||
		die "no folio was redone"
	echo WRITTEN
	;;
verify)
	mount_tau "$FS"
	rc=0
	sudo python3 - "$A" <<-'EOF' || rc=1
		import sys
		d = open(sys.argv[1], 'rb').read()
		MB = 1 << 20
		want = bytearray(b'\xa1' * (8 * MB) + b'\0' * 65536)
		for off in (1, 8):
		    want[off * MB:off * MB + 65536] = b'\xb2' * 65536
		bad = [i for i in range(0, len(want), 4096) if d[i:i + 4096] != want[i:i + 4096]]
		if len(d) != len(want) or bad:
		    print("  A: size %d, %d blocks wrong, first at %s" %
		          (len(d), len(bad), bad[0] if bad else "-"))
		    sys.exit(1)
		print("  A: both 64 KiB writes and the rest intact")
	EOF
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	sudo umount "$TAU_MNT" || rc=1
	[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
	exit $rc
	;;
*)
	die "usage: $0 <xfs|ext4> write|verify"
	;;
esac
