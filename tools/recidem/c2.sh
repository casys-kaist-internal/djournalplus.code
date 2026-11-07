#!/bin/bash
# c2: does τ keep one file's writes in order across a background commit? A deterministic VM repro of
# an ordering question about bimodal journaling (libra09, 2026-11-07), for EVAL_PLAN's oracle C2
# ("the recovered state is a prefix of the file's write sequence").
#
# The suspected path, read in a6d55fe7:
#   - Overwriting a block whose newest copy is durable only in the journal (τRedo) writes it in place
#     and records a revoke "at the next user commit" (tau_do_get_write_access, tau_record_revoke).
#   - A background commit leaves pending revokes behind (`take_tags = tcc->user` in tau_commit_begin).
#   - So a later write of another page can commit while the in-place one still depends on its revoke.
#     A crash then replays the old journal copy over the in-place page.
#
# Per trial, on a fresh τ file system (tools/recidem/c2_guest.py; pages Y and X of one O_TAU_UNTORN file):
#   init: Y = A, X = P, fsync; umount + mount so that both are home and clean
#   W0 Y = B + fsync (Y is now τRedo), W1 Y = C, W2 X = Q, all on one open fd; then by variant:
#     bg      no fsync, wait WAIT_S for a background commit, kill qemu
#     fsync   fsync after W2 (the control), wait WAIT_S, kill
#     nowait  no fsync, kill at once
#   boot again, mount (recovery), read Y and X
# Verdicts. Prefix states: (B,P), (C,P), (C,Q). Then:
#   (B,Q)        INVERSION: W2 survived and W1 did not
#   A in Y       W0 lost after its fsync (C3)
#   ? anywhere   a mixed page (C1)
# Usage: c2.sh [out dir]   env FSES ("ext4-tau xfs-tau"), VARIANTS ("bg fsync nowait"), REPEAT (3),
#        WAIT_S (20). Its own ssh port (5560), image and overlay, so it can run beside nth.sh.
# Parsed whole first.
{
SELF=$(realpath "$0")
R=/home/jhlee/codes/djournalplus.code; T=$R/tools/recidem; V=$R/tools/qemu/vm_imgs
cd $R || exit 1
unset TAU_TARGET_DISK; source set_env.sh > /dev/null; source bench/scripts/common.sh > /dev/null; set +e
set -u
FSES=${FSES:-ext4-tau xfs-tau} VARIANTS=${VARIANTS:-bg fsync nowait} REPEAT=${REPEAT:-3} WAIT_S=${WAIT_S:-20}
KD=$R/codes/djournalplus-kernel.code
KV=$(strings $KD/arch/x86/boot/bzImage | grep -m1 '^6\.8\.0tjournal')
BUILD=$(echo "$KV" | grep -oE '#[0-9]+' | tr -d '#')
INITRD=${INITRD:-$V/initrd.img-6.8.0tjournal+-$BUILD}
BASE=${BASE:-$V/cm-guest-ubuntu.qcow2}
OUT=$(realpath -m "${1:-$R/bench/workspace/results/libra09/correctness/c2_$(date -u +%Y%m%d_%H%M%S)}")
IMGDIR=${IMGDIR:-/mnt/recidem}
PORT=5560 GDB=1240
O="-i $HOME/.ssh/tau_vm_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
   -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=10"
g() { ssh -p $PORT $O jhlee@localhost "$@" < /dev/null; }
die() { echo "c2: $*"; exit 1; }
[ -f "$INITRD" ] || die "no initrd $INITRD for build #$BUILD"
mountpoint -q "$IMGDIR" || die "$IMGDIR is not mounted (tools/recidem/run.sh makes it)"
pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null && die "a VM on port $PORT is running"
mkdir -p "$OUT" || exit 1
exec > >(tee -a "$OUT/run.log") 2>&1
cp "$SELF" "$T/c2_guest.py" "$OUT/"
echo "c2 $(date -u --rfc-3339=seconds): kernel $KV; $FSES; variants $VARIANTS x $REPEAT; wait ${WAIT_S}s"

QPID=
boot() {  # <disk image> <console log>
  rm -f "${IMGDIR:?}/c2-ov.qcow2"
  qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$IMGDIR/c2-ov.qcow2" || return 1
  INITRD=$INITRD ROOTFS=$IMGDIR/c2-ov.qcow2 SCRATCH=$1 SSH_PORT=$PORT GDB_PORT=$GDB TAUFS_KERNEL=$KD MEM=8G CORES=4 \
    sg kvm -c "bash $R/tools/qemu/run_vm_torner.sh" > "$2" 2>&1 < /dev/null &
  QPID=$!
  local i
  for i in $(seq 80); do timeout 10 ssh -p $PORT $O jhlee@localhost true < /dev/null 2> /dev/null && break; sleep 3; done
  g "mkdir -p ~/c2" && scp -q -P $PORT $O "$T/c2_guest.py" jhlee@localhost:c2/ < /dev/null
}
vm_kill() { pkill -KILL -f "hostfwd=tcp::$PORT-:22"; wait $QPID 2> /dev/null; QPID=; }
vm_off() {
  timeout 30 ssh -p $PORT $O jhlee@localhost "sudo poweroff" < /dev/null > /dev/null 2>&1
  local i; for i in $(seq 40); do pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null || break; sleep 2; done
  pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null && vm_kill
  wait $QPID 2> /dev/null; QPID=
}
mnt() {  # <fs>
  local o
  case $1 in ext4-tau) o="-t ext4 -o tjournal,tjournal_size=1" ;; xfs-tau) o="-t xfs -o tjournal,tjournal_size=1" ;; esac
  g "sudo mkdir -p /mnt/c2 && sudo mount $o /dev/vda /mnt/c2 && sudo chmod 777 /mnt/c2"
}

