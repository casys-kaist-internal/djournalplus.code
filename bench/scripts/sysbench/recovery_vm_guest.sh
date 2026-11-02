#!/bin/bash
# Guest side of run_recovery_vm.sh (EVAL_PLAN R2 in a VM with the test NVMe passed
# through). Copied into the guest as ~/r2/recovery_vm_guest.sh; every subcommand
# is run over ssh by the host. Long steps run detached (nohup) and leave a marker
# that the host polls, so a wedged guest never blocks an ssh call.
#   prep <fs>                  check the device, settings that the host has (numa balancing off)
#   mount <fs> <out>           mount, timed (seconds into <out>), dmesg since the mount call
#   pg_start <log> | my_start <log> <dblwr> <args...>   start the DB until it accepts
#                              connections, timed (seconds on stdout)
#   sb <name> <args...>        sysbench detached: ~/r2/<name>.log, marker ~/r2/<name>.done
#   pos_pg | pos_my            WAL/redo position and the last checkpoint's
#   pg_stop | my_stop          clean shutdown;  umount
set -u
MNT=/mnt/temp
DEV=/dev/nvme0n1
R2=$HOME/r2
PG_BIN=/home/jhlee/codes/djournalplus.code/bench/workspace/pg_install/bin
MY_BIN=/home/jhlee/codes/djournalplus.code/bench/mysql-server/build/bin
PG_DATA=$MNT/pgsql_data
MY_DATA=$MNT/mysql_data
MY_SOCK=$MY_DATA/mysql.sock
now() { date +%s.%N; }
since() { awk -v a="$(now)" -v b="$1" 'BEGIN {printf "%.3f", a - b}'; }
mkdir -p "$R2"
cmd=$1; shift
case "$cmd" in
  prep)
    m=$(cat /sys/block/nvme0n1/device/model 2>/dev/null | xargs)
    [[ "$m" == "SAMSUNG MZPLJ3T2HBJR-00007" ]] || { echo "not the PM1735: '$m'"; exit 1; }
    sudo sysctl -q kernel.numa_balancing=0
    sudo swapoff -a
    sudo modprobe xfs 2>/dev/null || true   # loaded before any timed mount
    sudo mkdir -p $MNT
    echo "guest $(uname -r) $(uname -v | grep -o '#[0-9]*') mem $(free -g | awk '/Mem:/ {print $2}')G cpus $(nproc)"
    ;;
  mount)
    fs=$1 out=$2
    case $fs in   # as common.sh mount_fs
      ext4)        o=(-t ext4 -o data=ordered) ;;
      ext4-dj40)   o=(-t ext4 -o data=journal) ;;
      xfs)         o=(-t xfs) ;;
      ext4-tau)    o=(-t ext4 -o tjournal,tjournal_size=32) ;;
      xfs-tau)     o=(-t xfs -o tjournal) ;;
      *) echo "unknown fs $fs"; exit 1 ;;
    esac
    n=$(sudo dmesg | wc -l)
    t0=$(now)
    sudo mount "${o[@]}" $DEV $MNT || exit 1
    echo "mount_s=$(since "$t0")" > "$out"
    echo "mount_options=$(findmnt -no OPTIONS $MNT)" >> "$out"
    sudo dmesg | tail -n +$((n + 1)) > "$out.dmesg"
    cat "$out"
    ;;
  pg_start)
    rm -f $PG_DATA/postmaster.pid   # no PG runs in a freshly booted guest
    t0=$(now)
    $PG_BIN/pg_ctl -D $PG_DATA -l "$1" -w -t 3600 start > /dev/null || exit 1
    since "$t0"; echo
    ;;
  my_start)
    log=$1 dblwr=$2; shift 2
    rm -f $MY_SOCK $MY_SOCK.lock
    t0=$(now)
    nohup $MY_BIN/mysqld --datadir=$MY_DATA --socket=$MY_SOCK --port=3306 --pid-file=$MY_DATA/mysqld.pid \
      --bind-address=127.0.0.1 --skip-networking=0 --log-error="$log" --innodb_doublewrite=$dblwr \
      --log-error-verbosity=3 "$@" > /dev/null 2>&1 &
    pid=$!
    until $MY_BIN/mysqladmin -uroot --socket=$MY_SOCK ping > /dev/null 2>&1; do
      kill -0 $pid 2>/dev/null || { echo "mysqld exited"; exit 1; }
      sleep 0.1
    done
    since "$t0"; echo
    ;;
  sb)
    name=$1; shift
    rm -f "$R2/$name.done"
    nohup bash -c "sysbench $* > '$R2/$name.log' 2>&1; echo \$? > '$R2/$name.done'" > /dev/null 2>&1 &
    echo started
    ;;
  pos_pg)
    $PG_BIN/psql -XAt -h 127.0.0.1 -p 5432 -d "$1" -c "SELECT 'lsn=' || pg_current_wal_lsn() || ' redo_lsn=' || redo_lsn
      || ' checkpoint_lsn=' || checkpoint_lsn || ' wal_since_redo=' || pg_wal_lsn_diff(pg_current_wal_lsn(), redo_lsn)
      || ' checkpoint_time=' || extract(epoch from checkpoint_time) FROM pg_control_checkpoint()"
    ;;
  pos_my)
    $MY_BIN/mysql -uroot --socket=$MY_SOCK -NBe "SHOW ENGINE INNODB STATUS\G" | awk '
      /^Log sequence number/ {lsn = $NF} /^Last checkpoint at/ {ck = $NF}
      END {print "lsn=" lsn, "checkpoint_lsn=" ck, "redo_since_checkpoint=" lsn - ck}'
    ;;
  pg_stop) $PG_BIN/pg_ctl -D $PG_DATA -t 600 stop > /dev/null ;;
  my_stop) $MY_BIN/mysqladmin -uroot --socket=$MY_SOCK shutdown; while pgrep -x mysqld > /dev/null; do sleep 1; done ;;
  umount) sudo umount $MNT ;;
  *) echo "unknown command $cmd"; exit 2 ;;
esac
