#!/bin/bash
# EVAL_PLAN R2 (recovery time), method B (decided 2026-11-02): the database runs
# in a qemu VM with the test NVMe (PM1735, no volatile write cache) passed through
# (vfio-pci, tools/qemu/run_vm.sh, tools/tautest/host/vm.sh), and the crash is a
# SIGKILL of qemu while the load runs: nothing reaches the device after it, as in
# a power cut, so τ's journal is recovered as after a real one (the host-side
# shutdown ioctl of run_recovery.sh let τ keep writing and drain at umount).
# Baselines boot the guest on 6.8.0-base+, τ configurations on the τ kernel; the
# same kernel boots again for the recovery. Per configuration (FS_GROUPS with
# FS_FPWON / FS_FPWOFF as in run_main.sh) and per crash time in CRASH_TIMES (300
# 304 308 s into the load: one trial each, spread over PG's checkpoint cycle):
#   1. host: the PM1735 back on the nvme driver, trim and restore of the image,
#      then the device to vfio-pci (the host, on base+, cannot mount τ file
#      systems; PG's settings go into postgresql.conf in the guest after its
#      mount, MySQL takes them on the command line)
#   2. guest (64 GB from the host's 1 GiB huge pages, 32 vCPUs on two nodes):
#      mount, DB start with the benchmark settings, WARMUP_TIME (600 s) of the
#      64-thread load, then the load again and CRASH_AFTER s into it the WAL/redo
#      position and SIGKILL of qemu
#   3. the guest boots again; timed inside it: the mount (τ's journal replay on τ
#      configurations, its dmesg kept) and the DB start until it accepts
#      connections (PG pg_ctl -w with the end-of-recovery checkpoint; MySQL until
#      mysqladmin ping answers); then a clean shutdown and the device back to nvme
# Results: $TAU_RESULTS/recovery_vm/<db>/<ts>/: per trial <label>.times and the
# guest logs (warm-up, load, server before the crash, restart, mount dmesg), the
# console log; summary.md (recovery_report.py). Never `timeout` around guest work:
# long guest steps run detached and the host polls their markers with its own
# deadline.
# Usage: [FS_GROUPS=ext4 FS_FPWON=ext4 FS_FPWOFF=] [CRASH_TIMES="300 304 308"]
#        [WARMUP_TIME=600] [WORKLOAD=oltp_write_only] [IMAGE_KEY=t16_r32000000]
#        run_recovery_vm.sh <postgres|mysql>
set -e
DBMS="${1:-}"
[[ "$DBMS" == postgres || "$DBMS" == mysql ]] || { echo "Usage: $0 <postgres|mysql>"; exit 1; }
[ -n "$TAUFS_ENV_SOURCED" ] || { echo "Do source set_env.sh first."; exit 1; }
FS_GROUPS="${FS_GROUPS-ext4}"
FS_FPWON="${FS_FPWON-ext4}"
FS_FPWOFF="${FS_FPWOFF-}"
CRASH_TIMES="${CRASH_TIMES:-300 304 308}"
WARMUP_TIME=${WARMUP_TIME:-600}
WORKLOAD=${WORKLOAD:-oltp_write_only}
THREADS=64
source "$TAUFS_BENCH/scripts/common.sh"
source "$TAUFS_BENCH/scripts/$DBMS/api.sh"
set +e   # the api scripts set -e; failures are handled per step below
TABLE=$MAIN_TABLES
ROWS=$MAIN_ROWS_PER_TABLE
IMAGE_KEY=${IMAGE_KEY:-$(main_image_key)}
BACKUP_DIR=${BACKUP_DIR:-$TAU_BACKUP_ROOT/sysbench/$DBMS}
DBNAME="main_t${TABLE}"
BDF=0000:86:00.0
PM1735="SAMSUNG MZPLJ3T2HBJR-00007"
W=$(cd "$TAUFS_BENCH/.." && pwd)
VMSH=$W/tools/tautest/host/vm.sh
GUEST=$TAUFS_BENCH/scripts/sysbench/recovery_vm_guest.sh
BASE_KERNEL=${BASE_KERNEL:-$HOME/codes/linux-6.8.0plus-build}
TAU_KERNEL=${TAU_KERNEL:-$W/codes/djournalplus-kernel.code}
# an initrd with that build's own modules: the guest's root is btrfs (a module), and
# an initrd of another τ build carries modules the kernel rejects. One per build
# number of the tree's bzImage: a copy of /boot/initrd.img-6.8.0tjournal+ made
# while the host has that build installed (#1979: rebuilt from an older initrd)
TAU_BUILD=$(strings "$TAU_KERNEL/arch/x86/boot/bzImage" 2>/dev/null | grep -m1 '^6\.8\.0tjournal' | grep -oE '#[0-9]+' | tr -d '#')
TAU_INITRD=${TAU_INITRD:-$W/tools/qemu/vm_imgs/initrd.img-6.8.0tjournal+-$TAU_BUILD}
export VM_MEM=64G VM_NUMA=1 VM_HUGEPAGES=1 BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}
export VM_QEMU_DIR=${VM_QEMU_DIR:-$W/tools/qemu/qemu-7.2.1/build-numa}
export VM_IMAGE=${VM_IMAGE:-vm_imgs/r2-guest.qcow2}
for FS in $FS_GROUPS; do
  [[ -f "$(fs_image $FS "$IMAGE_KEY" "$BACKUP_DIR")" ]] || { echo "❌ Missing image $(fs_image $FS "$IMAGE_KEY" "$BACKUP_DIR")"; exit 1; }
  [[ "$FS" != *tau* || -f "$TAU_INITRD" ]] || { echo "❌ no τ initrd $TAU_INITRD"; exit 1; }
