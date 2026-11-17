#!/bin/bash
# Guest side of run_recovery_vm.sh (EVAL_PLAN R2 in a VM with the test NVMe passed
# through). Copied into the guest as ~/r2/recovery_vm_guest.sh; every subcommand
# is run over ssh by the host. Long steps run detached (nohup) and leave a marker
# that the host polls, so a wedged guest never blocks an ssh call.
#   prep <fs>                  check the device, settings that the host has (numa balancing off)
#   pg_conf <key=value>...     PG settings into postgresql.conf, synced (the host cannot mount τ)
#   mount <fs> <out>           mount, timed (seconds into <out>), dmesg since the mount call
#   pg_start <log> | my_start <log> <dblwr> <args...>   start the DB until it accepts
#                              connections, timed (seconds on stdout)
#   sb <name> <args...>        sysbench detached: ~/r2/<name>.log, marker ~/r2/<name>.done
#   pos_pg | pos_my            WAL/redo position and the last checkpoint's
#   pg_stop | my_stop          clean shutdown;  umount
# Application crash (run_recovery_vm.sh CRASH_MODE=app; the kernel and the mount stay):
#   pg_start <log> crashed     as pg_start, but postmaster.pid stays: PG itself finds the
#                              killed server's lock file and shared memory stale
#   trace_prep <fs> <f_inode> <i_ino>   kprobe events on the file system's write_iter, off:
#                              entry (inode, offset, bytes asked), return (bytes written);
#                              file.f_inode and inode.i_ino offsets from the host (pahole)
#   trace_on | trace_off       on | off, the trace into ~/r2/kill.trace.zst (.gz), the
#                              probes' hits and misses and the buffer's counts into kill.txt
#   kill_db <postgres|mysql>   SIGKILL of the whole server at once (PG: the postmaster's
#                              process group, mysqld), until no process of it is left;
#                              trace markers "kill" and "gone"; prints kill_epoch, gone_s
#   sb_stop                    the load's sysbench killed if it still runs
#   inopath <ino>...           paths of inodes under the mount
#   innochk                    detached: innochecksum of every InnoDB tablespace (server
#                              stopped), ~/r2/innochk.txt, marker ~/r2/innochk.done
set -u
MNT=/mnt/temp
DEV=/dev/nvme0n1
R2=$HOME/r2
TR=/sys/kernel/tracing
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
    # every boot starts with fresh logs: the host fetched what it needs from the last boot
    rm -f "${R2:?}"/*.log* "${R2:?}"/mount* "${R2:?}"/*.done "${R2:?}"/*.err*
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
  pg_conf)   # <key=value>...: as postgres/api.sh pg_conf_set, then synced (before any crash)
    conf=$PG_DATA/postgresql.conf
    [[ -f "$conf.bak" ]] || cp -a "$conf" "$conf.bak"
    for kv in "$@"; do
      k=${kv%%=*} v=${kv#*=}
      if grep -Eq "^[[:space:]]*#?[[:space:]]*$k[[:space:]]*=" "$conf"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*($k)[[:space:]]*=.*|\1 = $v|g" "$conf"
      else
        printf "\n%s = %s\n" "$k" "$v" >> "$conf"
      fi
    done
    sync
    grep -E "^($(printf '%s|' "${@%%=*}" | sed 's/|$//'))[[:space:]]*=" "$conf"
    ;;
  pg_start)
    [[ "${2:-}" == crashed ]] || rm -f $PG_DATA/postmaster.pid   # no PG runs in a freshly booted guest
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
  trace_prep)
    fs=$1 fi=$2 ii=$3
    case $fs in
      ext4*) fn=ext4_file_write_iter ;;
      xfs*)  fn=xfs_file_write_iter ;;
      *) echo "no write_iter probe for $fs"; exit 1 ;;
    esac
    [[ "$fi" =~ ^[0-9]+$ && "$ii" =~ ^[0-9]+$ ]] || { echo "bad offsets '$fi' '$ii'"; exit 1; }
    # x86-64: iocb in %di (ki_filp at 0, ki_pos at 8), from in %si (iov_iter.count at 24;
    # the host checked these three too). 8 MiB of buffer per CPU, allocated now, not at the kill.
    sudo sh -c "cd $TR || exit 1
      echo 0 > tracing_on; echo 0 > events/enable
      echo '-:tw/w_in' >> kprobe_events 2> /dev/null; echo '-:tw/w_out' >> kprobe_events 2> /dev/null
      echo 8192 > buffer_size_kb || exit 1
      echo 'p:tw/w_in $fn ino=+$ii(+$fi(+0(%di))):u64 pos=+8(%di):s64 count=+24(%si):u64' >> kprobe_events || exit 1
      echo 'r256:tw/w_out $fn ret=\$retval:s64' >> kprobe_events || exit 1
      echo > trace" || { echo "trace_prep failed"; exit 1; }
    sudo cat $TR/kprobe_events
    ;;
  trace_on) sudo sh -c "cd $TR && echo > trace && echo 1 > events/tw/enable && echo 1 > tracing_on" ;;
  trace_off)
    sudo sh -c "cd $TR && echo 0 > tracing_on && echo 0 > events/tw/enable"
    {
      echo "kprobe_profile:"; sudo cat $TR/kprobe_profile
      echo "buffer: $(sudo sh -c "cat $TR/per_cpu/cpu*/stats" | awk -F': ' '$1 ~ /^(entries|overrun|commit overrun|dropped events)$/ {
        k = $1; gsub(/ /, "_", k); s[k] += $2} END {for (k in s) printf "%s=%d ", k, s[k]}')"
    } >> $R2/kill.txt
    if command -v zstd > /dev/null; then
      sudo cat $TR/trace | zstd -q -3 -f -o $R2/kill.trace.zst
    else
      sudo cat $TR/trace | gzip -1 > $R2/kill.trace.gz
    fi
    ls -la $R2/kill.trace.* | awk '{print "trace_file=" $NF " bytes=" $5}'
    ;;
  kill_db)
    db=$1
    case $db in
      postgres) pm=$(head -1 $PG_DATA/postmaster.pid 2>/dev/null); comm=postgres ;;
      mysql)    pm=$(cat $MY_DATA/mysqld.pid 2>/dev/null); comm=mysqld ;;
      *) echo "kill_db postgres|mysql"; exit 2 ;;
    esac
    [[ "$pm" =~ ^[0-9]+$ ]] && kill -0 "$pm" 2> /dev/null || { echo "no $db server (pid '$pm')"; exit 1; }
    pids=$(pgrep -d ' ' -x $comm)
    pgid=$(ps -o pgid= -p "$pm" | tr -d ' ')
    # PG: pg_ctl starts the postmaster with setsid(), so its process group is the
    # postmaster and its children; one kill(2) on the group reaches them all before any
    # child can exit (and the postmaster react). Anything else in the group: one by one.
    others=$(ps -eo pgid=,comm= | awk -v g="$pgid" -v c="$comm" '$1 == g && $2 != c' | wc -l)
    {
      echo "server $db pid $pm pgid $pgid, $(echo $pids | wc -w) $comm processes, $(ls /proc/$pm/task | wc -l) threads in $pm, others in the group $others"
      echo "pids $pids"
    } > $R2/kill.txt
    sudo sh -c "echo kill > $TR/trace_marker" 2> /dev/null
    t0=$(now)
    if [[ $db == postgres && "$pgid" == "$pm" && $others == 0 ]]; then
      kill -KILL -- -"$pm"; how=group
    else
      kill -KILL $pids; how=each
    fi
    while pgrep -x $comm > /dev/null; do
      [[ $(since "$t0" | cut -d. -f1) -lt 120 ]] || { echo "$comm still there 120 s after the kill"; exit 1; }
      sleep 0.01
    done
    g=$(since "$t0")
    sudo sh -c "echo gone > $TR/trace_marker" 2> /dev/null
    echo "kill_epoch=$t0 gone_s=$g killed_processes=$(echo $pids | wc -w) kill_how=$how" | tee -a $R2/kill.txt
    ;;
  sb_stop)
    pkill -KILL -x sysbench 2> /dev/null
    sleep 1
    if pgrep -x sysbench > /dev/null; then echo "sysbench still runs"; exit 1; fi
    ;;
  inopath)
    for i in "$@"; do echo "ino $i $(sudo find $MNT -xdev -inum "$i" -printf '%P ' 2>/dev/null)"; done
    ;;
  innochk)
    rm -f $R2/innochk.done $R2/innochk.txt
    nohup bash "$0" innochk_run > /dev/null 2>&1 &
    echo started
    ;;
  innochk_run)   # innochk's work, detached
    ic=$MY_BIN/innochecksum
    if [[ ! -x $ic ]]; then
      echo "innochk_files=0 innochk_bad=0 innochk=missing" > $R2/innochk.txt
    else
      # every tablespace (.ibd, ibdata*, undo_*), 16 at a time; not the temporary ones (#innodb_temp, ibtmp1)
      cd $MY_DATA || exit 1
      find . -type f \( -name '*.ibd' -o -name 'ibdata*' -o -name 'undo_[0-9]*' \) -not -path './#innodb_temp/*' -print0 > $R2/innochk.list
      xargs -0 -P 16 -n 1 bash -c '"$0" "$1" > /dev/null 2>&1; echo "rc $? $1"' "$ic" < $R2/innochk.list > $R2/innochk.out
      { echo "innochk_files=$(tr -cd '\0' < $R2/innochk.list | wc -c) innochk_bad=$(grep -vc '^rc 0 ' $R2/innochk.out)"
        grep -v '^rc 0 ' $R2/innochk.out; } > $R2/innochk.txt
    fi
    echo 0 > $R2/innochk.done
    ;;
  *) echo "unknown command $cmd"; exit 2 ;;
esac
