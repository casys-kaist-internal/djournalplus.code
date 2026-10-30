#!/bin/bash
# §6.3 microbenchmarks (spec v2 of 2026-10-22; tool of the later note of the
# same day): 16 KiB buffered page writes committed in batches of FSYNC_N, one
# file per thread, measured with atomicw (TOOL=atomicw, the default: one tool
# for all eight configurations, App's doublewrite included) or fio (TOOL=fio,
# the cross-check; no App). The experiments are written as fio job files;
# for atomicw run_fio translates each job into the same atomicw run. The baselines run on the base kernel (6.8.0-base+, stock mkfs,
# as the database baselines), tau on the tau kernel; a run refuses the other
# kind (exception: EXPS=kcheck, EXT4_Raw on the tau kernel). Per run: the fio
# job file, its JSON, stderr and 1-s bandwidth logs, the device counters from
# the start to after syncfs + umount, the tau journal lines of the kernel log
# and, for tau, the open files carrying O_TAU_UNTORN; one CSV line per run in
# results.csv (fio_report.py row).
#
# Configurations (atomicw mode in brackets):
#   EXT4_Raw   stock mke2fs, default mount (ordered, delalloc) [raw]  base kernel
#   XFS_Raw    stock mkfs.xfs, default mount [raw]                    base kernel
#   EXT4_App   EXT4_Raw's file system, per-thread doublewrite file [app]   base kernel
#   XFS_App    XFS_Raw's file system, per-thread doublewrite file [app]    base kernel
#   EXT4_Data  stock mke2fs -J size=40000 (40,000 MB), data=journal   base kernel
#   ZFS        ashift=12, recordsize=16K, compression=off, atime=off  base kernel
#   tau-EXT4   tau mke2fs from codes/, mount tjournal,tjournal_size=$TAU_JOURNAL_GB;
#              fio opens its files with O_TAU_UNTORN through tau_preload.so
#   tau-XFS    tau mkfs.xfs -l tjmaxsize=${TAU_JOURNAL_GB}G (one tau journal
#              map block holds 32 GiB: the default 1G stops tau-XFS at 32 GiB),
#              mount tjournal,tjournal_size=$TAU_JOURNAL_GB
#
# Experiments (EXPS, in this order per configuration):
#   e1     OPS x THREADS_LIST, one file of TOTAL_GB/T per job. overwrite: time
#          based (RAMP + RUNTIME s) on files laid out once per T. prealloc
#          (fallocate=native), hole (fallocate=truncate), append (file_append):
#          fresh files written once, size based (FIRST_MODE=time: RUNTIME s)
#   e2     overwrite at TOP_T jobs on FILES_LIST files; the jobs write disjoint
#          2 GiB ranges of their file (TOTAL_GB/F per file)
#   sync1  e1 overwrite at TOP_T jobs with an fdatasync after every write
#   zoned  e1 overwrite at TOP_T jobs, 75% of the writes on 1% of each file
#          (ZONED_DIST), for the configurations in ZONED_CONFIGS
#   bytes  e1 overwrite at TOP_T jobs without ramp, once
#   gate   tau-EXT4 e1 overwrite at TOP_T jobs, once: pass if no pwrite takes
#          1 s and, after the journal fills, the last 60 s run within 5% of the
#          middle 60 s (fio_report.py gate)
#   kcheck EXT4_Raw e1 overwrite at TOP_T jobs on the tau kernel, against base+
#   r1     EVAL_PLAN R1, atomicw only: overwrite at TOP_T threads on R1_FILES
#          files (TOTAL_GB split evenly, laid out with atomicw --prepare), an
#          fdatasync every R1_FSYNC_N (1) writes; then R1_OPEN "F:N" cases, F
#          files open and only N written (atomicw --write-files)
# Runs: REPS_TOP at TOP_T (e1) and for e2, sync1, zoned, kcheck, r1; REPS at the
# other thread counts; bytes and gate once.
#
# Per configuration: trim the SSD, mkfs, lay out the overwrite files of every
# T and F the experiments use (sequential 1 MiB writes, not through tau), idle
# SETTLE s (after a whole-device discard the PM1735 runs slower for 4-5 min);
# prealloc, hole and append get a fresh file system per operation. FRESH_PER
# lists configurations that get a fresh one per T and F as well (ZFS: its
# copy-on-write writes would fill the untrimmed SSD). Every run: remount
# (empties the page cache and the ARC), fio, syncfs, umount; no trim between
# runs.
#
# Usage: [CONFIGS=...] [EXPS="e1 e2 sync1 zoned bytes"] [OPS=...] [THREADS_LIST="1 8 16 32 64"]
#        [FILES_LIST="1 4 16"] [REPS=1] [REPS_TOP=3] [RAMP=10] [RUNTIME=180] run_fio.sh <tag>
#        CHECK_ONLY=1: stop after the kernel and experiment checks
#        M3_TRACE=1: trace every run's fsync phases after the ramp (m3_phases.bt,
#        <run>.m3; m3_report.py tables), EVAL_PLAN M3
set -e
[ -n "$TAUFS_ENV_SOURCED" ] || { echo "Do source set_env.sh first."; exit 1; }
source "$TAUFS_BENCH/scripts/common.sh"
HERE=$TAUFS_BENCH/scripts/micro