done
[[ "$(cat /sys/bus/pci/devices/$BDF/device 2>/dev/null)" ]] || { echo "❌ no PCI device $BDF"; exit 1; }
OUT="$TAU_RESULTS/recovery_vm/$DBMS/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
export VM_LOG=$OUT/console.log
exec > >(tee -a "$OUT/run.log") 2>&1
cp "$0" "$GUEST" "$OUT/"
echo "=== R2 (VM, qemu SIGKILL): $DBMS $WORKLOAD, FS $FS_GROUPS (FPW/DWB on: $FS_FPWON; off: $FS_FPWOFF)," \
  "crash at $CRASH_TIMES s, warm-up $WARMUP_TIME s, image $IMAGE_KEY $(date -u --rfc-3339=seconds)"
log_env "$OUT/env.txt"
source "$VMSH"
set +u

now() { date +%s.%N; }
g() { vm_ssh "bash ~/r2/recovery_vm_guest.sh $*"; }
fail() { echo "===== TRIAL FAILED: $* $(date -u +%T)"; vm_kill; to_nvme; return 1; }

# the PM1735 on the nvme driver, and DEVICE/TAU_DEVICE set to its namespace
to_nvme() {
  local i d
  [[ "$(basename "$(readlink /sys/bus/pci/devices/$BDF/driver)")" == nvme ]] ||
    bash "$W/tools/qemu/passthrough.sh" $BDF reset > /dev/null
  for (( i = 0; i < 60; i++ )); do
    for d in /sys/bus/pci/devices/$BDF/nvme/nvme*/nvme*n1; do
      [[ -e "$d" ]] || continue
      d=$(basename "$d" | sed -E 's/c[0-9]+n/n/')
      if [[ -b /dev/$d && "$(cat /sys/block/$d/device/model 2>/dev/null | xargs)" == "$PM1735" ]]; then
        DEVICE=/dev/$d; TAU_DEVICE=/dev/$d; TAU_DEVICE_NAME=$d; return 0
      fi
    done
    sleep 1
  done
  echo "❌ the PM1735 did not come back on nvme"; return 1
}
to_vfio() { bash "$W/tools/qemu/passthrough.sh" $BDF > /dev/null; }

