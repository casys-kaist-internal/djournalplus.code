#!/bin/bash
# recidem: is τ's mount-time journal replay idempotent? EVAL_PLAN T3 #9 ("a crash during
# recovery: the second recovery must give what a completed first one gives"), approximated by
# VM kills instead of a kernel fault-injection hook (libra09, 2026-11-06).
#
# Per crash state: a fresh τ FS on a file-backed virtio disk (tools/qemu/run_vm_torner.sh,
# cache=writeback: a kill loses the requests in flight, the completed ones stay) takes atomicw
# overwrites of τ files (O_TAU_UNTORN, 16 KiB pages, an fdatasync every BATCH pages) until qemu is
# killed at a random time, by default after the journal has filled (so that much is left to
# replay). The image is copied:
#   A   mounted once: the replay runs to the end (its time T), then the data files' sha256 and
#       sizes, umount, fsck (the τ forks, on the host)
#   B   for each kill fraction f: mounted and killed f*T into the mount, mounted again, then the
#       same sha256/sizes and fsck
# A trial passes when B's files equal A's and both fsck runs are clean. "mid" says whether the
# first B mount was still running when the kill came (else the kill missed the replay).
#
# Usage: run.sh [out dir]
#   env: FSES ("ext4-tau xfs-tau"), STATES (5), FRACS ("0.25 0.5 0.75"), DISK_GB (256), FILES (64),
#        DATA_GB (96), JOURNAL_GB (32), THREADS (64), BATCH (64), LOAD_S (60), KILL_MIN_S (40),
#        IMGDIR (/mnt/recidem: a file system on the test device made here; the images live there),
#        SEGSIZE (16m: τ journal segments; empty = the mkfs default, 128 MiB),
#        KD (the umbrella's codes/djournalplus-kernel.code: the kernel tree the guest boots)
# Guest: an overlay on vm_imgs/cm-guest-ubuntu.qcow2 per boot, the tree's bzImage and the initrd of
# its build (vm_imgs/initrd.img-6.8.0tjournal+-<build>). Parsed whole first.
{
R=$(cd "$(dirname "$(realpath "$0")")/../.." && pwd); T=$R/tools/recidem; V=$R/tools/qemu/vm_imgs
cd $R || exit 1
unset TAU_TARGET_DISK; source set_env.sh > /dev/null; source bench/scripts/common.sh > /dev/null; set +e
set -u
FSES=${FSES:-ext4-tau xfs-tau} STATES=${STATES:-5} FRACS=${FRACS:-0.25 0.5 0.75}
DISK_GB=${DISK_GB:-256} FILES=${FILES:-64} DATA_GB=${DATA_GB:-96} JOURNAL_GB=${JOURNAL_GB:-32}
THREADS=${THREADS:-64} BATCH=${BATCH:-64} LOAD_S=${LOAD_S:-60} KILL_MIN_S=${KILL_MIN_S:-40}
# τ journal segments: 16 MiB, as the benches since the user's decision (가) of 11-08 (XFS then needs
# tjmaxsize=32G for the 32 GiB cap); SEGSIZE= (empty) gives the mkfs defaults, 128 MiB, as up to 11-08
SEGSIZE=${SEGSIZE-16m}
XL=tjmaxsize=1G; [ -n "$SEGSIZE" ] && XL=tjsegsize=$SEGSIZE,tjmaxsize=32G   # xfs-tau's -l
KD=${KD:-$R/codes/djournalplus-kernel.code}
KV=$(strings $KD/arch/x86/boot/bzImage | grep -m1 '^6\.8\.0tjournal')
BUILD=$(echo "$KV" | grep -oE '#[0-9]+' | tr -d '#')
INITRD=${INITRD:-$V/initrd.img-6.8.0tjournal+-$BUILD}
BASE=${BASE:-$V/cm-guest-ubuntu.qcow2}
AW=$R/bench/workspace/micro/atomicw
OUT=$(realpath -m "${1:-$R/bench/workspace/results/libra09/correctness/recidem_$(date -u +%Y%m%d_%H%M%S)}")
IMGDIR=${IMGDIR:-/mnt/recidem}
PORT=5559 GDB=1239
O="-i $HOME/.ssh/tau_vm_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
   -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=10"
g() { ssh -p $PORT $O jhlee@localhost "$@"; }
die() { echo "recidem: $*"; exit 1; }
[ -f "$INITRD" ] || die "no initrd $INITRD for build #$BUILD"
[ -x "$AW" ] || gcc -O2 -Wall -pthread -o "$AW" "$R/bench/scripts/micro/atomicw.c" || die "atomicw"
pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null && die "a VM on port $PORT is running"
mkdir -p "$OUT" || exit 1
exec > >(tee -a "$OUT/run.log") 2>&1
cp "$T/run.sh" "$T/guest.sh" "$OUT/"
echo "recidem $(date -u --rfc-3339=seconds): kernel $KV; $FSES; $STATES states x fractions $FRACS;" \
  "disk ${DISK_GB}G, $FILES files ${DATA_GB}G, journal ${JOURNAL_GB}G, $THREADS threads, batch $BATCH, load ${LOAD_S}s"
# the images' file system on the test device
if ! mountpoint -q "$IMGDIR"; then
  [[ $(cat /sys/block/$TAU_DEVICE_NAME/device/model | xargs) == "SAMSUNG MZPLJ3T2HBJR-00007" ]] || die "test device is not the PM1735"
  sudo mkdir -p "$IMGDIR"
  stock_mke2fs -q -t ext4 -F "$TAU_DEVICE" && sudo mount "$TAU_DEVICE" "$IMGDIR" && sudo chown "$(id -u):$(id -g)" "$IMGDIR" || die "image fs"
fi

QPID=
boot() {  # <disk image> <console log>: a fresh root overlay, the image as /dev/vda
  rm -f "${IMGDIR:?}/ov.qcow2"
  qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$IMGDIR/ov.qcow2" || return 1
  INITRD=$INITRD ROOTFS=$IMGDIR/ov.qcow2 SCRATCH=$1 SSH_PORT=$PORT GDB_PORT=$GDB TAUFS_KERNEL=$KD MEM=16G CORES=8 \
    sg kvm -c "bash $R/tools/qemu/run_vm_torner.sh" > "$2" 2>&1 < /dev/null &
  QPID=$!
  local i
  for i in $(seq 80); do timeout 10 ssh -p $PORT $O jhlee@localhost true 2>/dev/null && break; sleep 3; done
  g "mkdir -p ~/recidem" && scp -q -P $PORT $O "$T/guest.sh" "$AW" jhlee@localhost:recidem/
}
vm_kill() { pkill -KILL -f "hostfwd=tcp::$PORT-:22"; wait $QPID 2>/dev/null; QPID=; }
vm_off() {
  timeout 30 ssh -p $PORT $O jhlee@localhost "sudo poweroff" > /dev/null 2>&1
  local i; for i in $(seq 40); do pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null || break; sleep 2; done
  pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null && vm_kill
  wait $QPID 2>/dev/null; QPID=
}
mount_wait() {  # <timeout s>: seconds the guest's mount took, or "timeout"
  local i
  for (( i = 0; i < $1 * 2; i++ )); do
    t=$(g "cat ~/recidem/mount.done 2>/dev/null") && [ -n "$t" ] && { echo "$t"; return 0; }
    sleep 0.5
  done
  echo timeout; return 1
}
fsck_img() {  # <fs> <image>
  case $1 in
    ext4-tau) sudo "$TAUFS_E2FSPROGS/e2fsck/e2fsck" -fn "$2" > "$3" 2>&1 ;;
    xfs-tau)  sudo "$TAUFS_XFSPROGS/repair/xfs_repair" -n -f "$2" > "$3" 2>&1 ;;
  esac
  echo $?
}
recover() {  # <fs> <image> <prefix>: boot, mount (the replay), hash, umount, power off, fsck
  boot "$2" "$3.console" || { echo "boot failed"; return 1; }
  g "bash ~/recidem/guest.sh mount $1 $JOURNAL_GB" > /dev/null
  local t; t=$(mount_wait 900)
  scp -q -P $PORT $O jhlee@localhost:recidem/mount.dmesg "$3.dmesg" 2>/dev/null
  [[ $t == timeout ]] && { vm_kill; echo "mount timeout"; return 1; }
  g "bash ~/recidem/guest.sh hash" > "$3.hash"
  g "bash ~/recidem/guest.sh umount"
  vm_off
  local f; f=$(fsck_img "$1" "$2" "$3.fsck")
  echo "$t $f"
}

