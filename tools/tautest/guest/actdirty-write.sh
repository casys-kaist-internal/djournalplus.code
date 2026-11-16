#!/bin/bash
# Pages dirtied before activation (kernel taudocs/bug.md #68): blocks that held a
# deleted file's 0xAA, then 64 MiB of 0x55 written without O_TAU_UNTORN and no
# fsync, then an open with it, the directory fsync'd, time for the host's commit; ARMED.
#   usage: actdirty-write.sh <xfs|ext4>
cd "$(dirname "$0")" || exit 1
. ./common.sh
FS=${1:-}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <xfs|ext4>" ;; esac
STATUS_FILE=${STATUS_FILE:-$HOME/actdirty-status}
P=/sys/module/tau_journal/parameters
MB=$((1024 * 1024))
rm -f "$STATUS_FILE"
status() { echo "$*" > "$STATUS_FILE"; sync "$STATUS_FILE" 2>/dev/null; echo "== $* =="; }
probe() { cat "$P/tau_probe_$1" 2>/dev/null || echo 0; }

mkfs_mount "$FS"
echo "== X: 64 MiB of 0xAA, fsync'd, deleted =="
sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(64): os.write(fd, b"\xaa" * (1 << 20))
os.fsync(fd); os.close(fd)' "$TAU_MNT/x" || die "X failed"
sudo rm "$TAU_MNT/x"
sync
f0=$(probe act_flush); d0=$(probe act_dirty)
echo "== A: 64 MiB of 0x55, no O_TAU_UNTORN, no fsync =="
sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_WRONLY, 0o644)
for i in range(64): os.write(fd, b"\x55" * (1 << 20))
os.close(fd)' "$TAU_MNT/a" || die "A failed"
echo "== A opened with O_TAU_UNTORN =="
sudo python3 -c 'import os, sys
os.close(os.open(sys.argv[1], os.O_RDWR | 0o40000000))' "$TAU_MNT/a" || die "activation failed"
DIRTY=$(( $(probe act_dirty) - d0 ))
echo "  act_flush+$(( $(probe act_flush) - f0 )) act_dirty+$DIRTY"
sudo dmesg | grep -a "becomes a tau file with pages dirty" | tail -2 | sed 's/^/  /'
echo "== fsync of the directory: A's name durable, not its data =="
sudo python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)' "$TAU_MNT" || die "dir fsync failed"
echo "== idle 7 s: the host commits A's allocation =="
sleep 7
status "ARMED dirty=$DIRTY"
sleep 600
