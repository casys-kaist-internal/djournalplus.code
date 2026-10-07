#!/bin/bash
# fallocate / truncate range operations keep a tau file's data, at runtime and
# after a power cut (#36, #20, #26, unaligned truncate).
# Layout: README.  usage: range.sh <xfs|ext4> <case> write|verify
#   case: collapse | insert | zero | upunch | uzero | utrunc | extend
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; CASE=$2; MODE=$3
A=$TAU_MNT/a
P=/sys/module/tau_journal/parameters
R=$((4 * MB))

case "$CASE" in
collapse|insert|zero|upunch|uzero|utrunc|extend) ;;
*) die "usage: $0 <xfs|ext4> <collapse|insert|zero|upunch|uzero|utrunc|extend> write|verify" ;;
esac

probe() { cat $P/tau_probe_$1 2>/dev/null || echo 0; }

# a 1 GB journal: a tx is capped at a quarter of it, below the zeroing of 1 GiB
[ "$CASE" = extend ] && export TAU_MOUNT_OPTS=${TAU_MOUNT_OPTS:-tjournal,tjournal_size=1}

logforce() {
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x")
os.fsync(fd)
os.close(fd)' "$TAU_MNT/logforce" || die "log force"
}

# R0-R3 0x20-0x23 (TauRedo over 0x10-0x13 at home), R4 0x24 (not fsync'd)
layout() {
	case "$CASE" in
	collapse) echo "0x20:$R 0x22:$R 0x23:$R 0x24:$R" ;;
	insert)   echo "0x20:$R 0:$R 0x21:$R 0x22:$R 0x23:$R 0x24:$R" ;;
	zero)     echo "0x20:$R 0:$R 0x22:$R 0x23:$R 0x24:$R" ;;
	upunch|uzero) echo "0x20:$R 0x21:1000 0:10192 0x21:$((R - 11192)) 0x22:$R 0x23:$R 0x24:$R" ;;
	utrunc)   echo "0x20:$R 0x21:5000 0:$((R - 5000))" ;;
	extend)   echo "0x20:$R 0x21:$R 0x22:$R 0x23:$R 0x24:$R 0:$((1024 * MB - 5 * R))" ;;
	esac
}

check() {
	sudo python3 - "$A" "$1" $(layout) <<-'EOF'
		import sys, collections
		path, label, spec = sys.argv[1], sys.argv[2], sys.argv[3:]
		f = open(path, 'rb')
		bad, pos = [], 0
		for s in spec:
		    byte, n = (int(x, 0) for x in s.split(':'))
		    blocks, left = collections.Counter(), n
		    while left:
		        d = f.read(min(left, 16 << 20))
		        if not d:
		            break
		        if d != bytes([byte]) * len(d):
		            blocks.update(d[i] for i in range(0, len(d), 4096))
		        left -= len(d)
		    if blocks or left:
		        bad.append("[%d MiB +%d] want %#04x, %d short, blocks %s" % (pos >> 20, n,
		                   byte, left, " ".join("%#04x:%d" % kv for kv in sorted(blocks.items()))))
		    pos += n
		if f.read(1):
		    bad.append("longer than %d" % pos)
		print("  %s: %s" % (label, "FAIL (" + "; ".join(bad) + ")" if bad else "PASS"))
		sys.exit(1 if bad else 0)
	EOF
}

if [ "$MODE" = write ]; then
	echo 1 | sudo tee $P/tau_max_transaction_age >/dev/null
	mkfs_mount "$FS"
	c0=$(probe commits); d0=$(probe tx_dropped)
	for i in 0 1 2 3; do
		sudo "$TAUWRITE" "$A" $R $((0x10 + i)) $((i * R)) >/dev/null || die "T0"
	done
	for w in $(seq 1 20); do
		sleep 1
		[ $(( $(probe tx_dropped) - d0 )) -ge $(( $(probe commits) - c0 )) ] && break
	done
	echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
	for i in 0 1 2 3; do
		sudo "$TAUWRITE" "$A" $R $((0x20 + i)) $((i * R)) >/dev/null || die "T1"
	done
	sudo "$TAUWRITE_NOFSYNC" "$A" $R $((0x24)) $((4 * R)) >/dev/null || die "R4"

	h0=$(probe free_home); v0=$(probe free_revoke)
	echo "== $CASE =="
	case "$CASE" in
	collapse) sudo fallocate -c -o $R -l $R "$A" ;;
	insert)   sudo fallocate -i -o $R -l $R "$A" ;;
	zero)     sudo fallocate -z -o $R -l $R "$A" ;;
	upunch)   sudo fallocate -p -o $((R + 1000)) -l 10192 "$A" ;;
	uzero)    sudo fallocate -z -o $((R + 1000)) -l 10192 "$A" ;;
	utrunc)   sudo truncate -s $((R + 5000)) "$A" && sudo truncate -s $((2 * R)) "$A" ;;
	extend)   sudo fallocate -o 0 -l $((1024 * MB)) "$A" ;;
	esac || die "$CASE failed"
	echo "  written home $(( $(probe free_home) - h0 )), revoked $(( $(probe free_revoke) - v0 ))"
	check runtime || exit 1
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; exit 1; }
	sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
os.fsync(fd)
os.close(fd)' "$A" || die "fsync"
	logforce
	echo WRITTEN
else
	mount_tau "$FS"
	check recovered
	rc=$?
	[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
	sudo umount "$TAU_MNT" || rc=1
	exit $rc
fi