TAG=${1:?usage: run_fio.sh <tag>}
KERNEL=$(uname -r)
TAU_KERNEL=0
[[ $KERNEL == *tjournal* ]] && TAU_KERNEL=1
if (( TAU_KERNEL )); then
  CONFIGS=${CONFIGS:-tau-EXT4 tau-XFS}
else
  CONFIGS=${CONFIGS:-EXT4_Raw XFS_Raw EXT4_Data ZFS EXT4_App XFS_App}
fi
EXPS=${EXPS:-e1 e2 sync1 zoned bytes}
TOOL=${TOOL:-atomicw}
[[ $TOOL == atomicw || " $EXPS " != *" r1 "* ]] || { echo "❌ EXPS r1 needs TOOL=atomicw"; exit 1; }
[[ $TOOL == atomicw || $TOOL == fio ]] || { echo "❌ TOOL is atomicw or fio"; exit 1; }
OPS=${OPS:-overwrite prealloc hole append}
THREADS_LIST=${THREADS_LIST:-1 8 16 32 64}
FILES_LIST=${FILES_LIST:-1 4 16}
REPS=${REPS:-1}
REPS_TOP=${REPS_TOP:-3}
RAMP=${RAMP:-10}
RUNTIME=${RUNTIME:-180}
TOTAL_GB=${TOTAL_GB:-128}
SETTLE=${SETTLE:-300}
FSYNC_N=${FSYNC_N:-64}
FIRST_MODE=${FIRST_MODE:-size}
FRESH_PER=${FRESH_PER-ZFS}
TAU_JOURNAL_GB=${TAU_JOURNAL_GB:-40}
BW_LOG=${BW_LOG:-1}
TOP_T=${TOP_T:-64}
NO_DISCARD=${NO_DISCARD:-0}  # 1: no blkdiscard and no mkfs discard (a preconditioned consumer SSD)
ZONED_CONFIGS=${ZONED_CONFIGS:-EXT4_Raw EXT4_Data tau-EXT4}
ZONED_DIST=${ZONED_DIST:-zoned:75/1:25/99}
R1_FILES=${R1_FILES:-1000 10000 100000}
R1_OPEN=${R1_OPEN:-100000:100}
R1_FSYNC_N=${R1_FSYNC_N:-1}

has() { [[ " $1 " == *" $2 "* ]]; }

# tau only on the tau kernel, the baselines only on the base kernel
for c in $CONFIGS; do
  if [[ $c == tau-* ]] || { [[ $EXPS == kcheck ]] && [[ $c == EXT4_Raw ]]; }; then
    (( TAU_KERNEL )) || { echo "❌ $c ($EXPS) runs on the tau kernel, not $KERNEL"; exit 1; }
  else
    [[ $KERNEL == 6.8.0-base+ ]] || { echo "❌ $c runs on the base kernel 6.8.0-base+, not $KERNEL"; exit 1; }
  fi
done
if has "$EXPS" gate && [[ $EXPS != gate || $CONFIGS != tau-EXT4 ]]; then
  echo "❌ gate runs alone, for tau-EXT4"; exit 1
fi
if has "$EXPS" kcheck && [[ $EXPS != kcheck || $CONFIGS != EXT4_Raw ]]; then
  echo "❌ kcheck runs alone, for EXT4_Raw"; exit 1
fi
if [[ $TOOL == fio ]] && { has "$CONFIGS" EXT4_App || has "$CONFIGS" XFS_App; }; then
  echo "❌ App runs with atomicw only"; exit 1
fi
[[ "${CHECK_ONLY:-0}" == 0 ]] || { echo "checks passed: $CONFIGS | $EXPS | $KERNEL"; exit 0; }
if [[ "${HOST_CHECK:-1}" != 0 ]]; then
  bash "$TAUFS_BENCH/scripts/host_setup.sh" check || { echo "❌ run bench/scripts/host_setup.sh apply"; exit 1; }
fi
command -v fio >/dev/null || { echo "❌ no fio"; exit 1; }   # layouts use fio either way
AW=$TAUFS_BENCH_WS/micro/atomicw
gcc -O2 -Wall -pthread -o "$AW" "$HERE/atomicw.c"
PRE=$TAUFS_BENCH_WS/micro/tau_preload.so
mkdir -p "$(dirname "$PRE")"
gcc -O2 -Wall -shared -fPIC -o "$PRE" "$HERE/tau_preload.c" -ldl
STATDEV=$(tau_stat_devs)
DEVT=$(( (0x$(stat -c %t "$DEVICE") << 20) | 0x$(stat -c %T "$DEVICE") ))   # dev_t as the jbd2 tracepoints give it
if [[ "${M3_TRACE:-0}" == 1 ]]; then   # m3_phases.bt probes kfunc:xfs, which needs the module
  command -v bpftrace >/dev/null || { echo "❌ no bpftrace"; exit 1; }
  sudo modprobe xfs
