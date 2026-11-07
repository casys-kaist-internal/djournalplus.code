#!/bin/bash
# Guest side of tools/recidem/nth.sh: EVAL_PLAN T3 #9 (during_recovery_nth_block) as a block-level
# sweep. /dev/vda is the crash image with room appended by the host. dm-linear cuts it in three:
#   nthbase  the crash state, the τ FS's <fs GiB>: never written
#   nthcow   <cow GiB>, the COW of every snapshot: non-persistent, so it needs no reset between them
#   nthlog   <log GiB>, the dm-log-writes log
# Every mount runs on a dm-snapshot of nthbase. (The first version kept the COW and the log in files on
# the guest's root; the full-size run filled it, 11-07.)
#   record <fs> <journal GiB> <fs GiB> <cow GiB> <log GiB>
#       the reference recovery:
#       - a snapshot, dm-log-writes on top (log ~/nth/log.img), mount (τ's replay), mark torner:end;
#       - the data files' sha256 and sizes to ~/nth/A.hash, then umount;
#       - prints the mount time, then `torner replay --stat-only` of the log. Its end_entry is where the
#         mount returned. It is no bound: plain writes are logged at the next FLUSH or at teardown.
#   trial <fs> <journal GiB> <state spec>
#       a fresh snapshot gets `torner replay --state-spec` from the log: the device as a crash left it
#       after that part of the recovery's writes. Then mount (the second recovery), hash, umount, and
#       fsck with the τ forks. Prints one line:
#         spec=... last=<entry>/<epoch> mount_s=... replayed=<files>/<blocks> hash=same|DIFF fsck=<rc>
#   cleanup        tears down whatever a killed command left behind
# Needs ~/nth/bin: torner, e2fsck, xfs_repair (the host's builds); ~/nth/mod: the kernel tree's
# dm-bufio, dm-snapshot and dm-log-writes modules.
set -u
N=$HOME/nth; B=$N/bin; MNT=/mnt/nth; DEV=/dev/mapper/nthbase COW=/dev/mapper/nthcow LOG=/dev/mapper/nthlog
cmd=${1:?command}; shift
sudo mkdir -p $MNT; mkdir -p $N
SZ=$(sudo blockdev --getsz $DEV 2> /dev/null)
mopts() {  # <fs> <jgb>
  case $1 in
    ext4-tau) echo "-t ext4 -o tjournal,tjournal_size=$2" ;;
    xfs-tau)  echo "-t xfs -o tjournal,tjournal_size=$2" ;;
    *) echo "unknown fs $1" >&2; exit 1 ;;
  esac
}
carve() {  # <fs GiB> <cow GiB> <log GiB>: the three linear devices on /dev/vda
  local g=$((1 << 21)) a b c   # sectors per GiB
  a=$(( $1 * g )) b=$(( $2 * g )) c=$(( $3 * g ))
  (( $(sudo blockdev --getsz /dev/vda) >= a + b + c )) || { echo "/dev/vda is smaller than $1+$2+$3 GiB"; exit 1; }
  sudo dmsetup create nthbase --table "0 $a linear /dev/vda 0" &&
    sudo dmsetup create nthcow --table "0 $b linear /dev/vda $a" &&
    sudo dmsetup create nthlog --table "0 $c linear /dev/vda $(( a + b ))" || exit 1
  SZ=$a
}
snap() {  # <name>: a non-persistent snapshot of nthbase on nthcow, prints its device
  sudo dmsetup create $1 --table "0 $SZ snapshot $DEV $COW N 8" || exit 1
  echo /dev/mapper/$1
}
unsnap() {  # <name>
  sudo dmsetup remove $1 2> /dev/null
}
cowuse() {  # <name>: "used/total sectors" of a snapshot's COW, or its status word (Invalid, Overflow)
  sudo dmsetup status $1 2> /dev/null | awk '{print $4}'
}
hashfiles() {  # the data files f*, sorted, as recidem's guest.sh hash
  ( cd $MNT && ls f[0-9]* | sudo xargs -P 8 -n 1 sha256sum | sort -k 2 && sudo stat -c 'size %s %n' f[0-9]* )
}
mount_timed() {  # <dev> <fs> <jgb>: mounts, prints seconds
  local t0 t1; t0=$(date +%s.%N)
  sudo mount $(mopts $2 $3) $1 $MNT || return 1
  t1=$(date +%s.%N); awk -v a=$t1 -v b=$t0 'BEGIN {printf "%.1f", a - b}'
}
# The kernel log of one mount, followed live: τ's replay logs a line per revoke block, which
# overflows the ring buffer, so a line count taken before the mount does not locate it afterwards.
klog_start() { sudo dmesg -C; sudo dmesg -w > $N/$1.dmesg 2>&1 & echo $! > $N/klog.pid; }
klog_stop() { sleep 1; sudo kill $(cat $N/klog.pid) 2> /dev/null; wait 2> /dev/null; }
replayed() {  # <name>: "<files>/<blocks>" τ's replay reported in that mount's log
  awk '/TAU: replay done for ino/ {f++; for (i = 1; i <= NF; i++) if ($i == "replayed") b += $(i + 1)}
    END {printf "%d/%d", f, b}' $N/$1.dmesg
}
mods() {  # the tree's dm-bufio, dm-snapshot, dm-log-writes (~/nth/mod), unless loaded
  local m
  for m in dm-bufio dm-snapshot dm-log-writes; do
    grep -q "^${m//-/_} " /proc/modules || sudo insmod $N/mod/$m.ko || { echo "insmod $m failed"; exit 1; }
  done
}
case $cmd in
  record)
    fs=$1 jgb=$2
    mods
    carve $3 $4 $5
    S=$(snap nthref) || exit 1
    L=$LOG
    echo "$L" > $N/log.loop
    wc=$(cat /sys/block/vda/queue/write_cache)
    sudo dmsetup create nthlw --table "0 $SZ log-writes $S $L" || exit 1
    klog_start record
    t=$(mount_timed /dev/mapper/nthlw $fs $jgb) || { klog_stop; echo "record: mount failed"; exit 1; }
    sudo dmsetup message nthlw 0 mark torner:end
    klog_stop
    r=$(replayed record)
    hashfiles > $N/A.hash
    sudo umount $MNT
    sudo dmsetup remove nthlw
    echo "record: cow $(cowuse nthref)"
    unsnap nthref
    echo "record: mount_s=$t replayed=$r vda_write_cache='$wc' files=$(grep -c '^size' $N/A.hash)"
    sudo $B/torner replay --log $L --stat-only
    ;;
  trial)
    fs=$1 jgb=$2 spec=$3
    L=$(cat $N/log.loop)
    S=$(snap nthtrial) || exit 1
    sudo $B/torner replay --log $L --target $S --state-spec "$spec" > $N/trial.replay 2>&1 ||
      { echo "spec=$spec replay-failed: $(tail -1 $N/trial.replay)"; unsnap nthtrial; exit 1; }
    sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    klog_start trial
    t=$(mount_timed $S $fs $jgb) || { klog_stop; echo "spec=$spec mount=FAILED"; tail -5 $N/trial.dmesg; unsnap nthtrial; exit 1; }
    klog_stop
    r=$(replayed trial)
    hashfiles > $N/B.hash
    h=same; cmp -s $N/A.hash $N/B.hash || h=DIFF
    sudo umount $MNT
    c=$(cowuse nthtrial)
    case $fs in
      ext4-tau) sudo $B/e2fsck -fn $S > $N/trial.fsck 2>&1 ;;
      xfs-tau)  sudo $B/xfs_repair -n $S > $N/trial.fsck 2>&1 ;;
    esac
    f=$?
    [ $h = DIFF ] && { k=$(echo "$spec" | tr -c 'a-z0-9' '_'); cp $N/B.hash $N/B.$k.hash; cp $N/trial.dmesg $N/B.$k.dmesg; }
    unsnap nthtrial
    le=$(grep -o '"last_entry":[0-9]*' $N/trial.replay | cut -d: -f2)
    lp=$(grep -o '"last_epoch":[0-9]*' $N/trial.replay | cut -d: -f2)
    echo "spec=$spec last=$le/$lp mount_s=$t replayed=$r hash=$h fsck=$f cow=$c"
    ;;
  cleanup)
    mountpoint -q $MNT && sudo umount $MNT
    sudo dmsetup remove nthlw 2> /dev/null
    unsnap nthtrial; unsnap nthref
    for d in nthlog nthcow nthbase; do sudo dmsetup remove $d 2> /dev/null; done
    echo cleaned
    ;;
  *) echo "unknown command $cmd"; exit 2 ;;
esac