printf '%-10s %-6s %-5s %8s %8s %6s %8s %8s %8s %s\n' fs state frac T_A kill_s mid T_B2 fsckA fsckB result | tee "$OUT/results.txt"
for fs in $FSES; do
  for s in $(seq "$STATES"); do
    P=$OUT/$fs.s$s C=$IMGDIR/$fs.s$s.crash
    # a fresh τ file system, loaded until the kill: the crash state
    rm -f "${C:?}"; truncate -s "${DISK_GB}G" "$C"
    case $fs in
      ext4-tau) tau_mke2fs -t ext4 -E lazy_itable_init=0,lazy_journal_init=0${SEGSIZE:+,tau_segsize=$SEGSIZE} -F "$C" > "$P.mkfs" 2>&1 ;;
      xfs-tau)  tau_mkfs_xfs -f -l $XL "$C" > "$P.mkfs" 2>&1 ;;
    esac
    echo "$fs s$s: mkfs: $(grep -m1 -o 'segment size of [0-9]* *[A-Z]*' "$P.mkfs")"
    boot "$C" "$P.load.console" || { echo "$fs s$s: boot failed"; vm_kill; continue; }
    g "bash ~/recidem/guest.sh mount $fs $JOURNAL_GB" > /dev/null; mount_wait 120 > /dev/null || { echo "$fs s$s: load mount failed"; vm_kill; continue; }
    g "bash ~/recidem/guest.sh prepare $FILES $DATA_GB" > /dev/null || { echo "$fs s$s: prepare failed"; vm_kill; continue; }
    g "bash ~/recidem/guest.sh load $FILES $DATA_GB $THREADS $LOAD_S $BATCH" > /dev/null
    k=$(( KILL_MIN_S + RANDOM % (LOAD_S - KILL_MIN_S) ))
    sleep "$k"
    g "tail -c 300 ~/recidem/load.log" > "$P.load.tail" 2>/dev/null
    vm_kill
    echo "$fs s$s: crash state after ${k}s of load ($(date -u +%T))"
    # A: one complete recovery
    cp --sparse=always "$C" "$IMGDIR/A.img"
    a=$(recover "$fs" "$IMGDIR/A.img" "$P.A"); read -r TA fA <<< "$a"
    echo "$fs s$s A: mount ${TA}s fsck $fA"
    [[ $TA =~ ^[0-9.]+$ ]] || { echo "$fs s$s: A failed ($a)"; continue; }
    for f in $FRACS; do
      cp --sparse=always "$C" "$IMGDIR/B.img"
      boot "$IMGDIR/B.img" "$P.B$f.1.console" || { echo "boot failed"; vm_kill; continue; }
      kill_s=$(awk -v t="$TA" -v f="$f" 'BEGIN {printf "%.2f", t * f}')
      g "bash ~/recidem/guest.sh mount $fs $JOURNAL_GB" > /dev/null
      sleep "$kill_s"
      mid=yes; g "test -e ~/recidem/mount.done" && mid=no
      vm_kill
      b=$(recover "$fs" "$IMGDIR/B.img" "$P.B$f"); read -r TB fB <<< "$b"
      if [[ $TB =~ ^[0-9.]+$ ]] && cmp -s "$P.A.hash" "$P.B$f.hash" && [[ $fA == 0 && $fB == 0 ]]; then res=PASS
      elif [[ $TB =~ ^[0-9.]+$ ]] && ! cmp -s "$P.A.hash" "$P.B$f.hash"; then res="FAIL($(diff "$P.A.hash" "$P.B$f.hash" | grep -c '^>') files differ)"
      else res="FAIL($b)"; fi
      printf '%-10s %-6s %-5s %8s %8s %6s %8s %8s %8s %s\n' "$fs" "s$s" "$f" "$TA" "$kill_s" "$mid" "$TB" "$fA" "$fB" "$res" | tee -a "$OUT/results.txt"
    done
    rm -f "${IMGDIR:?}/A.img" "${IMGDIR:?}/B.img" "${C:?}"
  done
done
rm -f "${IMGDIR:?}/ov.qcow2"
echo "recidem done $(date -u --rfc-3339=seconds): $(grep -c PASS "$OUT/results.txt") PASS, $(grep -c FAIL "$OUT/results.txt") FAIL"
exit
}