fi

RESULT_DIR=$TAU_RESULTS/micro/$(date +%Y%m%d_%H%M%S)_fio_$TAG
mkdir -p "$RESULT_DIR/runs"
cp "$0" "$HERE/tau_preload.c" "$HERE/atomicw.c" "$HERE/fio_report.py" "$HERE/m3_phases.bt" "$HERE/m3_report.py" "$RESULT_DIR/"
CSV=$RESULT_DIR/results.csv
python3 "$HERE/fio_report.py" header > "$CSV"
log_env "$RESULT_DIR/env.txt"
{
  echo "test device: $DEVICE $(cat /sys/block/$TAU_DEVICE_NAME/device/model 2>/dev/null) (stats from /sys/block/$STATDEV/stat), write_cache $(cat /sys/block/$TAU_DEVICE_NAME/queue/write_cache), NO_DISCARD=$NO_DISCARD"
  echo "kernel: $KERNEL $(uname -v); source $(readlink -f /lib/modules/$KERNEL/build)"
  echo "fio: $(fio --version)"
  echo "mkfs: baselines $STOCK_DIR (stock); tau $TAUFS_E2FSPROGS/misc/mke2fs ($(git -C "$TAUFS_E2FSPROGS" log -1 --format=%h 2>/dev/null)), $TAUFS_XFSPROGS/mkfs/mkfs.xfs ($(git -C "$TAUFS_XFSPROGS" log -1 --format=%h 2>/dev/null))"
  sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_bytes vm.dirty_background_bytes \
    vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
  echo "zfs_arc_max: $(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null)"
  echo "TOOL=$TOOL CONFIGS=$CONFIGS EXPS=$EXPS OPS=$OPS THREADS_LIST=$THREADS_LIST FILES_LIST=$FILES_LIST REPS=$REPS REPS_TOP=$REPS_TOP RAMP=$RAMP RUNTIME=$RUNTIME TOTAL_GB=$TOTAL_GB SETTLE=$SETTLE FSYNC_N=$FSYNC_N FIRST_MODE=$FIRST_MODE FRESH_PER=$FRESH_PER TAU_JOURNAL_GB=$TAU_JOURNAL_GB BW_LOG=$BW_LOG TOP_T=$TOP_T ZONED_CONFIGS=$ZONED_CONFIGS ZONED_DIST=$ZONED_DIST R1_FILES=$R1_FILES R1_OPEN=$R1_OPEN R1_FSYNC_N=$R1_FSYNC_N M3_TRACE=${M3_TRACE:-0}"
} >> "$RESULT_DIR/env.txt"
echo "=== fio: $RESULT_DIR ($CONFIGS | $EXPS | $OPS | threads $THREADS_LIST | files $FILES_LIST | $KERNEL) $(date -u --rfc-3339=seconds)"

fs_make() {
  sudo zpool destroy -f zfspool 2>/dev/null || true
  mountpoint -q "$MOUNT_DIR" && sudo umount "$MOUNT_DIR"
  local ext=lazy_itable_init=0,lazy_journal_init=0 xk=()
  if (( NO_DISCARD )); then
    ext+=,nodiscard; xk=(-K)
  else
    echo "[+] Trimming $DEVICE (blkdiscard)"
    sudo blkdiscard -f "$DEVICE"
  fi
  case $1 in
    EXT4_Raw|EXT4_App) stock_mke2fs -q -t ext4 -E "$ext" -F "$DEVICE" ;;
    EXT4_Data) stock_mke2fs -q -t ext4 -J size=40000 -E "$ext" -F "$DEVICE" ;;
    XFS_Raw|XFS_App) stock_mkfs_xfs -q -f "${xk[@]}" "$DEVICE" ;;
    tau-EXT4)
      sudo "$TAUFS_E2FSPROGS/misc/mke2fs" -q -t ext4 -E "$ext" -F "$DEVICE" ;;
    tau-XFS)
      sudo "$TAUFS_XFSPROGS/mkfs/mkfs.xfs" -q -f "${xk[@]}" -l tjmaxsize=${TAU_JOURNAL_GB}G "$DEVICE" ;;
    ZFS)
      sudo wipefs -a "$DEVICE" >/dev/null
      sudo zpool create -f -o ashift=12 -O recordsize=16K -O compression=off -O atime=off \
        -O mountpoint="$MOUNT_DIR" zfspool "$DEVICE"
      ;;
    *) echo "Unknown config $1"; exit 1 ;;
  esac
  sudo mkdir -p "$MOUNT_DIR"
  fs_mount "$1"
  sudo chown "$(id -u):$(id -g)" "$MOUNT_DIR"
}