printf '%-9s %-7s %-4s %-8s %-8s %s\n' fs variant rep Y X verdict | tee "$OUT/results.txt"
for fs in $FSES; do
  for variant in $VARIANTS; do
    for rep in $(seq "$REPEAT"); do
      P=$OUT/$fs.$variant.$rep I=$IMGDIR/c2-$fs.img
      rm -f "${I:?}"; truncate -s 8G "$I"
      case $fs in
        ext4-tau) tau_mke2fs -q -t ext4 -E lazy_itable_init=0,lazy_journal_init=0 -F "$I" > /dev/null ;;
        xfs-tau)  tau_mkfs_xfs -q -f -l tjmaxsize=1G "$I" > /dev/null ;;
      esac
      boot "$I" "$P.1.console" || { echo "$fs $variant $rep: boot failed"; vm_kill; continue; }
      mnt $fs && g "python3 ~/c2/c2_guest.py init" > /dev/null && g "sudo umount /mnt/c2" && mnt $fs \
        || { echo "$fs $variant $rep: init failed"; vm_kill; continue; }
      g "nohup python3 ~/c2/c2_guest.py scenario $variant > ~/c2/scenario.log 2>&1 &"
      for i in $(seq 100); do g "test -s ~/c2/ready" && break; sleep 0.2; done
      g "cat ~/c2/ready" > "$P.ready" 2> /dev/null
      [ -s "$P.ready" ] || { echo "$fs $variant $rep: the scenario did not start"; g "cat ~/c2/scenario.log"; vm_kill; continue; }
      [ $variant = nowait ] || sleep "$WAIT_S"
      vm_kill
      boot "$I" "$P.2.console" || { echo "$fs $variant $rep: reboot failed"; vm_kill; continue; }
      g "sudo dmesg -C"; mnt $fs || { echo "$fs $variant $rep: recovery mount failed"; vm_kill; continue; }
      g "sudo dmesg" > "$P.recovery.dmesg"
      rd=$(g "python3 ~/c2/c2_guest.py read")
      g "sudo umount /mnt/c2"; vm_off
      y=$(echo "$rd" | grep -oE 'Y=.' | cut -d= -f2); x=$(echo "$rd" | grep -oE 'X=.' | cut -d= -f2)
      case "$y$x" in
        BP) v="prefix (W0)" ;; CP) v="prefix (W1)" ;; CQ) v="prefix (W2)" ;;
        BQ) v="INVERSION: X has W2, Y lost W1" ;;
        A?) v="LOST W0 after its fsync (C3)" ;;
        *) v="UNEXPECTED ($rd)" ;;
      esac
      [[ $y == '?' || $x == '?' ]] && v="MIXED PAGE (C1): $rd"
      printf '%-9s %-7s %-4s %-8s %-8s %s\n' "$fs" "$variant" "$rep" "${y:--}" "${x:--}" "$v" | tee -a "$OUT/results.txt"
      rm -f "${I:?}"
    done
  done
done
rm -f "${IMGDIR:?}/c2-ov.qcow2"
echo "c2 done $(date -u --rfc-3339=seconds): $(grep -c 'INVERSION' "$OUT/results.txt") inversions in $(( $(wc -l < "$OUT/results.txt") - 1 )) trials"
exit
}
