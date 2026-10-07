#!/bin/bash
# Print the host settings that can change benchmark results as "key: value"
# lines, so that two machines (or two points in time) can be compared with diff.
# Usage: machine_info.sh [test device, default $TAU_DEVICE_NAME or nvme0n1]
DEV=${1:-${TAU_DEVICE_NAME:-nvme0n1}}
B=$(cd "$(dirname "$0")/.." && pwd)   # bench/
cpu=/sys/devices/system/cpu

section() { printf '\n## %s\n' "$1"; }
kv() { printf '%-24s %s\n' "$1:" "$2"; }
sel() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$1"; }   # the [selected] value of a sysfs choice

echo "# machine_info $(date -u --rfc-3339=seconds)"

section system
kv host "$(hostname)"
kv product "$(sudo dmidecode -s system-manufacturer) $(sudo dmidecode -s system-product-name)"
kv bios "$(sudo dmidecode -s bios-version) ($(sudo dmidecode -s bios-release-date))"
kv os "$(. /etc/os-release && echo "$PRETTY_NAME")"
kv kernel "$(uname -r)"
kv cmdline "$(cat /proc/cmdline)"

section sources
# the tau kernel and mkfs trees (set_env.sh): commit and local changes
for t in TAUFS_KERNEL TAUFS_E2FSPROGS TAUFS_XFSPROGS; do
  d=${!t}
  kv "$t" "$d $(git -C "$d" describe --always --dirty --abbrev=12 2>/dev/null) ($(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null))"
done

