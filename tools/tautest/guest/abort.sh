#!/bin/bash
# An aborted tau journal stops cleanly: writers get EIO without hanging, other
# files keep working, and umount + mount brings back every fsync (#22, #7).
# Layout: README.  usage: abort.sh <xfs|ext4> <site 1-6>
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; SITE=$2
P=/sys/module/tau_journal/parameters
ACK=$HOME/abort-ack
D=$TAU_MNT/d
FILES=4; PAGES=32768; SECS=60	# files still growing when the fault is armed (sites 5, 6)

# the writer runs under sudo: kill -0 would be refused, and a zombie still has /proc
running() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$st" ] && [ "${st:0:1}" != Z ]; }

sudo rm -rf "$ACK"; mkdir -p "$ACK"
echo 0 | sudo tee $P/tau_inject_fault >/dev/null
mkfs_mount "$FS"
sudo mkdir -p "$D"
sudo dmesg -C

sudo "$TAU_BIN/tauabort" run "$D" $FILES $PAGES $SECS "$ACK" > "$ACK/run.log" 2>&1 &
pid=$!
sleep 3
echo "$SITE" | sudo tee $P/tau_inject_fault >/dev/null
armed=$SECONDS

# the fault fires on the next pass through its site
while [ "$(cat $P/tau_inject_fault)" != 0 ] && running $pid; do
	sleep 1
done
if [ "$(cat $P/tau_inject_fault)" != 0 ]; then
	echo 0 | sudo tee $P/tau_inject_fault >/dev/null
	wait $pid
	echo "RESULT: INCONCLUSIVE (site $SITE never reached)"
	exit 3
fi
fired=$((SECONDS - armed))

# every writer must be gone within 30 s of the abort
rc=0
for i in $(seq 1 30); do
	running $pid || break
	sleep 1
done
if running $pid; then
	echo "  writers still running 30 s after the abort:"
	ps -eo pid,stat,wchan:32,comm | awk '$2 ~ /D/' | sed 's/^/    /'
	echo "RESULT: FAIL (hang)"
	exit 1
fi
wait $pid
wrc=$?
sed 's/^/  /' "$ACK/run.log"
sudo dmesg | grep -E "Tau-Journal .*aborting|EXT4-fs error|Remounting filesystem read-only|Aborting journal" |
	head -4 | sed 's/^/  /'
[ $wrc -eq 0 ] || { echo "  some writer did not stop on EIO (rc $wrc)"; rc=1; }
echo "  fault fired ${fired}s after arming"

# ext4 stops its own journal when the abort caught an allocation in flight
hostro=0
sudo dmesg | grep -q "tau journal aborted with a block allocation in flight" && hostro=1

# a new tau file is refused (EROFS first if the host went read-only)
sudo python3 -c 'import os, sys
ok = [5, 30] if sys.argv[2] == "1" else [5]
try:
    os.open(sys.argv[1], os.O_CREAT | os.O_RDWR | 0o40000000, 0o644)
except OSError as e:
    print("  new tau file: %s" % os.strerror(e.errno)); sys.exit(0 if e.errno in ok else 1)
print("  new tau file: opened"); sys.exit(1)' "$D/new" $hostro || rc=1

# other files: still writable unless the host journal was stopped
if sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
os.write(fd, b"x" * 4096); os.fsync(fd); os.close(fd)' "$TAU_MNT/plain" 2>/dev/null; then
	echo "  plain file: writable"
	[ $hostro -eq 0 ] || { echo "  ...though the host journal was aborted"; rc=1; }
else
	echo "  plain file: not writable"
	[ $hostro -eq 1 ] || rc=1
fi

sudo umount "$TAU_MNT" || { echo "RESULT: FAIL (umount)"; exit 1; }
echo "  umount done"
mount_tau "$FS"
sudo dmesg | grep -E "TAU: replay done" | tail -4 | sed 's/^/  /'
sudo "$TAU_BIN/tauabort" verify "$D" $FILES $PAGES "$ACK" | tail -12 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
warn=$(sudo dmesg | grep -c "WARNING: CPU")
[ "$warn" = 0 ] || { sudo dmesg | grep -A6 "WARNING: CPU" | head -20; rc=1; }
[ "$(kernel_faults)" = "0" ] || { show_kernel_faults; rc=1; }
sudo umount "$TAU_MNT" || rc=1
[ $rc -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
