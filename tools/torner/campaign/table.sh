#!/bin/bash
# Host side of the atomicity table (paper §6.2): boot the Torner VM on a kernel
# tree, run campaign/table_guest.sh there over CELLS, pull table.csv and the
# captures back, power the VM off.
#
#   usage: table.sh <kernel tree> <out dir>
#   env:   CELLS (required), PROFILES, LIMIT_ATOM, LIMIT_EPOCH, PREFER_SPLIT,
#          CAP_PARAM, TAU_SEG, MKFS_OPTS, TAG -- passed to table_guest.sh
#          PORT [5556], GDB_PORT [1236], NAME [table]: two calls with different
#          ones run side by side; DEADLINE_MIN [600]; MEM [16G]
#          ZFS_KIT: build_zfs.sh's kit (spl/zfs modules for the basevm kernel,
#          the noble userland they match), for the zfs-* configs
#          BASE: a copy of tautest's qemu-image.qcow2 to put the overlay on
#
# Kernels: the tau columns boot the kernel tree's test-config build (dm-log-
# writes a module, loaded from the tree; the control switches need its
# TAU_PROBE_TORN); the baseline columns boot build_basevm.sh's build, where
# dm-log-writes is built in.  The VM's root is a fresh overlay on tautest's
# qemu-image.qcow2 (it cannot boot while a tautest VM runs) or on BASE, a copy
# of it taken while no VM ran (a tautest VM may then run beside); its scratch
# disk a sparse file on the PM1753, deleted at the end like the overlay.
# The guest gets the host's Torner tree (built there) and the current tau forks;
# the source disk run_vm_torner.sh attaches (vdb) is not used.
set -u
TC=$(cd "$(dirname "$0")" && pwd); TR=$(cd "$TC/.." && pwd); R=$(cd "$TR/../.." && pwd)
V=$R/tools/qemu/vm_imgs
die() { echo "table.sh: $*" >&2; exit 1; }
KD=$(cd "${1:?usage: table.sh <kernel tree> <out dir>}" && pwd) || exit 1
OUT=$(realpath -m "${2:?usage: table.sh <kernel tree> <out dir>}")
CELLS=${CELLS:?CELLS is required}
PORT=${PORT:-5556}; GDB_PORT=${GDB_PORT:-1236}; NAME=${NAME:-table}
SCR=${SCRATCH_DIR:-/mnt/tau_backup/torner-scratch}
O="-i $HOME/.ssh/tau_vm_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
   -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=30"
g() { ssh -p $PORT $O jhlee@localhost "$@"; }

KV=$(strings "$KD/arch/x86/boot/bzImage" 2>/dev/null | grep -m1 '^6\.8\.0')
B=$(echo "$KV" | grep -oE '#[0-9]+')
[ -n "$B" ] || die "no bzImage in $KD"
KO=""
if grep -q '^CONFIG_DM_LOG_WRITES=m' "$KD/.config"; then
	KO=$KD/drivers/md/dm-log-writes.ko
	[ -f "$KO" ] || die "$KO missing"
fi
pgrep -f "hostfwd=tcp::$PORT-:22" >/dev/null && die "a VM already listens on ssh $PORT"
# a tautest VM writes the base image the overlay sits on, unless BASE is a copy
BASE=${BASE:-qemu-image.qcow2}
if [ "$BASE" = qemu-image.qcow2 ]; then
	pgrep -af qemu-system | grep -qE 'file=[^,]*qemu-image\.qcow2,' && die "a tautest VM is running"
else
	[ -f "$BASE" ] || die "no base image $BASE"