fs_mount() {  # idempotent
  case $1 in
    # a whole-disk vdev lives on partition 1 (zpool create partitions the disk)
    ZFS) zpool list zfspool >/dev/null 2>&1 || sudo zpool import -d "${DEVICE}p1" zfspool; return ;;
  esac
  ! mountpoint -q "$MOUNT_DIR" || return 0
  case $1 in
    EXT4_Raw|EXT4_App) sudo mount -t ext4 "$DEVICE" "$MOUNT_DIR" ;;
    EXT4_Data) sudo mount -t ext4 -o data=journal "$DEVICE" "$MOUNT_DIR" ;;
    tau-EXT4)  sudo mount -t ext4 -o tjournal,tjournal_size="$TAU_JOURNAL_GB" "$DEVICE" "$MOUNT_DIR" ;;
    XFS_Raw|XFS_App) sudo mount -t xfs "$DEVICE" "$MOUNT_DIR" ;;
    tau-XFS)   sudo mount -t xfs -o tjournal,tjournal_size="$TAU_JOURNAL_GB" "$DEVICE" "$MOUNT_DIR" ;;
  esac
}

fs_umount() {  # idempotent
  case $1 in
    ZFS) ! zpool list zfspool >/dev/null 2>&1 || sudo zpool export zfspool ;;
    *)   ! mountpoint -q "$MOUNT_DIR" || sudo umount "$MOUNT_DIR" ;;
  esac
}

# kernel log lines after a marker line (the ring buffer is full: no counting)
kmark() { echo "$1" | sudo tee /dev/kmsg > /dev/null; }
klines() { sudo dmesg | awk -v m="$1" 'f { print } index($0, m) { f = 1 }'; }

devstat() { awk '{ print $5, $7, ($16 == "" ? 0 : $16) }' "/sys/block/$STATDEV/stat"; }

fs_note() {
  {
    echo "== $1 $(date -u --rfc-3339=seconds)"
    grep " $MOUNT_DIR " /proc/mounts || true
    case $1 in
      ZFS)
        sudo zpool get -H ashift,autotrim zfspool
        sudo zfs get -H recordsize,compression,atime,logbias,sync,primarycache zfspool ;;
      EXT4_Data) sudo dumpe2fs -h "$DEVICE" 2>/dev/null | grep -E '^Total journal (size|blocks)' || true ;;
    esac
    # tau rejects O_DIRECT|O_TAU_UNTORN with EINVAL: the check that tau is active
    python3 - "$MOUNT_DIR/.taucheck" <<'EOF'
import errno, os, sys
try:
    fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT | os.O_DIRECT | 0o40000000, 0o644)
    os.close(fd)
    print("O_DIRECT|O_TAU_UNTORN accepted: tau not active")
except OSError as e:
    print("O_DIRECT|O_TAU_UNTORN: " + ("EINVAL, tau active" if e.errno == errno.EINVAL else errno.errorcode[e.errno]))
EOF
    rm -f "$MOUNT_DIR/.taucheck"
    [[ $1 != tau-* ]] || sudo dmesg | grep 'TAU journal: resizing' | tail -1
  } >> "$RESULT_DIR/fs.txt" 2>&1
}

# fio job files
job_common() {
  cat <<EOF
[global]
ioengine=psync
direct=0
bs=16k
thread
group_reporting
EOF
  [[ $BW_LOG == 0 ]] || printf 'write_bw_log=%s\nlog_avg_msec=1000\n' "$RESULT_DIR/runs/$LABEL"
}

job_e1() {  # <op> <dir> <threads> <fdatasync n> <ramp> [<random_distribution>]
  local op=$1 dir=$2 t=$3 n=$4 ramp=$5 dist=$6 fsize=$(( TOTAL_GB / $3 ))g
  job_common
  printf 'directory=%s\nnrfiles=1\nfilename_format=e1.$jobnum\nfilesize=%s\nfdatasync=%s\n' "$dir" "$fsize" "$n"
  case $op in
    overwrite) printf 'rw=randwrite\ntime_based\nramp_time=%s\nruntime=%s\n' "$ramp" "$RUNTIME" ;;
    prealloc)  printf 'rw=randwrite\nfallocate=native\nsize=%s\n' "$fsize" ;;
    hole)      printf 'rw=randwrite\nfallocate=truncate\nsize=%s\n' "$fsize" ;;
    append)    printf 'rw=write\nfile_append=1\nfallocate=none\nsize=%s\n' "$fsize" ;;
  esac
  [[ $op == overwrite || $FIRST_MODE == size ]] || printf 'time_based\nruntime=%s\n' "$RUNTIME"
  [[ -z $dist ]] || printf 'random_distribution=%s\n' "$dist"
  printf '[%s]\nnumjobs=%s\n' "$op" "$t"
}

