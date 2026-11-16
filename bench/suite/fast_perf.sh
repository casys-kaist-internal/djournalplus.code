#!/bin/bash
# The fast test's libra09 performance half, for one τ kernel version (the user, 11-16: every τ kernel change gets
# a fast test, ~6 h with libra08's correctness half running in parallel; the paper's numbers come from the full
# test). It runs on the τ kernel under test and the PM1735 (the 990 PRO is for the full test only), and only calls
# the existing tools: sysbench/run_main.sh, benchbase/run_tpcc.sh, micro/run_fio.sh (the v2 micro tool),
# sysbench/parse_main.py, plus fio on the raw test device for the guard. Their default paths are not changed.
#
# Steps (STEPS, default "fp0 fp1 fp2 fp3 fp4"; about 4.6 h on libra09, README.md has the estimate per step):
#   fp0  ref guard, on the kernel under test:
#          a. the raw PM1735 with fio, no file system: 16 KiB randwrite QD32 x 4 jobs, then 16 KiB writes at QD1,
#             60 s each (the device alone, ~2.5 min);
#          b. KCHECK: PG sysbench oltp_write_only 64 threads on stock EXT4 (Raw), 10-min warm-up + 5 min
#             (run_main.sh KCHECK=1, run names -kcheck; never baseline data).
#        The first fast run of REF_VERSION (default beta) only records them. Later runs go on only if b is within
#        ±3% of that run (GUARD=strict, the default), or if a's randwrite IOPS is within ±5% (GUARD=device: the
#        device holds even when the kernel under test moves the stock EXT4 path). Otherwise the run stops.
#   fp1  micro, run_fio.sh as phase A's v2: τ-EXT4 and τ-XFS x e1 overwrite and append (first writes, time based)
#        x T1 and T64, and sync1 (an fdatasync per write) at T64, 60 s each; sync1 at T1 is a second run_fio.sh
#        call (FP1_SYNC1_T1=0 leaves it out, ~17 min less).
#   fp2  sysbench oltp_write_only 64 threads, 10-min warm-up + 5 min, PG and MySQL x τ-EXT4 and τ-XFS (the main
#        _seg16m images, 4 restores).
#   fp3  TPC-C 1,100 WH, 64 terminals, 10-min warm-up + 5 min, PG and MySQL x τ-EXT4 (2 restores).
#   fp4  hygiene: the boot's kernel log (journalctl -k -b 0), SMART before/after, discards, 1 GiB huge pages,
#        linger, the timer services that ran during the run. τ flags and tjournal of every τ run are read by
#        fast_report.py from the runs' own .spec/.tau/results.csv lines.
# Verdict (fast_report.py report): FAIL on a kernel fault line, a failed step, τ inactive in a τ run, a SMART critical
# warning or new media errors; STOPPED on the guard; else PASS. Performance against the previous version's fast run
# only warns: DB ±3%, micro ±5%, p99 ±10%. τ÷App and τ÷Raw use the beta baselines (baselines_<host>.csv), which are
# not measured again.
#
# Input: VERSION (beta, v1.0, ...) and its expected kernel in bench/suite/versions/<VERSION>.env (KERNEL_COMMIT,
# UNAME_R, UNAME_V, BZIMAGE_MD5, CONFIG_MD5, E2FSPROGS, XFSPROGS), each overridable as EXPECT_<name>. If the running
# kernel differs (uname -r/-v, /boot image and config md5, the image's banner, tau_journal present with
# tau_shrink_seeks 32) or the τ mkfs trees are elsewhere, the run stops before it writes anything.
# Output: $TAU_RESULTS/versions/<VERSION>/fast/<UTC>/: MANIFEST.txt, REPORT.md, metrics.json, fast.log, STATUS,
# checks/, raw_fio/, and the tools' run directories (TAU_RESULTS points there for them). run_tpcc.sh rewrites the
# tracked bench/results/<host>/SUMMARY.md at its end; this script puts it back after each TPC-C run.
# During the run a kernel oops or soft lockup reboots the host (kernel.panic=30, panic_on_oops=1, softlockup_panic=1,
# as phase A; AUTOREBOOT=0 leaves them); STATUS then stays "running" and the report says the run did not finish.
# DRY=1: the kernel and host checks are made and reported (a mismatch is reported, not fatal), every command is
# printed, nothing is run that writes, starts a database or changes a setting, and no output directory is made.
#
# Usage: VERSION=<v> [PREV_VERSION=<v>] [REF_VERSION=beta] [GUARD=strict|device] [STEPS="fp0 ..."] [FP1_SYNC1_T1=0]
#        [DRY=1] bench/suite/fast_perf.sh            (from anywhere; nohup setsid ... & for a real run)
# Parsed whole first.
{
set -u
SELF=$(realpath "$0"); SUITE=$(dirname "$SELF"); ROOT=$(cd "$SUITE/../.." && pwd)
cd "$ROOT" || exit 1
VERSION=${VERSION:?set VERSION: beta, v1.0, ...}
DRY=${DRY:-0} STEPS=${STEPS:-fp0 fp1 fp2 fp3 fp4} REF_VERSION=${REF_VERSION:-beta} GUARD=${GUARD:-strict}
FP1_SYNC1_T1=${FP1_SYNC1_T1:-1} AUTOREBOOT=${AUTOREBOOT:-1} PREV_VERSION=${PREV_VERSION:-}
PM1735="SAMSUNG MZPLJ3T2HBJR-00007"
TIMERS="apt-daily.timer apt-daily-upgrade.timer man-db.timer e2scrub_all.timer fwupd-refresh.timer mdcheck_start.timer
  mdcheck_continue.timer update-notifier-download.timer snapd.snap-repair.timer dpkg-db-backup.timer logrotate.timer
  motd-news.timer"
PRE=()   # the lines before the output directory exists; they open fast.log
say() { local l; l="===== $* $(date -u --rfc-3339=seconds)"; echo "$l"; PRE+=("$l"); }
die() { echo "===== FAILED: $* $(date -u --rfc-3339=seconds)"; exit 2; }
for s in $STEPS; do [[ " fp0 fp1 fp2 fp3 fp4 " == *" $s "* ]] || die "no step '$s' (fp0 fp1 fp2 fp3 fp4)"; done
[[ $GUARD == strict || $GUARD == device ]] || die "GUARD is strict or device"
[[ $DRY == 1 ]] && say "DRY run: checks and commands only, nothing is run or written"

# 1. The running kernel must be VERSION's
VENV=$SUITE/versions/$VERSION.env
[[ -f $VENV ]] || die "no $VENV: write the version's expected kernel first"
source "$VENV"
for k in KERNEL_COMMIT UNAME_R UNAME_V BZIMAGE_MD5 CONFIG_MD5 E2FSPROGS XFSPROGS; do
  e=EXPECT_$k; [[ -n ${!e:-} ]] && printf -v "$k" '%s' "${!e}"
  [[ -n ${!k:-} ]] || die "$k is empty for $VERSION ($VENV, or EXPECT_$k)"
done
KR=$(uname -r) KV=$(uname -v) KIMG=/boot/vmlinuz-$(uname -r)
bad=()
[[ $KR == "$UNAME_R" ]] || bad+=("uname -r is $KR, expected $UNAME_R")
[[ $KV == "$UNAME_V" ]] || bad+=("uname -v is '$KV', expected '$UNAME_V'")
bi=$(sed -n 's/.*BOOT_IMAGE=\([^ ]*\).*/\1/p' /proc/cmdline)
[[ ${bi##*/} == "vmlinuz-$KR" ]] || bad+=("the boot image is ${bi:-unknown}, not vmlinuz-$KR")
m=$(md5sum < "$KIMG" 2> /dev/null | cut -c1-32)
[[ $m == "$BZIMAGE_MD5" ]] || bad+=("$KIMG md5 is ${m:-unreadable}, expected $BZIMAGE_MD5")
m=$(md5sum < "/boot/config-$KR" 2> /dev/null | cut -c1-32)
[[ $m == "$CONFIG_MD5" ]] || bad+=("/boot/config-$KR md5 is ${m:-unreadable}, expected $CONFIG_MD5")
banner=$(strings "$KIMG" 2> /dev/null | awk -v r="$UNAME_R (" 'index($0, r) == 1 { print; exit }')
[[ -n $banner && $banner == *"$UNAME_V" ]] || bad+=("$KIMG's version banner '${banner:-none}' does not end in '$UNAME_V'")
[[ -d /sys/module/tau_journal ]] || bad+=("no /sys/module/tau_journal: not a τ kernel")
seeks=$(cat /sys/module/tau_journal/parameters/tau_shrink_seeks 2> /dev/null)
[[ $seeks == 32 ]] || bad+=("tau_shrink_seeks is '${seeks:-absent}', not 32 ((가), the user 11-08)")
for p in e2fsprogs:$E2FSPROGS xfsprogs-dev:$XFSPROGS; do
  h=$(git -C codes/${p%%:*} rev-parse HEAD 2> /dev/null)
  [[ -n $h && $h == ${p#*:}* ]] || bad+=("codes/${p%%:*} is at ${h:0:12}, expected ${p#*:} (the τ mkfs of fp1)")
done
if (( ${#bad[@]} )); then
  for b in "${bad[@]}"; do say "kernel check: $b"; done
  [[ $DRY == 1 ]] || die "the running kernel or τ mkfs is not $VERSION's: nothing was run or written"
  say "DRY: a real run stops here"
else
  say "kernel check: $KR $KV is $VERSION (commit ${KERNEL_COMMIT:0:12}, bzImage md5 $BZIMAGE_MD5)"
fi

# 2. The host: the PM1735, nothing else running, linger, huge pages; timers in the run's window
unset TAU_TARGET_DISK          # libra09.env's default test device: the PM1735 (the 990 is for the full test)
set +u; source set_env.sh > /dev/null; rc=$?; set -u   # set_env.sh reads variables that may be unset
(( rc == 0 )) || die "set_env.sh"
SUMMARY=$TAUFS_BENCH/results/$TAU_HOST/SUMMARY.md
VROOT=$TAU_RESULTS/versions
hbad=()
[[ -n ${TAU_DEVICE:-} ]] || hbad+=("no test device from set_env.sh")
[[ $(cat /sys/block/${TAU_DEVICE_NAME:-none}/device/model 2> /dev/null | xargs) == "$PM1735" ]] \
  || hbad+=("the test device ${TAU_DEVICE:-none} is not the PM1735")
busy=$(pgrep -a -x 'postgres|mysqld|fio|sysbench|java|qemu-system-x86_64' | head -3)
[[ -z $busy ]] || hbad+=("already running: $(echo $busy)")
lg=$(loginctl show-user "$(id -un)" -p Linger --value 2> /dev/null)
[[ $lg == yes ]] || hbad+=("linger is '${lg:-off}': logind would remove PG's shared memory at an SSH logout (11-15)")
hp=""
for n in /sys/devices/system/node/node*/hugepages/hugepages-1048576kB; do
  nr=$(cat $n/nr_hugepages) fr=$(cat $n/free_hugepages); hp+="$(basename "$(dirname "$(dirname "$n")")") $fr/$nr free; "
  [[ $nr -gt 0 && $nr == "$fr" ]] || hbad+=("1 GiB huge pages $(dirname "$(dirname "$n")"): $fr of $nr free")
done
EST=(fp0:32 fp1:$(( FP1_SYNC1_T1 == 1 ? 61 : 44 )) fp2:112 fp3:61 fp4:3)
ETA=0; for x in "${EST[@]}"; do [[ " $STEPS " == *" ${x%%:*} "* ]] && ETA=$(( ETA + ${x#*:} )); done
now=$(date +%s); tw=()
for t in $TIMERS; do
  nx=$(systemctl show "$t" -p NextElapseUSecRealtime --value 2> /dev/null)
  [[ -n $nx && $nx != n/a ]] || continue
  e=$(date -d "$nx" +%s 2> /dev/null) || continue
  (( e >= now && e <= now + ETA * 60 )) && tw+=("$t at $(TZ=Asia/Seoul date -d @$e '+%m-%d %H:%M KST')")
done
say "plan: $STEPS, about $ETA min (ends ~$(TZ=Asia/Seoul date -d @$(( now + ETA * 60 )) '+%m-%d %H:%M KST')), test device ${TAU_DEVICE:-none}, guard $GUARD against $REF_VERSION"
(( ${#tw[@]} )) && say "warning: timers due within the run: ${tw[*]}"
if (( ${#hbad[@]} )); then
  for b in "${hbad[@]}"; do say "host check: $b"; done
  [[ $DRY == 1 ]] || die "the host is not ready: nothing was run or written"
  say "DRY: a real run stops here"
fi

# 3. The output directory; the tools write their runs into it
UTC=$(date -u +%Y%m%d_%H%M%S)
OUT=$VROOT/$VERSION/fast/$UTC
latest() {  # newest fast run of a version with metrics.json (not this run)
  local d
  for d in $(ls -td "$VROOT/$1"/fast/*/ 2> /dev/null); do
    [[ ${d%/} != "$OUT" && -f ${d%/}/metrics.json ]] && { echo "${d%/}"; return; }
  done
}
REF=$(latest "$REF_VERSION")
if [[ -z $PREV_VERSION ]]; then   # the newest fast run of another version, else this version's last
  PREVD=$(for d in $(ls -td "$VROOT"/*/fast/*/ 2> /dev/null); do
            [[ ${d%/} != "$OUT" && -f ${d%/}/metrics.json && $d != "$VROOT/$VERSION/"* ]] && { echo "${d%/}"; break; }
          done)
  [[ -n $PREVD ]] || PREVD=$(latest "$VERSION")
else
  PREVD=$(latest "$PREV_VERSION")
fi
[[ -n $REF || $VERSION == "$REF_VERSION" ]] \
  || say "warning: no $REF_VERSION fast run yet: the guard can only record this run's values"
say "output $OUT; guard reference ${REF:-none (this run records it)}; previous fast run ${PREVD:-none}"
if [[ $DRY != 1 ]]; then
  mkdir -p "$OUT/checks" "$OUT/raw_fio" || die "mkdir $OUT"
  printf '%s\n' "${PRE[@]}" > "$OUT/fast.log"
  exec > >(tee -a "$OUT/fast.log") 2>&1
  echo running > "$OUT/STATUS"
  { for k in VERSION UNAME_R UNAME_V KERNEL_COMMIT BZIMAGE_MD5 CONFIG_MD5 STEPS GUARD REF_VERSION FP1_SYNC1_T1; do
      echo "$k=${!k}"; done
    echo "REF=${REF:-}"; echo "PREV=${PREVD:-}"; echo "START=$now"; } > "$OUT/checks/run.env"
fi
export TAU_RESULTS=$OUT

manifest() {
  local f
  echo "# fast test manifest: $VERSION, $(hostname -s), $(date -u --rfc-3339=seconds)"
  echo "## kernel"
  echo "running: $KR $KV; cmdline: $(cat /proc/cmdline)"
  echo "expected ($VENV): commit $KERNEL_COMMIT, uname -r $UNAME_R, uname -v '$UNAME_V', bzImage md5 $BZIMAGE_MD5, config md5 $CONFIG_MD5"
  echo "$KIMG md5 $(md5sum < "$KIMG" | cut -c1-32), /boot/config-$KR md5 $(md5sum < "/boot/config-$KR" | cut -c1-32)"
  echo "banner: $banner"
  for f in /sys/module/tau_journal/parameters/*; do [[ -r $f ]] && echo "tau_journal.$(basename "$f")=$(cat "$f")"; done
  echo "kernel source tree (not necessarily the build): $(git -C codes/djournalplus-kernel.code log -1 --format='%H %s'), $(git -C codes/djournalplus-kernel.code status --short | wc -l) changed paths"
  echo "## τ mkfs (fp1) and stock mkfs (fp0 KCHECK, fp1 none)"
  for f in e2fsprogs:misc/mke2fs xfsprogs-dev:mkfs/mkfs.xfs; do
    echo "codes/${f%%:*}: $(git -C codes/${f%%:*} log -1 --format='%H %s'), $(git -C codes/${f%%:*} status --short | wc -l) changed paths; ${f#*:} md5 $(md5sum < codes/${f%%:*}/${f#*:} | cut -c1-32)"
  done
  echo "stock mke2fs md5 $(md5sum < $TAUFS_BENCH_WS/stock/usr/sbin/mke2fs | cut -c1-32), stock mkfs.xfs md5 $(md5sum < $TAUFS_BENCH_WS/stock/sbin/mkfs.xfs | cut -c1-32)"
  echo "## databases and tools"
  echo "postgres: $($TAUFS_BENCH_WS/pg_install/bin/pg_config --version), binary md5 $(md5sum < $TAUFS_BENCH_WS/pg_install/bin/postgres | cut -c1-32); bench/postgresql $(git -C bench/postgresql log -1 --format=%H), $(git -C bench/postgresql status --short | wc -l) changed paths"
  echo "mysqld: $($TAUFS_BENCH/mysql-server/build/bin/mysqld --version 2> /dev/null), binary md5 $(md5sum < $TAUFS_BENCH/mysql-server/build/bin/mysqld | cut -c1-32); bench/mysql-server $(git -C bench/mysql-server log -1 --format=%H), $(git -C bench/mysql-server status --short | wc -l) changed paths"
  echo "benchbase: bench/benchbase $(git -C bench/benchbase log -1 --format=%H), $(git -C bench/benchbase status --short | wc -l) changed paths"
  echo "sysbench: $(sysbench --version 2> /dev/null); fio: $(fio --version)"
  echo "## umbrella"
  echo "HEAD $(git log -1 --format='%H %s')"
  echo "uncommitted:"; git status --short | sed 's/^/  /'
  echo "submodules:"; git submodule status | sed 's/^/  /'
  echo "harness: fast_perf.sh md5 $(md5sum < "$SELF" | cut -c1-32), fast_report.py md5 $(md5sum < "$SUITE/fast_report.py" | cut -c1-32)"
  echo "## images (restored by fp0 b, fp2, fp3)"
  for f in sysbench/postgres/ext4_t16_r32000000.img sysbench/{postgres,mysql}/{ext4,xfs}-tau_t16_r32000000_seg16m.img \
           benchbase/{postgres,mysql}/ext4-tau_tpcc_w1100_seg16m.img; do
    echo "$TAU_BACKUP_ROOT/$f: $(stat -c '%s B, mtime %y' "$TAU_BACKUP_ROOT/$f" 2> /dev/null || echo MISSING)"
  done
  echo "provenance: ${IMAGES_NOTE:-see versions/$VERSION.env}"
  echo "## test device"
  local b=/sys/block/$TAU_DEVICE_NAME
  echo "$TAU_DEVICE: $(cat $b/device/model | xargs), serial $(cat $b/device/serial | xargs), fw $(cat $b/device/firmware_rev | xargs), write_cache $(cat $b/queue/write_cache)"
  echo "## host"
  bash bench/scripts/machine_info.sh 2> /dev/null
}

smart() { sudo nvme smart-log "$TAU_DEVICE" 2> /dev/null; }   # the PM1735 is a multipath head: by namespace
sval() {  # <field> <smart-log text>: the value's first word
  awk -F: -v k="$1" '$1 ~ "^"k"[ \t]*$" { sub(/^[ \t]+/, "", $2); split($2, a, " "); print a[1]; exit }' <<< "$2"
}
discards() { awk '{ print $12 }' /sys/block/$TAU_DEVICE_NAME/stat; }
hugepages() {  # "<all free: yes|no> <free/total per node ...>"
  local n s="" all=yes
  for n in /sys/devices/system/node/node*/hugepages/hugepages-1048576kB; do
    s+="$(cat $n/free_hugepages)/$(cat $n/nr_hugepages) "; [[ $(cat $n/free_hugepages) == "$(cat $n/nr_hugepages)" ]] || all=no
  done
  echo "$all ${s% }"
}
leftovers() {  # after a failed step: a database or the mount left behind stops the run
  local l
  l=$(pgrep -a -x 'postgres|mysqld' | head -2)
  if [[ -n $l ]] || mountpoint -q "${MOUNT_DIR:-/mnt/temp}"; then
    finish "stopped: a failed step left ${l:-a mount at ${MOUNT_DIR:-/mnt/temp}} behind"
  fi
}
step() {  # step <name> <command...>
  say "step $1"
  printf '+'; printf ' %q' "${@:2}"; echo
  [[ $DRY == 1 ]] && return 0
  local t0 rc
  t0=$(date -u +%s)
  "${@:2}"; rc=$?
  printf '%s\t%s\t%s\t%s\n' "$1" "$rc" "$t0" "$(date -u +%s)" >> "$OUT/checks/steps.tsv"
  (( rc == 0 )) || { say "FAILED: step $1 rc=$rc"; leftovers; }
  return 0
}
summarize() {  # summary.csv of the newest sysbench run of $1 (run_main.sh writes none)
  [[ $DRY == 1 ]] && { echo "+ python3 bench/scripts/sysbench/parse_main.py <newest $OUT/sysbench/$1 run>"; return 0; }
  local d
  d=$(ls -td "$OUT/sysbench/$1"/20*/ 2> /dev/null | head -1)
  [[ -n $d ]] && python3 bench/scripts/sysbench/parse_main.py "${d%/}" > "${d%/}/summary.txt" 2>&1 && tail -3 "${d%/}/summary.txt"
}
summary_keep() { [[ $DRY == 1 ]] || cp -p "$SUMMARY" "$OUT/checks/SUMMARY.md.before_$1"; }
summary_back() {  # run_tpcc.sh's export_results.py rewrote the tracked SUMMARY.md from this run only
  [[ $DRY == 1 ]] && { echo "+ cp -p checks/SUMMARY.md.before_$1 $SUMMARY   # if run_tpcc.sh changed it"; return 0; }
  cmp -s "$OUT/checks/SUMMARY.md.before_$1" "$SUMMARY" && return 0
  if cp -p "$OUT/checks/SUMMARY.md.before_$1" "$SUMMARY"; then echo "===== put $SUMMARY back"; SUMRESTORED=yes
  else echo "===== FAILED to put $SUMMARY back (copy: checks/SUMMARY.md.before_$1)"; SUMRESTORED=failed; fi
}
SUMRESTORED=unchanged
# the raw test device, no file system: 16 KiB randwrite at QD32 x 4 jobs (a 64 GiB region each), then 16 KiB random
# writes at QD1 (latency); the PM1735 is write-through, so no FLUSH is involved
RAW1=(sudo fio --name=randwrite --filename="${TAU_DEVICE:-/dev/null}" --direct=1 --ioengine=libaio --rw=randwrite
  --bs=16k --iodepth=32 --numjobs=4 --size=64g --offset_increment=64g --time_based --runtime=60 --ramp_time=5
  --group_reporting --output-format=json --output="$OUT/raw_fio/randwrite.json")
RAW2=(sudo fio --name=write_qd1 --filename="${TAU_DEVICE:-/dev/null}" --direct=1 --ioengine=psync --rw=randwrite
  --bs=16k --size=64g --time_based --runtime=60 --ramp_time=5 --output-format=json
  --output="$OUT/raw_fio/write_qd1.json")
TIMER_START=$(date '+%F %T')
finish() {  # <status>: FP4's records, metrics and REPORT.md, STATUS
  [[ $DRY == 1 ]] && { echo "+ python3 bench/suite/fast_report.py report $OUT --prev ${PREVD:-<none>} --baselines bench/suite/baselines_$TAU_HOST.csv"; exit 0; }
  local s ran="" u
  s=$(smart)
  echo "$s" > "$OUT/checks/smart_after.txt"
  journalctl -k -b 0 --no-pager -o short-iso > "$OUT/checks/kernel_log.txt" 2>&1
  for u in $TIMERS; do
    journalctl --since "$TIMER_START" -u "${u%.timer}.service" --no-pager -o short-iso 2> /dev/null | grep -q 'Start' \
      && ran+="${u%.timer}.service "
  done
  read -r hpall hpa <<< "$(hugepages)"
  cat >> "$OUT/checks/fp4.env" <<EOF
smart_after=temp $(sval temperature "$s"), used $(sval percentage_used "$s"), media errors $(sval media_errors "$s"), written $(sval 'Data Units Written' "$s")
smart_critical_warning_after=$(sval critical_warning "$s")
smart_media_errors_after=$(sval media_errors "$s")
smart_err_log_after=$(sval num_err_log_entries "$s")
discards_after=$(discards)
hugepages_after=$hpa
hugepages_all_free_after=$hpall
linger_after=$(loginctl show-user "$(id -un)" -p Linger --value 2> /dev/null)
timers_ran=${ran% }
summary_md_restored=$SUMRESTORED
EOF
  echo "$1" > "$OUT/STATUS"
  declare -F restore_panic > /dev/null && restore_panic
  python3 "$SUITE/fast_report.py" report "$OUT" ${PREVD:+--prev "$PREVD"} --baselines "$SUITE/baselines_$TAU_HOST.csv"
  say "fast test $VERSION: $1; report $OUT/REPORT.md"
  exit 0
}

# 4. Records and settings before the first step
if [[ $DRY == 1 ]]; then
  echo "+ manifest > $OUT/MANIFEST.txt   (kernel, τ mkfs, PG/mysqld md5, umbrella HEAD and uncommitted paths, images, device, host)"
  echo "+ bash bench/scripts/host_setup.sh apply && bash bench/scripts/host_setup.sh check"
  echo "+ sudo sysctl -w kernel.panic=30 kernel.panic_on_oops=1 kernel.softlockup_panic=1   (AUTOREBOOT=$AUTOREBOOT)"
  echo "+ sudo nvme smart-log $TAU_DEVICE > checks/smart_before.txt; PM1735 temperature every 30 s > checks/temps.txt"
else
  manifest > "$OUT/MANIFEST.txt" 2>&1
  bash bench/scripts/host_setup.sh apply > /dev/null && bash bench/scripts/host_setup.sh check \
    || finish "stopped: host_setup check"
  if [[ $AUTOREBOOT == 1 ]]; then
    OLD_PANIC=$(sysctl -n kernel.panic kernel.panic_on_oops kernel.softlockup_panic | xargs)
    sudo sysctl -q -w kernel.panic=30 kernel.panic_on_oops=1 kernel.softlockup_panic=1 || finish "stopped: the auto-reboot sysctls"
    restore_panic() {
      [[ -n ${OLD_PANIC:-} ]] || return 0
      read -r a b c <<< "$OLD_PANIC"; OLD_PANIC=
      sudo sysctl -q -w kernel.panic=$a kernel.panic_on_oops=$b kernel.softlockup_panic=$c && echo "===== panic sysctls back to $a $b $c"
    }
    trap restore_panic EXIT
    say "auto-reboot on oops/soft lockup: kernel.panic=30 panic_on_oops=1 softlockup_panic=1 (were $OLD_PANIC)"
  fi
  s=$(smart); echo "$s" > "$OUT/checks/smart_before.txt"
  read -r hpball hpb <<< "$(hugepages)"
  cat > "$OUT/checks/fp4.env" <<EOF
smart_before=temp $(sval temperature "$s"), used $(sval percentage_used "$s"), media errors $(sval media_errors "$s"), written $(sval 'Data Units Written' "$s")
smart_media_errors_before=$(sval media_errors "$s")
smart_err_log_before=$(sval num_err_log_entries "$s")
discards_before=$(discards)
hugepages_before=$hpb
linger_before=$lg
timers_window=${tw[*]:-none}
EOF
  ( while kill -0 $$ 2> /dev/null; do echo "$(date -u +%T) $(sval temperature "$(smart)")"; sleep 30; done ) > "$OUT/checks/temps.txt" &
fi
R=bench/scripts/sysbench/run_main.sh T=bench/scripts/benchbase/run_tpcc.sh F=bench/scripts/micro/run_fio.sh
SB=(THREADS_LIST=64 LAST_POINT_RUNS=1 WARMUP_TIME=600 RUNNING_TIME=300)

# 5. The steps
for s in $STEPS; do
  case $s in
  fp0)
    step fp0a_randwrite "${RAW1[@]}"
    step fp0a_write_qd1 "${RAW2[@]}"
    step fp0b env KCHECK=1 IOSTAT=1 PG_PRE_CHECKPOINT=0 FS_GROUPS=ext4 FS_FPWON= FS_FPWOFF=ext4 "${SB[@]}" \
      bash $R postgres oltp_write_only
    summarize postgres
    if [[ $DRY == 1 ]]; then
      echo "+ python3 bench/suite/fast_report.py guard $OUT ${REF:--} $GUARD   (exit 3: stop)"
    else
      python3 "$SUITE/fast_report.py" guard "$OUT" "${REF:--}" "$GUARD" || finish "stopped: guard"
    fi ;;
  fp1)
    step fp1 env CONFIGS="tau-EXT4 tau-XFS" EXPS="e1 sync1" OPS="overwrite append" THREADS_LIST="1 64" \
      REPS=1 REPS_TOP=1 RUNTIME=60 FIRST_MODE=time bash $F "fast_$VERSION"
    [[ $FP1_SYNC1_T1 == 1 ]] && step fp1_sync1_t1 env CONFIGS="tau-EXT4 tau-XFS" EXPS=sync1 TOP_T=1 THREADS_LIST=1 \
      REPS_TOP=1 RUNTIME=60 bash $F "fast_${VERSION}_sync1t1" ;;
  fp2)
    for db in postgres mysql; do
      pg=(); [[ $db == postgres ]] && pg=(PG_PRE_CHECKPOINT=0)
      step fp2_$db env IOSTAT=1 "${pg[@]}" FS_GROUPS="ext4-tau xfs-tau" FS_FPWON= FS_FPWOFF="ext4-tau xfs-tau" \
        "${SB[@]}" bash $R $db oltp_write_only
      summarize $db
    done ;;
  fp3)
    for db in postgres mysql; do
      summary_keep $db
      step fp3_$db env FS_GROUPS=ext4-tau FS_FPWON= FS_FPWOFF=ext4-tau "${SB[@]}" bash $T $db
      summary_back $db
    done ;;
  fp4) ;;   # finish below records it
  esac
done
finish done
}