boot() {  # <fs>: the guest on the kernel this configuration needs
  if [[ "$1" == *tau* ]]; then
    TAUFS_KERNEL=$TAU_KERNEL VM_INITRD=$TAU_INITRD
  else
    TAUFS_KERNEL=$BASE_KERNEL VM_INITRD=/boot/initrd.img-6.8.0-base+
  fi
  export TAUFS_KERNEL VM_INITRD
  vm_boot || return 1
  vm_scp "$GUEST" jhlee@localhost:r2/recovery_vm_guest.sh > /dev/null 2>&1 ||
    { vm_ssh 'mkdir -p ~/r2' && vm_scp "$GUEST" jhlee@localhost:r2/recovery_vm_guest.sh > /dev/null; } || return 1
  vm_ssh sync   # anything copied in must be on disk before a kill
  g prep
}

wait_marker() {  # <name> <deadline s>: until the guest's sysbench marker appears
  local t0=$SECONDS
  until vm_ssh "test -f ~/r2/$1.done" 2>/dev/null; do
    (( SECONDS - t0 < $2 )) || { echo "no ~/r2/$1.done after $2 s"; return 1; }
    sleep 5
  done
}

case "$DBMS" in
  postgres)
    SB=(--db-driver=pgsql --auto_inc=on --pgsql-host=127.0.0.1 --pgsql-port="$PG_PORT"
        --pgsql-user="$PGUSER" --pgsql-db="$DBNAME")
    # in the guest after its mount: the host (base+) cannot mount τ file systems
    db_settings() { g pg_conf full_page_writes=$FPW shared_buffers=$PG_SHARED_BUFFERS max_wal_size=$PG_MAX_WAL_SIZE; }
    db_start() { g pg_start "$1"; }
    db_pos() { g pos_pg "$DBNAME"; }
    db_stop() { g pg_stop; }
    LOGFILE=pg.log
    ;;
  mysql)
    SB=(--db-driver=mysql --mysql-user=root --mysql-socket=/mnt/temp/mysql_data/mysql.sock --mysql-db="$DBNAME")
    MYARGS="--innodb_buffer_pool_size=$MY_BUFFER_POOL_SIZE --innodb_redo_log_capacity=$MY_REDO_LOG_CAPACITY"
    MYARGS="$MYARGS --innodb_flush_method=$MY_FLUSH_METHOD --innodb_log_spin_cpu_pct_hwm=$MY_LOG_SPIN_CPU_PCT_HWM"
    [[ "$MY_BINLOG" == OFF ]] && MYARGS="$MYARGS --disable-log-bin"
    db_settings() { :; }
    db_start() { g my_start "$1" "$DBW" $MYARGS; }
    db_pos() { g pos_my; }
    db_stop() { g my_stop; }
    LOGFILE=mysqld.err
    ;;
esac
SB+=(--tables=$TABLE --table-size=$ROWS --rand-type=special --threads=$THREADS --report-interval=10)

