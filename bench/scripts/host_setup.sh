#!/bin/bash
# Put the benchmark host into the fixed state used for every measurement
# (apply), or report where it differs (check, exit 1 on any difference).
# Runtime settings are applied; boot-time ones (GRUB) are only checked.
# Record the resulting state with machine_info.sh.
# Usage: host_setup.sh {check|apply}
MODE=${1:-check}
cpu=/sys/devices/system/cpu
# This machine's memory budget (set_env.sh exports it; bench/machines/<host>.env)
if [ -z "$TAU_MEM_GB" ]; then
  source "$(dirname "$(realpath "$0")")/../machines/$(hostname -s).env" || exit 1
fi

# Target state
BOOT_ARGS="$TAU_BOOT_ARGS"  # the memory above TAU_MEM_GB held as unused huge pages
NUMA_BALANCING=0
GOVERNOR=performance
EPB=0                   # energy_perf_bias: 0 = performance
TURBO=on
CSTATE_MAX_LATENCY=2    # us: POLL and C1 stay, C1E and C6 are disabled
# OpenZFS caps the ARC at half of MemTotal, which still counts the reserved huge
# pages (~188 GB on libra09); TAU_ZFS_ARC_GB is what TAU_MEM_GB installed gets.
ZFS_ARC_MAX=$((TAU_ZFS_ARC_GB << 30))

fail=0
ok()  { echo "✓ $*"; }
bad() { echo "✗ $*"; fail=1; }

apply() {
  sudo swapoff -a
  sudo sysctl -qw kernel.numa_balancing=$NUMA_BALANCING
  echo $GOVERNOR | sudo tee $cpu/cpu[0-9]*/cpufreq/scaling_governor >/dev/null
  echo $EPB | sudo tee $cpu/cpu[0-9]*/power/energy_perf_bias >/dev/null
  echo "$([ $TURBO = on ] && echo 0 || echo 1)" | sudo tee $cpu/intel_pstate/no_turbo >/dev/null
  for s in $cpu/cpu[0-9]*/cpuidle/state[0-9]*; do
    echo "$([ "$(cat $s/latency)" -gt $CSTATE_MAX_LATENCY ] && echo 1 || echo 0)" | sudo tee $s/disable >/dev/null
  done
  if modinfo zfs >/dev/null 2>&1; then
    sudo modprobe zfs && echo $ZFS_ARC_MAX | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null
  fi
}

check() {
  local cmdline want uniq s bad_states=""
  cmdline=$(cat /proc/cmdline)
  if [[ " $cmdline " == *" mem="* ]]; then
    bad "boot: mem= is set; use GRUB_CMDLINE_LINUX_DEFAULT=\"$BOOT_ARGS\""
  fi
  for want in $BOOT_ARGS; do
    [[ " $cmdline " == *" $want "* ]] || bad "boot: missing $want (GRUB_CMDLINE_LINUX_DEFAULT=\"$BOOT_ARGS\")"
  done
  [[ " $cmdline " == *" mem="* ]] || [[ "$fail" == 1 ]] || ok "boot: $BOOT_ARGS"

  [ -z "$(swapon --show --noheadings)" ] && ok "swap off" || bad "swap is on"
  [ "$(cat /proc/sys/kernel/numa_balancing)" = $NUMA_BALANCING ] && ok "numa_balancing=$NUMA_BALANCING" \
    || bad "numa_balancing=$(cat /proc/sys/kernel/numa_balancing), want $NUMA_BALANCING"

  uniq=$(cat $cpu/cpu[0-9]*/cpufreq/scaling_governor | sort -u | xargs)
  [ "$uniq" = $GOVERNOR ] && ok "governor $GOVERNOR" || bad "governor: $uniq, want $GOVERNOR"
  uniq=$(cat $cpu/cpu[0-9]*/power/energy_perf_bias 2>/dev/null | sort -u | xargs)
  [ "$uniq" = $EPB ] && ok "energy_perf_bias $EPB" || bad "energy_perf_bias: $uniq, want $EPB"
  uniq=$([ "$(cat $cpu/intel_pstate/no_turbo)" = 0 ] && echo on || echo off)
  [ "$uniq" = $TURBO ] && ok "turbo $TURBO" || bad "turbo $uniq, want $TURBO"

  for s in $cpu/cpu[0-9]*/cpuidle/state[0-9]*; do
    want=$([ "$(cat $s/latency)" -gt $CSTATE_MAX_LATENCY ] && echo 1 || echo 0)
    [ "$(cat $s/disable)" = "$want" ] || bad_states+=" $(basename "$(dirname "$(dirname $s)")")/$(cat $s/name)"
  done
  if [ -z "$bad_states" ]; then
    ok "C-states with exit latency > ${CSTATE_MAX_LATENCY}us disabled"
  else
    bad "C-states not as wanted (exit latency > ${CSTATE_MAX_LATENCY}us off):$(echo $bad_states | tr ' ' '\n' | sed 's|.*/||' | sort | uniq -c | xargs)"
  fi

  if [ -d /sys/module/zfs ]; then
    uniq=$(cat /sys/module/zfs/parameters/zfs_arc_max)
    [ "$uniq" = $ZFS_ARC_MAX ] && ok "zfs_arc_max $((ZFS_ARC_MAX >> 30)) GiB" \
      || bad "zfs_arc_max=$uniq, want $ZFS_ARC_MAX"
  fi
}

case "$MODE" in
  apply) apply; check ;;
  check) check ;;
  *) echo "Usage: $0 {check|apply}"; exit 2 ;;
esac
exit $fail