job_e2() {  # <dir> <files>: TOP_T jobs over the files, a disjoint 2 GiB range each
  local dir=$1 f=$2 k
  job_common
  printf 'rw=randwrite\nfdatasync=%s\ntime_based\nramp_time=%s\nruntime=%s\nsize=%sg\noffset_increment=%sg\n' \
    "$FSYNC_N" "$RAMP" "$RUNTIME" $(( TOTAL_GB / TOP_T )) $(( TOTAL_GB / TOP_T ))
  for (( k = 0; k < f; k++ )); do
    printf '[f%s]\nfilename=%s/e2.%s\nfilesize=%sg\nnumjobs=%s\n' "$k" "$dir" "$k" $(( TOTAL_GB / f )) $(( TOP_T / f ))
  done
}

layout_e1() {  # <dir> <threads>: the overwrite files of e1 at T, filled once
  mkdir -p "$1"
  {
    job_common | grep -v _bw_log
    printf 'bs=1m\ndirectory=%s\nnrfiles=1\nfilename_format=e1.$jobnum\nfilesize=%sg\nrw=write\nend_fsync=1\n[fill]\nnumjobs=%s\n' \
      "$1" $(( TOTAL_GB / $2 )) "$2"
  } > "$RESULT_DIR/runs/layout.fio"
  fio --output-format=terse "$RESULT_DIR/runs/layout.fio" > /dev/null
}

layout_e2() {  # <dir> <files>
  local k
  mkdir -p "$1"
  {
    job_common | grep -v _bw_log
    printf 'bs=1m\nrw=write\nend_fsync=1\n'
    for (( k = 0; k < $2; k++ )); do
      printf '[f%s]\nfilename=%s/e2.%s\nfilesize=%sg\n' "$k" "$1" "$k" $(( TOTAL_GB / $2 ))
    done
  } > "$RESULT_DIR/runs/layout.fio"
  fio --output-format=terse "$RESULT_DIR/runs/layout.fio" > /dev/null
}

layout_r1() {  # <dir> <files>: atomicw's own layout (fio cannot run 10^5 jobs)
  mkdir -p "$1"
  "$AW" --prepare --dir "$1" --files "$2" --total "${TOTAL_GB}g" --file-fmt 'r1.%d' > /dev/null
}

# the r1 run as a job text for the record; aw_args turns it into atomicw's options
job_r1() {  # <dir> <files> <files written>
  printf '# r1: atomicw only\n[r1]\ndirectory=%s\nfiles=%s\nwrite_files=%s\ntotal=%sg\nnumjobs=%s\nfdatasync=%s\nramp_time=%s\nruntime=%s\n' \
    "$1" "$2" "$3" "$TOTAL_GB" "$TOP_T" "$R1_FSYNC_N" "$RAMP" "$RUNTIME"
}

# fresh file system with the overwrite layouts of the given "t<T>" / "f<F>" /
# "r<F>" directories, then idle
fresh_fs() {  # <config> <what> <layouts...>
  local cfg=$1 what=$2 l t0
  shift 2
  echo "=== $cfg $what: mkfs $(date -u --rfc-3339=seconds)"
  fs_make "$cfg"
  fs_note "$cfg"
  for l in "$@"; do
    t0=$(date +%s)
    case $l in
      t*) layout_e1 "$MOUNT_DIR/$l" "${l#t}" ;;
      f*) layout_e2 "$MOUNT_DIR/$l" "${l#f}" ;;
      r*) layout_r1 "$MOUNT_DIR/$l" "${l#r}" ;;
    esac
    echo "--> $cfg: laid out $l (${TOTAL_GB} GiB) in $(( $(date +%s) - t0 )) s"
  done
  echo "--> settling ${SETTLE} s $(date -u +%T)"
  sleep "$SETTLE"
}

