#!/bin/bash
# Guest side of tools/recidem/run.sh (EVAL_PLAN T3 #9: a crash during the τ journal's replay
# at mount). Copied into the guest as ~/recidem/guest.sh; the host runs every command over ssh.
# Long steps run detached and leave markers the host polls, so a killed VM never hangs an ssh call.
#   mount <fs> <journal GiB>   mount /dev/vda with tjournal, detached: markers mount.start (epoch
#                              s.ns) and mount.done (seconds the mount took, written once the
#                              mount's kernel log is complete in mount.dmesg, followed with dmesg -w)
#   prepare <files> <GiB>      the files the load overwrites (f000...), then sync
#   load <files> <GiB> <threads> <s> <batch>   atomicw overwrite --mode tau, an fdatasync every <batch> pages, detached
#                              (load.log, marker load.done)
#   hash                       sha256 and size of the data files (f*), sorted, to stdout: not the
#                              τ journal's own files (xfs-tau keeps tjournal* in the root)
#   umount
set -u
DEV=/dev/vda
MNT=/mnt/recidem
R=$HOME/recidem
cmd=$1; shift
mkdir -p "$R"
case "$cmd" in
  mount)
    fs=$1 jgb=$2
    rm -f "$R"/mount.*
    sudo mkdir -p $MNT
    case $fs in
      ext4-tau) o=(-t ext4 -o "tjournal,tjournal_size=$jgb") ;;
      xfs-tau)  o=(-t xfs -o "tjournal,tjournal_size=$jgb") ;;
      *) echo "unknown fs $fs"; exit 1 ;;
    esac
    # the mount's kernel log, followed live: τ's replay logs a line per revoke block and overflows
    # the ring buffer, so a line count taken before the mount does not find its start afterwards
    # (the 11-06 run's replay sizes were lower bounds for that reason)
    sudo dmesg -C
    nohup bash -c "sudo dmesg -w > '$R/mount.dmesg' 2>&1 & kp=\$!
      t0=\$(date +%s.%N); echo \$t0 > '$R/mount.start'; sync '$R/mount.start'
      if sudo mount ${o[*]} $DEV $MNT; then
        e=\$(awk -v a=\$(date +%s.%N) -v b=\$t0 'BEGIN {printf \"%.3f\", a - b}')
        sleep 1; sudo kill \$kp; echo \$e > '$R/mount.done'
      else sleep 1; sudo kill \$kp; fi" > /dev/null 2>&1 &
    echo started
    ;;
  prepare)
    files=$1 gb=$2
    sudo chmod 777 $MNT
    "$R/atomicw" --prepare --dir $MNT --files "$files" --total "${gb}g" > "$R/prepare.log" 2>&1 || { cat "$R/prepare.log"; exit 1; }
    sync
    echo prepared
    ;;
  load)
    files=$1 gb=$2 threads=$3 secs=$4 batch=$5
    rm -f "$R/load.done"
    nohup bash -c "'$R/atomicw' --dir $MNT --pattern overwrite --mode tau --threads $threads --files $files \
      --total ${gb}g --batch $batch --warmup 0 --duration $secs > '$R/load.log' 2>&1; echo \$? > '$R/load.done'" \
      > /dev/null 2>&1 &
    echo started
    ;;
  hash)
    cd $MNT && sudo sha256sum f[0-9]* && sudo stat -c 'size %s %n' f[0-9]*
    ;;
  umount) sudo umount $MNT ;;
  *) echo "unknown command $cmd"; exit 2 ;;
esac