section cpu
kv model "$(lscpu | sed -n 's/^Model name: *//p')"
kv topology "$(lscpu | sed -n 's/^Socket(s): *//p') sockets x $(lscpu | sed -n 's/^Core(s) per socket: *//p') cores x $(lscpu | sed -n 's/^Thread(s) per core: *//p') threads"
kv smt "control=$(cat $cpu/smt/control) active=$(cat $cpu/smt/active)"
kv microcode "$(awk '/^microcode/{print $3; exit}' /proc/cpuinfo)"
kv freq_driver "$(cat $cpu/cpu0/cpufreq/scaling_driver) (intel_pstate $(cat $cpu/intel_pstate/status 2>/dev/null))"
kv governor "$(cat $cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c | xargs)"
kv freq_khz "min=$(cat $cpu/cpu0/cpufreq/scaling_min_freq) max=$(cat $cpu/cpu0/cpufreq/scaling_max_freq) hw_max=$(cat $cpu/cpu0/cpufreq/cpuinfo_max_freq)"
kv turbo "$([ "$(cat $cpu/intel_pstate/no_turbo 2>/dev/null)" = 0 ] && echo on || echo off)"
kv energy_perf_bias "$(cat $cpu/cpu0/power/energy_perf_bias 2>/dev/null)"
kv cstates "$(cat $cpu/cpuidle/current_driver): $(for s in $cpu/cpu0/cpuidle/state*; do printf '%s=%s ' "$(cat $s/name)" "$([ "$(cat $s/disable)" = 0 ] && echo on || echo off)"; done)"
kv clocksource "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
for v in $cpu/vulnerabilities/*; do kv "vuln.$(basename $v)" "$(cat $v)"; done

section memory
hp_kb() {  # total kB held by huge pages of every size under $1 (a hugepages/ dir)
  local d sz sum=0
  for d in "$1"/hugepages-*; do
    sz=${d##*hugepages-}
    sum=$(( sum + $(cat $d/nr_hugepages) * ${sz%kB} ))
  done
  echo $sum
}
kv memtotal "$(awk '/^MemTotal/{t=$2} /^Hugetlb/{h=$2} END{printf "%.1f GiB, usable %.1f GiB (minus huge pages)", t/1048576, (t-h)/1048576}' /proc/meminfo)"
for n in /sys/devices/system/node/node[0-9]*; do
  t=$(awk '/MemTotal/{print $4}' $n/meminfo)
  h=$(hp_kb $n/hugepages)
  kv "$(basename $n)" "$(awk -v t=$t -v h=$h 'BEGIN{printf "%.1f GiB, huge pages %.1f GiB, usable %.1f GiB", t/1048576, h/1048576, (t-h)/1048576}'), cpus $(cat $n/cpulist)"
done
kv dimms "$(sudo dmidecode -t 17 | awk -F': ' '/^\tSize: [0-9]/{s=$2} /^\tConfigured Memory Speed:/{if (s != "") print s " @ " $2; s=""}' | sort | uniq -c | awk '{c=$1; $1=""; printf "%d x%s ", c, $0}')"
kv numa_balancing "$(cat /proc/sys/kernel/numa_balancing)"
kv thp "enabled=$(sel /sys/kernel/mm/transparent_hugepage/enabled) defrag=$(sel /sys/kernel/mm/transparent_hugepage/defrag) shmem=$(sel /sys/kernel/mm/transparent_hugepage/shmem_enabled)"
kv hugepages "$(for d in /sys/kernel/mm/hugepages/hugepages-*; do printf '%s=%s ' "${d##*hugepages-}" "$(cat $d/nr_hugepages)"; done)"
kv ksm "$(cat /sys/kernel/mm/ksm/run)"
kv swap "$(swapon --show=NAME,SIZE --noheadings | xargs) swappiness=$(cat /proc/sys/vm/swappiness)"
kv dirty "ratio=$(cat /proc/sys/vm/dirty_ratio) background=$(cat /proc/sys/vm/dirty_background_ratio) expire_cs=$(cat /proc/sys/vm/dirty_expire_centisecs) writeback_cs=$(cat /proc/sys/vm/dirty_writeback_centisecs)"
kv vm_other "overcommit=$(cat /proc/sys/vm/overcommit_memory) min_free_kbytes=$(cat /proc/sys/vm/min_free_kbytes) zone_reclaim=$(cat /proc/sys/vm/zone_reclaim_mode)"

section storage
kv nvme_multipath "$(cat /sys/module/nvme_core/parameters/multipath 2>/dev/null)"
kv test_device "$DEV"
for c in /sys/class/nvme/nvme[0-9]*; do
  n=$(basename $c)
  ns=$(ls -d /sys/block/${n}n1 2>/dev/null | head -1)
  q=$(ls -d /sys/block/${n}c*n1/queue /sys/block/${n}n1/queue/scheduler 2>/dev/null | head -1)
  q=${q%/scheduler}
  pci=$(basename "$(readlink -f $c/device)")
  link=$(sudo lspci -vv -s "$pci" 2>/dev/null | sed -n 's/.*LnkSta:[^S]*\(Speed [^,]*\), \(Width x[0-9]*\).*/\1 \2/p')
  kv "$n" "$(cat $c/model | xargs), fw $(cat $c/firmware_rev | xargs), numa $(cat $c/device/numa_node), pcie $link, $([ -n "$ns" ] && echo "$(( $(cat $ns/size) * 512 / 1000000000 )) GB, cache $(cat $ns/queue/write_cache)")"
  [ -n "$q" ] && kv "$n.queue" "sched=$(sel $q/scheduler) nr_requests=$(cat $q/nr_requests) read_ahead_kb=$(cat $ns/queue/read_ahead_kb 2>/dev/null) max_sectors_kb=$(cat $q/max_sectors_kb)"
done

section services
kv services "$(for s in irqbalance tuned thermald; do printf '%s=%s ' $s "$(systemctl is-active $s 2>/dev/null)"; done)"

section software
kv postgres "$($B/workspace/pg_install/bin/postgres --version 2>/dev/null)"
kv mysql "$($B/mysql-server/build/bin/mysqld --version 2>/dev/null | sed 's/.*Ver //')"
kv sysbench "$(sysbench --version 2>/dev/null)"
kv partclone "$(partclone.ext4 -v 2>&1 | sed -n 's/^Partclone : //p')"
kv stock_mkfs "$($B/workspace/stock/usr/sbin/mke2fs -V 2>&1 | head -1), $($B/workspace/stock/sbin/mkfs.xfs -V 2>&1)"
kv system_mkfs "$(mke2fs -V 2>&1 | head -1), $(mkfs.xfs -V 2>&1) (tau forks)"
kv zfs "$(cat /sys/module/zfs/version 2>/dev/null || echo 'module not loaded') / userland $(dpkg-query -W -f='${Version}' zfsutils-linux 2>/dev/null)$([ -d /sys/module/zfs ] && echo " / arc_max $(cat /sys/module/zfs/parameters/zfs_arc_max)")"