# the atomicw run of a fio job (AWARGS): same directory, files, sizes, batch,
# ramp, run time, distribution
aw_args() {  # <config> <job text> <out prefix> <mode time|size>
  local job=$2 op dir files t total fsize fmt n ramp=0 run wf=""
  op=$(grep -m1 -oE '^\[(overwrite|prealloc|hole|append)\]' <<< "$job" | tr -d '[]')
  n=$(grep -m1 '^fdatasync=' <<< "$job" | cut -d= -f2)
  if grep -q '^\[r1\]' <<< "$job"; then                         # r1: atomicw's options as written
    op=overwrite
    dir=$(grep -m1 '^directory=' <<< "$job" | cut -d= -f2)
    files=$(grep -m1 '^files=' <<< "$job" | cut -d= -f2)
    wf=$(grep -m1 '^write_files=' <<< "$job" | cut -d= -f2)
    t=$(grep -m1 '^numjobs=' <<< "$job" | cut -d= -f2)
    fsize=0; total=$(grep -m1 '^total=' <<< "$job" | cut -d= -f2 | tr -d g)
    fmt='r1.%d'
  elif [[ -n $op ]]; then                                      # e1: one file per job
    dir=$(grep -m1 '^directory=' <<< "$job" | cut -d= -f2)
    t=$(grep -m1 '^numjobs=' <<< "$job" | cut -d= -f2); files=$t
    fsize=$(grep -m1 '^filesize=' <<< "$job" | cut -d= -f2 | tr -d g)
    fmt='e1.%d'
  else                                                         # e2: F files, disjoint ranges
    op=overwrite
    files=$(grep -c '^filename=' <<< "$job")
    dir=$(dirname "$(grep -m1 '^filename=' <<< "$job" | cut -d= -f2)")
    t=$(( $(grep -m1 '^numjobs=' <<< "$job" | cut -d= -f2) * files ))
    fsize=$(grep -m1 '^filesize=' <<< "$job" | cut -d= -f2 | tr -d g)
    fmt='e2.%d'
  fi
  [[ $fsize == 0 ]] || total=$(( fsize * files ))
  grep -q '^ramp_time=' <<< "$job" && ramp=$(grep -m1 '^ramp_time=' <<< "$job" | cut -d= -f2)
  run=$(grep -m1 '^runtime=' <<< "$job" | cut -d= -f2)
  local mode=raw
  case $1 in tau-*) mode=tau ;; *_App) mode=app ;; esac
  AWARGS=(--dir "$dir" --pattern "$op" --mode "$mode" --threads "$t" --files "$files" --total "${total}g"
          --file-fmt "$fmt" --batch "$n" --warmup "$ramp" --dev "$STATDEV"
          --timeline "$3.tl" --hist "$3.hist" --label "${3##*/}")
  [[ -z $run ]] || AWARGS+=(--duration "$run")
  [[ -z $wf || $wf == "$files" ]] || AWARGS+=(--write-files "$wf")
  [[ $op == overwrite || $4 == size ]] || AWARGS+=(--time-based)
  grep -q '^random_distribution=zoned' <<< "$job" && AWARGS+=(--dist zoned)
  return 0
}

