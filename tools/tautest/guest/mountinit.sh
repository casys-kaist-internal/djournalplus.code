#!/bin/bash
# Mount-time journal setup.  race: journald takes its first look before the
# mount has backed a journal segment (bug.md #66) -- it must wait, not oops.
# initfail: the mount cannot back one (#67) -- the mount fails cleanly and the
# FS mounts afterwards, plain and tjournal, with its data.
# Layout: README.  usage: mountinit.sh <xfs|ext4> race|initfail
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; PART=$2
P=/sys/module/tau_journal/parameters
A=$TAU_MNT/a
R=$((4 * MB))
OOPS='divide error|Oops|general protection|kernel BUG|BUG: |WARNING: |soft lockup|blocked for more than'
DELAY_JOURNALD=5	# TAU_DELAY_JOURNALD
DELAY_INIT_BLOCKS=6	# TAU_DELAY_INIT_BLOCKS
FAULT_INIT_BLOCKS=9	# TAU_FAULT_INIT_BLOCKS

[ -e $P/tau_inject_delay ] || die "tau_inject_delay: this test needs CONFIG_TAU_PROBE_TORN=y"

oopses() { sudo dmesg | grep -cE "$OOPS" || true; }
mark() { echo "mountinit: $*" | sudo tee /dev/kmsg >/dev/null; }

# fails, and returns, if the count rose: what follows could hang on a dead journald
no_new_faults() {
	local n=$(( $(oopses) - $1 ))

	[ "$n" -eq 0 ] && { echo "  no kernel fault: PASS"; return 0; }
	echo "  no kernel fault: FAIL ($n)"
	sudo dmesg | grep -E "$OOPS" -A4 | head -24
	return 1
}

# umount, giving up after <seconds>: a dead journald keeps it waiting forever
umount_within() {
	local pid s t=0

	sudo umount "$TAU_MNT" &
	pid=$!
	while :; do
		s=$(cut -d' ' -f3 /proc/$pid/stat 2>/dev/null)
		[ -z "$s" ] || [ "$s" = Z ] && break
		[ $t -ge $(($1 * 10)) ] && return 1
		sleep 0.1
		t=$((t + 1))
	done
	wait $pid
}

# a tau file, fsync'd, on a fresh FS left unmounted
prepare() {
	mkfs_mount "$FS"
	sudo "$TAUWRITE" "$A" $R $((0x41)) >/dev/null || die "tauwrite"
	sudo umount "$TAU_MNT" || die "umount"
	want=$(md5_of_repeat $((0x41)) $R)
}

# the mounted FS still works: the data, a tau write, an unmount
still_works() {
	expect_md5 "$1" "$A" "$want" || rc=1
	sudo "$TAUWRITE" "$A" $R $((0x42)) >/dev/null ||
		{ echo "  tau write: FAIL"; rc=1; }
	if umount_within 30; then
		echo "  umount: PASS"
	else
		echo "  umount: FAIL (still waiting after 30 s)"
		exit 1
	fi
}

rc=0
case "$PART" in
race)
	echo "== $FS: journald looks before the mount backs a segment (#66) =="
	prepare
	base=$(oopses)
	# journald looks as soon as the map is set; the mount then holds 5 s before its segments
	echo 5000 | sudo tee $P/tau_inject_delay_ms >/dev/null
	echo $(( (1 << DELAY_JOURNALD) | (1 << DELAY_INIT_BLOCKS) )) |
		sudo tee $P/tau_inject_delay >/dev/null
	mark "race mount"
	if ! sudo mount -t "$FS" -o "${TAU_MOUNT_OPTS:-tjournal}" "$TAU_DEV" "$TAU_MNT"; then
		echo "  race mount: FAIL"
		sudo dmesg | sed -n '/mountinit: race mount/,$p' | grep -vE '^\s+[?a-z_]+\+0x|^\s*<' | head -40 | sed 's/^/    /'
		exit 1
	fi
	sleep 2		# journald's delay is over and its first rounds ran
	left=$(cat $P/tau_inject_delay)
	[ "$left" = 0 ] || { echo "  FAIL: delay sites not reached (mask $left left)"; rc=1; }
	log=$(sudo dmesg | sed -n '/mountinit: race mount/,$p')
	echo "$log" | grep -E 'injected delay|tau_journald\] started|divide error' | sed 's/^/    /'
	backed=$(echo "$log" | grep -n "injected delay at site $DELAY_INIT_BLOCKS done" | head -1 | cut -d: -f1)
	started=$(echo "$log" | grep -n 'tau_journald\] started' | head -1 | cut -d: -f1)
	if [ -n "$backed" ] && [ -n "$started" ] && [ "$started" -gt "$backed" ]; then
		echo "  journald waits for the segments: PASS"
	else
		echo "  journald waits for the segments: FAIL (journald at line ${started:-none}, segments at ${backed:-none})"
		rc=1
	fi
	no_new_faults "$base" || exit 1
	still_works data
	;;
initfail)
	echo "== $FS: the mount cannot back a journal segment (#67) =="
	prepare
	base=$(oopses)
	echo $FAULT_INIT_BLOCKS | sudo tee $P/tau_inject_fault >/dev/null
	if sudo mount -t "$FS" -o "${TAU_MOUNT_OPTS:-tjournal}" "$TAU_DEV" "$TAU_MNT" 2>/dev/null; then
		# with #67 the sb's sbi is already freed: touch nothing more
		echo "  tjournal mount fails: FAIL (it mounted)"
		exit 1
	fi
	if [ "$(cat $P/tau_inject_fault)" = 0 ]; then
		echo "  tjournal mount fails: PASS"
	else
		echo "  tjournal mount fails: FAIL (fault site not reached)"
		echo 0 | sudo tee $P/tau_inject_fault >/dev/null
		rc=1
	fi
	no_new_faults "$base" || exit 1
	sudo mount -t "$FS" "$TAU_DEV" "$TAU_MNT" || die "plain mount after the failed one"
	expect_md5 plain "$A" "$want" || rc=1
	sudo umount "$TAU_MNT" || die "umount"
	mount_tau "$FS"
	still_works tau
	no_new_faults "$base" || rc=1
	;;
*)
	die "usage: $0 <xfs|ext4> race|initfail"
	;;
esac
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