trial() {  # FS FPW crash_after
  local T="$OUT/$LABEL.times" s t b f
  echo "=== $LABEL: restoring ${FS}_${IMAGE_KEY} $(date -u +%T)"
  vm_kill; to_nvme || return 1
  [[ -s "$OUT/device.txt" ]] || echo "device $BDF $DEVICE vwc $(sudo nvme id-ctrl "$DEVICE" 2>/dev/null | awk '/^vwc /{print $3}')" \
    | tee "$OUT/device.txt"
  restore_filesystem $FS "$IMAGE_KEY" "$BACKUP_DIR" > "$OUT/$LABEL.restore.log" 2>&1 || { fail restore; return 1; }
  DBW=OFF; [[ "$FPW" == on ]] && DBW=ON
  to_vfio || { fail vfio; return 1; }
  echo "fs=$FS fpw=$FPW crash_after_s=$CRASH_AFTER threads=$THREADS warmup_s=$WARMUP_TIME workload=$WORKLOAD" > "$T"
  b=$(boot $FS) || { echo "$b"; fail boot; return 1; }
  echo "$b" | tee -a "$T"
  g mount $FS ~/r2/mount0 > /dev/null || { fail mount; return 1; }
  db_settings >> "$OUT/$LABEL.settings" || { fail settings; return 1; }
  db_start "~/r2/$LOGFILE.0" > /dev/null || { fail "db start"; return 1; }
  echo "--> warm-up ${WARMUP_TIME} s $(date -u +%T)"
  g sb warmup $WORKLOAD "${SB[*]}" --time=$WARMUP_TIME --rand-seed=1 run > /dev/null
  wait_marker warmup $((WARMUP_TIME + 300)) || { fail warm-up; return 1; }
  echo "--> load, crash in ${CRASH_AFTER} s $(date -u +%T)"
  g sb load $WORKLOAD "${SB[*]}" --time=$((CRASH_AFTER + 600)) --rand-seed=$((2000 + CRASH_AFTER)) run > /dev/null
  s=$(now)
  while [[ $(awk -v a="$(now)" -v b="$s" 'BEGIN {print (a - b >= '"$CRASH_AFTER"') ? 1 : 0}') == 0 ]]; do sleep 0.2; done
  echo "before_crash $(db_pos)" >> "$T"
  # the guest's logs so far, fetched before the kill (they stay in the guest image too)
  # (the load and server logs too: what the guest has not synced is lost in the crash)
  vm_scp jhlee@localhost:r2/warmup.log "$OUT/$LABEL.warmup.log" > /dev/null 2>&1
  vm_scp jhlee@localhost:r2/load.log "$OUT/$LABEL.sysbench.log" > /dev/null 2>&1
  vm_scp "jhlee@localhost:r2/$LOGFILE.0" "$OUT/$LABEL.server.log" > /dev/null 2>&1
  t=$(now)
  vm_crash > /dev/null
  echo "crash_epoch=$t" >> "$T"
  vm_kill   # waits until qemu is gone and vfio has released the device
  echo "--> crashed $(date -u +%T); boot again, mount, DB start"
  boot $FS > /dev/null || { fail reboot; return 1; }
  b=$(g mount $FS ~/r2/mount1) || { echo "$b"; fail "mount after crash"; return 1; }
  echo "$b" | tee -a "$T"
  b=$(db_start "~/r2/$LOGFILE.restart") || { echo "$b"; fail "db start after crash"; return 1; }
  echo "db_start_s=$b" | tee -a "$T"
  echo "after_restart $(db_pos)" >> "$T"
  for f in mount1.dmesg "$LOGFILE.restart"; do
    vm_scp "jhlee@localhost:r2/$f" "$OUT/$LABEL.${f//\//_}" > /dev/null 2>&1
  done
  [[ -f "$OUT/$LABEL.$LOGFILE.restart" ]] && cp "$OUT/$LABEL.$LOGFILE.restart" "$OUT/$LABEL.restart.log"
  [[ "$FS" == *tau* ]] && grep -i 'tau' "$OUT/$LABEL.mount1.dmesg" | head -20 | sed 's/^/tau_dmesg /' >> "$T"
  cat "$T"
  db_stop; g umount
  vm_kill; to_nvme
  clear_fs $FS "$DEVICE" > /dev/null 2>&1
}

for FS in $FS_GROUPS; do
  for FPW in on off; do
    if [[ "$FPW" == off && " $FS_FPWOFF " != *" $FS "* ]] || [[ "$FPW" == on && " $FS_FPWON " != *" $FS "* ]]; then
      continue
    fi
    for CRASH_AFTER in $CRASH_TIMES; do
      LABEL="${DBMS}_recovery_${FS}_fpw_${FPW}_t${TABLE}_c${THREADS}_x${CRASH_AFTER}"
      trial || echo "===== $LABEL failed, next trial $(date -u +%T)"
    done
  done
done
vm_kill; to_nvme
python3 "$TAUFS_BENCH/scripts/sysbench/recovery_report.py" "$OUT" > "$OUT/summary.md" || true
echo "=== done $(date -u --rfc-3339=seconds) -> $OUT"