fi
mkdir -p "$OUT" "$SCR" || exit 1
exec > >(tee -a "$OUT/table.log") 2>&1
OV=$V/$NAME-overlay.qcow2; SD=$SCR/$NAME-scratch.raw
rm -f "$OV" "$SD"
(cd $V && qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$OV") || exit 1

echo "===== boot $(date '+%F %T')  $KV"
echo "cells: $CELLS"
echo "base: $BASE"
INITRD=$V/initrd.img-6.8.0tjournal+ ROOTFS=$OV SCRATCH=$SD SCRATCH_SIZE=24G \
	SSH_PORT=$PORT GDB_PORT=$GDB_PORT TAUFS_KERNEL=$KD MEM=${MEM:-16G} \
	sg kvm -c "bash $R/tools/qemu/run_vm_torner.sh" > "$OUT/console.log" 2>&1 < /dev/null &
qpid=$!
# whatever ends the run, the VM goes down and its overlay and scratch go away
down() {
	timeout 30 ssh -p $PORT $O jhlee@localhost "sudo poweroff" 2>/dev/null
	for i in $(seq 90); do kill -0 $qpid 2>/dev/null || break; sleep 2; done
	kill -0 $qpid 2>/dev/null && { echo "qemu still up: killing it"; pkill -f "hostfwd=tcp::$PORT-:22"; sleep 3; }
	pgrep -f "hostfwd=tcp::$PORT-:22" >/dev/null || rm -f "$OV" "$SD"
}
trap down EXIT
for i in $(seq 90); do timeout 20 ssh -p $PORT $O jhlee@localhost true 2>/dev/null && break; sleep 5; done
v=$(g "uname -v") || die "no ssh to the VM"
[[ "$v" == "$B "* ]] || die "guest is $v, not $B"

# the host's Torner tree, the current tau forks, and the stock e2fsprogs and
# xfsprogs the performance baselines are made with (the guest has no xfsprogs)
tar -C "$R/tools" -czf - --exclude='torner/src/*.o' --exclude=torner/torner \
	--exclude=torner/results torner | g "rm -rf ~/torner && tar -C ~ -xzf -" || die "copy torner"
F=$R/codes
scp -q -P $PORT $O $F/e2fsprogs/misc/mke2fs $F/e2fsprogs/misc/tune2fs $F/e2fsprogs/e2fsck/e2fsck \
	$F/xfsprogs-dev/mkfs/mkfs.xfs $F/xfsprogs-dev/repair/xfs_repair $F/xfsprogs-dev/db/xfs_db \
	${KO:+$KO} jhlee@localhost: || die "copy forks"
ST=$R/bench/workspace/stock
tar -C "$ST" -chzf - usr/sbin/mke2fs usr/sbin/e2fsck usr/sbin/tune2fs usr/sbin/xfs_db \
	sbin/mkfs.xfs sbin/xfs_repair etc/mke2fs.conf |
	g "rm -rf ~/stock && mkdir ~/stock && tar -C ~/stock -xzf -" || die "copy stock tools"
if [ -n "${ZFS_KIT:-}" ]; then
	[ -f "$ZFS_KIT/zfs.ko" ] || die "no zfs.ko in $ZFS_KIT"
	tar -C "$ZFS_KIT" -czf - . | g "rm -rf ~/zfs-kit && mkdir ~/zfs-kit && tar -C ~/zfs-kit -xzf -" ||
		die "copy zfs kit"
fi
g "KO=${KO:+\$HOME/dm-log-writes.ko} bash -s" > "$OUT/setup.log" 2>&1 <<'EOF'
set -eu
if [ -n "$KO" ]; then
	lsmod | grep -q '^dm_log_writes' || sudo insmod "$KO"
fi
sudo dmsetup targets | grep log-writes
# the zfs kit goes into the overlay, which the run throws away: no dpkg, so no
# postinst starting services or modprobing a module the guest has no tree for
if [ -d ~/zfs-kit ]; then
	sudo insmod ~/zfs-kit/spl.ko && sudo insmod ~/zfs-kit/zfs.ko
	sudo cp -a ~/zfs-kit/root/lib/x86_64-linux-gnu/. /usr/local/lib/ && sudo ldconfig
	sudo cp -a ~/zfs-kit/root/sbin/. /usr/local/sbin/
	sudo ln -sf /usr/local/sbin/mount.zfs /sbin/mount.zfs
	sudo mkdir -p /etc/zfs
	sudo /usr/local/sbin/zfs version
fi
sudo mkdir -p /mnt/scratch
sudo /sbin/mkfs.ext4 -qF /dev/vda && sudo mount /dev/vda /mnt/scratch
sudo chown jhlee:jhlee /mnt/scratch
mkdir -p /mnt/scratch/bin /mnt/scratch/stock/bin /mnt/scratch/stock/etc
mv ~/mke2fs ~/tune2fs ~/e2fsck ~/mkfs.xfs ~/xfs_repair ~/xfs_db /mnt/scratch/bin/
ln -sf mke2fs /mnt/scratch/bin/mkfs.ext4
mv ~/stock/usr/sbin/* ~/stock/sbin/* /mnt/scratch/stock/bin/
mv ~/stock/etc/mke2fs.conf /mnt/scratch/stock/etc/
ln -sf mke2fs /mnt/scratch/stock/bin/mkfs.ext4
cd ~/torner && make -s -j8 2>&1 | tail -3 && ls -l torner | cut -c1-60
for t in mkfs.ext4 mkfs.xfs e2fsck xfs_repair; do
	echo "$t: tau $(PATH=/mnt/scratch/bin command -v $t), baseline $(PATH=/mnt/scratch/stock/bin command -v $t)"
done
/mnt/scratch/stock/bin/mkfs.xfs -V; /mnt/scratch/stock/bin/mke2fs -V 2>&1 | head -1
cat /sys/block/vda/queue/write_cache
df -h /mnt/scratch | tail -1
EOF
rc=$?; cat "$OUT/setup.log"; [ $rc = 0 ] || die "guest setup failed"

g "setsid nohup env CELLS='$CELLS' PROFILES='${PROFILES:-quiet busy}' \
	LIMIT_ATOM=${LIMIT_ATOM:-1000} LIMIT_EPOCH=${LIMIT_EPOCH:-1000} \
	PREFER_SPLIT=${PREFER_SPLIT:-0} CAP_PARAM='${CAP_PARAM:-}' TAU_SEG='${TAU_SEG:-2m}' \
	MKFS_OPTS='${MKFS_OPTS:-}' \
	TAG='${TAG:-}' bash ~/torner/campaign/table_guest.sh > /mnt/scratch/table_guest.log 2>&1 < /dev/null &"
deadline=$(( $(date +%s) + ${DEADLINE_MIN:-600} * 60 ))
while :; do
	sleep 30
	timeout 60 ssh -p $PORT $O jhlee@localhost "cat /mnt/scratch/table_guest.log" \
		> "$OUT/table_guest.log.new" 2>/dev/null && mv "$OUT/table_guest.log.new" "$OUT/table_guest.log"
	grep -q "^===== done" "$OUT/table_guest.log" 2>/dev/null && break
	[ "$(date +%s)" -lt $deadline ] || { echo "DEADLINE: the guest did not finish"; break; }
done

echo "===== pull $(date +%T)"
g "cd /mnt/scratch && bash -O nullglob -c 'sudo tar -cSf - table.csv cap-* *.log *.dmesg'" |
	tar -C "$OUT" -xSf - || echo "pull: tar failed"
du -sh "$OUT"
echo "===== done $(date '+%F %T'): $OUT/table.csv"
grep -q "^===== done" "$OUT/table_guest.log" 2>/dev/null