# one run: remount, the tool, syncfs, umount, counters; LABEL and JOB set by
# the caller. The device counters are read at the start, after the ramp and
# after the umount.
run_fio() {  # <config> <exp> <op> <threads> <files> <fdatasync n> <dist> <rep> <mode> <dir>
  local cfg=$1 out=$RESULT_DIR/runs/$LABEL mark t0 t1 t2 d0 d1 d2 pid ramp=0
  [[ $9 != time ]] || ramp=$(grep -m1 '^ramp_time=' <<< "$JOB" | cut -d= -f2)
  ramp=${ramp:-0}
  fs_umount "$cfg"
  drop_caches > /dev/null
  fs_mount "$cfg"
  echo "$JOB" > "$out.fio"
  mark="fio-run-$LABEL-$RANDOM"
  kmark "$mark"
  rm -f "$out.dramp" "$out.fds"
  d0=$(devstat); t0=$(date +%s.%N)
  if [[ $TOOL == atomicw ]]; then
    aw_args "$cfg" "$JOB" "$out" "$9"
    echo "$AW ${AWARGS[*]}" > "$out.cmd"
    "$AW" --csv-header > "$out.aw.csv"
    "$AW" "${AWARGS[@]}" >> "$out.aw.csv" 2> "$out.err" &
  elif [[ $cfg == tau-* ]]; then
    env LD_PRELOAD="$PRE" TAU_PREFIX="$MOUNT_DIR" TAU_PRELOAD_DEBUG=summary \
      fio --output-format=json --output="$out.json" "$out.fio" 2> "$out.err" &
  else
    fio --output-format=json --output="$out.json" "$out.fio" 2> "$out.err" &
  fi
  pid=$!
  local trp=""
  if [[ "${M3_TRACE:-0}" == 1 ]]; then   # EVAL_PLAN M3: the run's fsync phases, after the ramp
    ( sleep "$ramp"; exec sudo env BPFTRACE_MAX_MAP_KEYS=100000 bpftrace "$HERE/m3_phases.bt" "$pid" "$DEVT" ) \
      > "$out.m3" 2>&1 &
    trp=$!
  fi
  (( ramp == 0 )) || ( sleep "$ramp"; devstat > "$out.dramp" ) &
  if [[ $cfg == tau-* ]]; then   # which of fio's open files carry O_TAU_UNTORN
    ( sleep $(( ramp + 5 )); sudo env MNT="$MOUNT_DIR" P="$pid" bash -c '
        n=0; tau=0
        for fd in /proc/$P/fd/*; do
          t=$(readlink "$fd" 2>/dev/null) || continue
          [[ $t == "$MNT"/* ]] || continue
          fl=$(awk "/^flags:/{print \$2}" "/proc/$P/fdinfo/${fd##*/}" 2>/dev/null) || continue
          n=$((n + 1)); (( 8#$fl & 8#40000000 )) && tau=$((tau + 1))
        done
        echo "tau_fds=$tau/$n"' > "$out.fds" 2>/dev/null ) &
  fi
  wait "$pid"
  [[ -z $trp ]] || sudo kill -INT "$trp" 2>/dev/null || true
  t1=$(date +%s.%N); d1=$(devstat)
  wait
  sync -f "${10}"
  fs_umount "$cfg"
  t2=$(date +%s.%N); d2=$(devstat)
  {
    echo "exp=$2 config=$cfg op=$3 threads=$4 files=$5 fdatasync_n=$6 dist=$7 rep=$8 mode=$9 kernel=$KERNEL"
    echo "elapsed_s=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')"
    echo "elapsed_total_s=$(awk -v a="$t0" -v b="$t2" 'BEGIN { printf "%.1f", b - a }')"
    echo "dev_start=$d0"
    [[ ! -s $out.dramp ]] || echo "dev_ramp=$(cat "$out.dramp")"
    echo "dev_fio_end=$d1"
    echo "dev_end=$d2"
    [[ ! -s $out.fds ]] || cat "$out.fds"
  } > "$out.info"
  klines "$mark" | grep -E 'Tau_Daemon|TAU|tau_|fio-run' > "$out.tau" || true
  rm -f "$out.fds" "$out.dramp"
  python3 "$HERE/fio_report.py" row "$out" >> "$CSV"
  echo "    $LABEL: $(python3 "$HERE/fio_report.py" brief "$out") $(date -u +%T)"
}

nreps() {  # <threads>
  if (( $1 == TOP_T )); then echo "$REPS_TOP"; else echo "$REPS"; fi
}

overwrite_runs() {  # <config> <T>: e1 overwrite at T, and the TOP_T experiments
  local cfg=$1 t=$2 rep dir=$MOUNT_DIR/t$2
  if has "$EXPS" e1 && has "$OPS" overwrite; then
    for (( rep = 1; rep <= $(nreps "$t"); rep++ )); do
      LABEL="e1_${cfg}_overwrite_t${t}_f${t}_r${rep}"
      JOB=$(job_e1 overwrite "$dir" "$t" "$FSYNC_N" "$RAMP")
      run_fio "$cfg" e1 overwrite "$t" "$t" "$FSYNC_N" uniform "$rep" time "$dir"
    done
  fi
  (( t == TOP_T )) || return 0
  if has "$EXPS" sync1; then
    for (( rep = 1; rep <= REPS_TOP; rep++ )); do
      LABEL="sync1_${cfg}_overwrite_t${t}_f${t}_r${rep}"
      JOB=$(job_e1 overwrite "$dir" "$t" 1 "$RAMP")
      run_fio "$cfg" sync1 overwrite "$t" "$t" 1 uniform "$rep" time "$dir"
    done
  fi
  if has "$EXPS" zoned && has "$ZONED_CONFIGS" "$cfg"; then
    for (( rep = 1; rep <= REPS_TOP; rep++ )); do
      LABEL="zoned_${cfg}_overwrite_t${t}_f${t}_r${rep}"
      JOB=$(job_e1 overwrite "$dir" "$t" "$FSYNC_N" "$RAMP" "$ZONED_DIST")
      run_fio "$cfg" zoned overwrite "$t" "$t" "$FSYNC_N" "$ZONED_DIST" "$rep" time "$dir"
    done
  fi
  if has "$EXPS" bytes; then
    LABEL="bytes_${cfg}_overwrite_t${t}_f${t}_r1"
    JOB=$(job_e1 overwrite "$dir" "$t" "$FSYNC_N" 0)
    run_fio "$cfg" bytes overwrite "$t" "$t" "$FSYNC_N" uniform 1 time "$dir"
  fi
  if has "$EXPS" gate; then
    LABEL="gate_${cfg}_overwrite_t${t}_f${t}_r1"
    JOB=$(job_e1 overwrite "$dir" "$t" "$FSYNC_N" "$RAMP")
    run_fio "$cfg" gate overwrite "$t" "$t" "$FSYNC_N" uniform 1 time "$dir"
    python3 "$HERE/fio_report.py" gate "$RESULT_DIR/runs/$LABEL" | tee "$RESULT_DIR/gate.txt"
  fi
  if has "$EXPS" kcheck; then
    for (( rep = 1; rep <= REPS_TOP; rep++ )); do
      LABEL="kcheck_${cfg}_overwrite_t${t}_f${t}_r${rep}"
      JOB=$(job_e1 overwrite "$dir" "$t" "$FSYNC_N" "$RAMP")
      run_fio "$cfg" kcheck overwrite "$t" "$t" "$FSYNC_N" uniform "$rep" time "$dir"
    done
  fi
}

e2_runs() {  # <config> <F>
  local cfg=$1 f=$2 rep
  for (( rep = 1; rep <= REPS_TOP; rep++ )); do
    LABEL="e2_${cfg}_overwrite_t${TOP_T}_f${f}_r${rep}"
    JOB=$(job_e2 "$MOUNT_DIR/f$f" "$f")
    run_fio "$cfg" e2 overwrite "$TOP_T" "$f" "$FSYNC_N" uniform "$rep" time "$MOUNT_DIR/f$f"
  done
}

r1_runs() {  # <config>: R1_FILES files written, then the R1_OPEN "F:N" cases
  local cfg=$1 f n c rep
  for c in $(for f in $R1_FILES; do echo "$f:$f"; done) $R1_OPEN; do
    f=${c%%:*}; n=${c##*:}
    for (( rep = 1; rep <= REPS_TOP; rep++ )); do
      LABEL="r1_${cfg}_overwrite_t${TOP_T}_f${f}_w${n}_r${rep}"
      JOB=$(job_r1 "$MOUNT_DIR/r$f" "$f" "$n")
      run_fio "$cfg" r1 overwrite "$TOP_T" "$f" "$R1_FSYNC_N" uniform "$rep" time "$MOUNT_DIR/r$f"
    done
  done
}

first_runs() {  # <config> <op> <T>: fresh files every run
  local cfg=$1 op=$2 t=$3 rep
  for (( rep = 1; rep <= $(nreps "$t"); rep++ )); do
    LABEL="e1_${cfg}_${op}_t${t}_f${t}_r${rep}"
    fs_mount "$cfg"
    rm -rf "$MOUNT_DIR/w"; mkdir -p "$MOUNT_DIR/w"
    JOB=$(job_e1 "$op" "$MOUNT_DIR/w" "$t" "$FSYNC_N" 0)
    run_fio "$cfg" e1 "$op" "$t" "$t" "$FSYNC_N" uniform "$rep" "$FIRST_MODE" "$MOUNT_DIR/w"
  done
}

for CONFIG in $CONFIGS; do
  per=0
  has "$FRESH_PER" "$CONFIG" && per=1
  # the overwrite family: e1 overwrite and the TOP_T runs (files per T), e2 (per F)
  ts=()
  { has "$EXPS" e1 && has "$OPS" overwrite; } && for t in $THREADS_LIST; do ts+=("$t"); done
  for x in sync1 zoned bytes gate kcheck; do
    { has "$EXPS" $x && ! has "${ts[*]}" "$TOP_T"; } && ts+=("$TOP_T")
  done
  fs=()
  has "$EXPS" e2 && for f in $FILES_LIST; do fs+=("$f"); done
  rs=()   # r1 layouts: R1_FILES and the F of every R1_OPEN case
  if has "$EXPS" r1; then
    for f in $R1_FILES $(for c in $R1_OPEN; do echo "${c%%:*}"; done); do has "${rs[*]}" "$f" || rs+=("$f"); done
  fi
  if (( ${#ts[@]} + ${#fs[@]} + ${#rs[@]} )); then
    if (( per )); then
      for t in "${ts[@]}"; do fresh_fs "$CONFIG" "t$t" "t$t"; overwrite_runs "$CONFIG" "$t"; done
      for f in "${fs[@]}"; do fresh_fs "$CONFIG" "f$f" "f$f"; e2_runs "$CONFIG" "$f"; done
      if (( ${#rs[@]} )); then
        lay=(); for f in "${rs[@]}"; do lay+=("r$f"); done
        fresh_fs "$CONFIG" r1 "${lay[@]}"; r1_runs "$CONFIG"
      fi
    else
      lay=()
      for t in "${ts[@]}"; do lay+=("t$t"); done
      for f in "${fs[@]}"; do lay+=("f$f"); done
      for f in "${rs[@]}"; do lay+=("r$f"); done
      fresh_fs "$CONFIG" overwrite "${lay[@]}"
      for t in "${ts[@]}"; do overwrite_runs "$CONFIG" "$t"; done
      for f in "${fs[@]}"; do e2_runs "$CONFIG" "$f"; done
      (( ${#rs[@]} == 0 )) || r1_runs "$CONFIG"
    fi
  fi
  # first writes
  if has "$EXPS" e1; then
    for OP in $OPS; do
      [[ $OP != overwrite ]] || continue
      if (( per )); then
        for t in $THREADS_LIST; do fresh_fs "$CONFIG" "$OP t$t"; first_runs "$CONFIG" "$OP" "$t"; done
      else
        fresh_fs "$CONFIG" "$OP"
        for t in $THREADS_LIST; do first_runs "$CONFIG" "$OP" "$t"; done
      fi
    done
  fi
  fs_umount "$CONFIG" || true
  [[ $CONFIG != ZFS ]] || sudo zpool destroy -f zfspool 2>/dev/null || true
done
python3 "$HERE/fio_report.py" tables "$RESULT_DIR" -o "$RESULT_DIR/tables.md" > /dev/null || true
echo "=== done: $RESULT_DIR $(date -u --rfc-3339=seconds)"
