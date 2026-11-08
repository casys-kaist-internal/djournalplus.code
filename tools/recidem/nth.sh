#!/bin/bash
# recidem nth: EVAL_PLAN T3 #9 (during_recovery_nth_block: "the second recovery must give what a
# completed first one gives") as a block-level sweep over the recovery's own writes, with no kernel
# hook (libra09, 2026-11-07). run.sh kills the VM at f·T into the replay; this puts the crash at chosen
# points of the replay's write stream instead.
#
# Per crash state (made as run.sh makes it: a fresh τ FS, atomicw τ overwrites until a qemu kill after
# the journal has filled), in one VM boot (tools/recidem/nth_guest.sh):
#   1. record: the reference recovery, mounted through dm-log-writes on a snapshot of the crash image;
#      its data files' hashes are A, then umount. The log is swept to its end (libra08:tau): plain
#      writes are logged at the next FLUSH or at teardown, so a mark sent when the mount returns can come
#      before the recovery's last writes. The tail of the log is the umount's writes, also crash
#      states the second recovery must handle. The torner:end mark only says where the mount returned.
#   2. the states: device = crash image + a part of the recovery's writes, built by
#      `torner replay --state-spec` (deterministic: the same spec gives the same bytes)
#      - epoch<=k: the log's FLUSH/FUA boundaries (legacy epochs), up to EPOCHS_MAX of them, evenly
#        spaced; the last one is the whole log
#      - entry<=N: in-order cuts at ENTRY_CUTS evenly spaced entry counts, inside the windows too
#      - random-subset: SUBSETS states where only a random part of one flush window landed (the
#        write-back cache's reordering, torner's random-subset)
#   3. each state: mount (the second recovery), hash, fsck (the τ forks)
#   4. the flip: the cut where the second recovery goes from "replays again" to "nothing to replay"
#      (the write that records the recovery as done), found by bisecting entry<=N between the cuts
#      around it; then entry<=F+1, F's window without F (epoch<=e,drop=[F]), and FLIP_SUBSETS
#      random subsets of that window
# PASS = hashes equal A's and fsck is clean.
#
# Usage: nth.sh [out dir]
#   env FSES ("ext4-tau xfs-tau"), STATES (1), EPOCHS_MAX (25), ENTRY_CUTS (20), SUBSETS (6),
#       FLIP_SUBSETS (4), SEED (1), COW_GB (64), LOG_GB (32): the room appended to the crash image for the
#       snapshots' COW and the log (nth_guest.sh carves /dev/vda; the guest's root stays out of it),
#       plus run.sh's DISK_GB FILES DATA_GB JOURNAL_GB THREADS BATCH LOAD_S KILL_MIN_S IMGDIR SEGSIZE
# Guest: an overlay on vm_imgs/cm-guest-ubuntu.qcow2, the tree's bzImage and the initrd of its build.
# Parsed whole first.
{
SELF=$(realpath "$0")
R=/home/jhlee/codes/djournalplus.code; T=$R/tools/recidem; V=$R/tools/qemu/vm_imgs
cd $R || exit 1
unset TAU_TARGET_DISK; source set_env.sh > /dev/null; source bench/scripts/common.sh > /dev/null; set +e
set -u
FSES=${FSES:-ext4-tau xfs-tau} STATES=${STATES:-1}
EPOCHS_MAX=${EPOCHS_MAX:-25} ENTRY_CUTS=${ENTRY_CUTS:-20} SUBSETS=${SUBSETS:-6} FLIP_SUBSETS=${FLIP_SUBSETS:-4} SEED=${SEED:-1}
COW_GB=${COW_GB:-64} LOG_GB=${LOG_GB:-32}
# τ journal segments: 16 MiB, as the benches since the user's decision (가) of 11-08 (XFS then needs
# tjmaxsize=32G for the 32 GiB cap); SEGSIZE= (empty) gives the mkfs defaults, 128 MiB, as up to 11-08
SEGSIZE=${SEGSIZE-16m}
XL=tjmaxsize=1G; [ -n "$SEGSIZE" ] && XL=tjsegsize=$SEGSIZE,tjmaxsize=32G   # xfs-tau's -l
DISK_GB=${DISK_GB:-256} FILES=${FILES:-64} DATA_GB=${DATA_GB:-96} JOURNAL_GB=${JOURNAL_GB:-32}
THREADS=${THREADS:-64} BATCH=${BATCH:-64} LOAD_S=${LOAD_S:-60} KILL_MIN_S=${KILL_MIN_S:-40}
KD=$R/codes/djournalplus-kernel.code
KV=$(strings $KD/arch/x86/boot/bzImage | grep -m1 '^6\.8\.0tjournal')
BUILD=$(echo "$KV" | grep -oE '#[0-9]+' | tr -d '#')
INITRD=${INITRD:-$V/initrd.img-6.8.0tjournal+-$BUILD}
BASE=${BASE:-$V/cm-guest-ubuntu.qcow2}
AW=$R/bench/workspace/micro/atomicw; TORNER=$R/tools/torner/torner
OUT=$(realpath -m "${1:-$R/bench/workspace/results/libra09/correctness/recidem_nth_$(date -u +%Y%m%d_%H%M%S)}")
IMGDIR=${IMGDIR:-/mnt/recidem}
PORT=5559 GDB=1239
O="-i $HOME/.ssh/tau_vm_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
   -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=10"
g() { ssh -p $PORT $O jhlee@localhost "$@"; }
die() { echo "nth: $*"; exit 1; }
[ -f "$INITRD" ] || die "no initrd $INITRD for build #$BUILD"
[ -x "$AW" ] || gcc -O2 -Wall -pthread -o "$AW" "$R/bench/scripts/micro/atomicw.c" || die "atomicw"
( cd $R/tools/torner && make -s ) || die "torner build"
$TORNER replay --help 2>&1 | grep -q state-spec || die "torner"
pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null && die "a VM on port $PORT is running"
mkdir -p "$OUT" || exit 1
exec > >(tee -a "$OUT/run.log") 2>&1
cp "$SELF" "$T/nth_guest.sh" "$OUT/"
echo "recidem nth $(date -u --rfc-3339=seconds): kernel $KV; $FSES; $STATES state(s); epochs $EPOCHS_MAX, entry cuts $ENTRY_CUTS," \
  "subsets $SUBSETS (seed $SEED); disk ${DISK_GB}G, $FILES files ${DATA_GB}G, journal ${JOURNAL_GB}G, $THREADS threads, batch $BATCH"
if ! mountpoint -q "$IMGDIR"; then
  [[ $(cat /sys/block/$TAU_DEVICE_NAME/device/model | xargs) == "SAMSUNG MZPLJ3T2HBJR-00007" ]] || die "test device is not the PM1735"
  sudo mkdir -p "$IMGDIR"
  stock_mke2fs -q -t ext4 -F "$TAU_DEVICE" && sudo mount "$TAU_DEVICE" "$IMGDIR" && sudo chown "$(id -u):$(id -g)" "$IMGDIR" || die "image fs"
fi

QPID=
boot() {  # <disk image> <console log>: a fresh root overlay, the image as /dev/vda
  rm -f "${IMGDIR:?}/nth-ov.qcow2"
  qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$IMGDIR/nth-ov.qcow2" || return 1
  INITRD=$INITRD ROOTFS=$IMGDIR/nth-ov.qcow2 SCRATCH=$1 SSH_PORT=$PORT GDB_PORT=$GDB TAUFS_KERNEL=$KD MEM=16G CORES=8 \
    sg kvm -c "bash $R/tools/qemu/run_vm_torner.sh" > "$2" 2>&1 < /dev/null &
  QPID=$!
  local i
  for i in $(seq 80); do timeout 10 ssh -p $PORT $O jhlee@localhost true 2> /dev/null && break; sleep 3; done
  # the dm targets are modules (=m) and the guest image's /lib/modules is an older build's: take the
  # tree's own, which match the bzImage the guest booted
  g "mkdir -p ~/recidem ~/nth/bin ~/nth/mod" &&
    scp -q -P $PORT $O "$T/guest.sh" "$T/nth_guest.sh" "$AW" jhlee@localhost:recidem/ &&
    scp -q -P $PORT $O "$TORNER" "$TAUFS_E2FSPROGS/e2fsck/e2fsck" "$TAUFS_XFSPROGS/repair/xfs_repair" jhlee@localhost:nth/bin/ &&
    scp -q -P $PORT $O $KD/drivers/md/dm-bufio.ko $KD/drivers/md/dm-snapshot.ko $KD/drivers/md/dm-log-writes.ko \
      jhlee@localhost:nth/mod/
}
vm_kill() { pkill -KILL -f "hostfwd=tcp::$PORT-:22"; wait $QPID 2> /dev/null; QPID=; }
vm_off() {
  timeout 30 ssh -p $PORT $O jhlee@localhost "sudo poweroff" > /dev/null 2>&1
  local i; for i in $(seq 40); do pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null || break; sleep 2; done
  pgrep -f "hostfwd=tcp::$PORT-:22" > /dev/null && vm_kill
  wait $QPID 2> /dev/null; QPID=
}
mount_wait() {  # <timeout s>
  local i
  for (( i = 0; i < $1 * 2; i++ )); do
    t=$(g "cat ~/recidem/mount.done 2> /dev/null") && [ -n "$t" ] && { echo "$t"; return 0; }
    sleep 0.5
  done
  echo timeout; return 1
}

printf '%-9s %-6s %-34s %16s %8s %12s %5s %5s %s\n' fs state spec last_entry/epoch mount_s replayed hash fsck result | tee "$OUT/results.txt"
trial() {  # <spec>: one state in the booted guest; the table line, and the line kept in $P.trials
  local line m r h f le c res
  # ssh must not read the spec list on stdin
  line=$(g "bash ~/recidem/nth_guest.sh trial $fs $JOURNAL_GB '$1'" < /dev/null 2>&1 | tail -1)
  echo "$line" >> "$P.trials"
  le=$(echo "$line" | grep -oE 'last=[^ ]+' | cut -d= -f2)
  m=$(echo "$line" | grep -oE 'mount_s=[^ ]+' | cut -d= -f2)
  r=$(echo "$line" | grep -oE 'replayed=[^ ]+' | cut -d= -f2)
  h=$(echo "$line" | grep -oE 'hash=[^ ]+' | cut -d= -f2)
  f=$(echo "$line" | grep -oE 'fsck=[^ ]+' | cut -d= -f2)
  c=$(echo "$line" | grep -oE 'cow=[^ ]+' | cut -d= -f2)
  if [[ $h == same && $f == 0 && $c =~ ^[0-9]+/[0-9]+$ ]]; then res=PASS; else res="FAIL($line)"; fi
  printf '%-9s %-6s %-34s %16s %8s %12s %5s %5s %s\n' "$fs" "s$s" "$1" "${le:--}" "${m:--}" "${r:--}" "${h:--}" "${f:--}" "$res" | tee -a "$OUT/results.txt"
}
blocks_of() {  # <spec>: the blocks the second recovery replayed in that state ("" if not run)
  grep -F "spec=$1 " "$P.trials" | tail -1 | grep -oE 'replayed=[0-9]+/[0-9]+' | cut -d/ -f2
}
for fs in $FSES; do
  for s in $(seq "$STATES"); do
    P=$OUT/$fs.s$s C=$IMGDIR/nth-$fs.s$s.crash
    # the crash state, as run.sh
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
    g "tail -c 300 ~/recidem/load.log" > "$P.load.tail" 2> /dev/null
    vm_kill
    truncate -s $(( DISK_GB + COW_GB + LOG_GB ))G "$C"   # the COW's and the log's room, behind the FS
    echo "$fs s$s: crash state after ${k}s of load ($(date -u +%T))"
    # the sweep, in one boot; /dev/vda (the crash image) is only read
    boot "$C" "$P.sweep.console" || { echo "$fs s$s: boot failed"; vm_kill; continue; }
    g "bash ~/recidem/nth_guest.sh record $fs $JOURNAL_GB $DISK_GB $COW_GB $LOG_GB" > "$P.record" 2>&1
    cat "$P.record"
    st=$(grep '^{"tool":"torner-replay"' "$P.record")
    E=$(echo "$st" | python3 -c 'import json, sys; print(json.load(sys.stdin)["entries"])' 2> /dev/null)
    EP=$(echo "$st" | python3 -c 'import json, sys; print(json.load(sys.stdin)["epochs"])' 2> /dev/null)
    if ! [[ $E =~ ^[0-9]+$ && $EP =~ ^[0-9]+$ ]] || (( E < 2 || EP < 2 )); then
      echo "$fs s$s: no usable recovery log (entries '$E', epochs '$EP': one epoch means FLUSH/FUA were stripped)"; vm_off; continue
    fi
    # the states: FLUSH/FUA boundaries, in-order cuts, reordered windows, over the whole log
    g "sudo ~/nth/bin/torner replay --log \$(cat ~/nth/log.loop) --enumerate --strategy random-subset --samples 1 --seed $SEED" \
      > "$P.subsets.jsonl" 2> /dev/null
    python3 - "$E" "$EP" "$EPOCHS_MAX" "$ENTRY_CUTS" "$SUBSETS" "$P.subsets.jsonl" > "$P.specs" <<'EOF'
import json, sys
E, EP, emax, cuts, nsub = (int(x) for x in sys.argv[1:6])
specs = []
ks = list(range(1, EP + 1))
if len(ks) > emax:
    ks = sorted({ks[round(i * (len(ks) - 1) / (emax - 1))] for i in range(emax)})
specs += ["epoch<=%d" % k for k in ks]
specs += ["entry<=%d" % n for n in sorted({round(i * (E - 1) / cuts) for i in range(1, cuts + 1)})]
subs = []
for line in open(sys.argv[6]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    # torner's key is state_spec; a window of millions of entries makes a drop list
    # too long for a command line, so only windows whose spec stays short
    sp = d.get("state_spec") or ""
    if 1 <= d.get("epoch", 0) <= EP and sp and len(sp) <= 4096:
        subs.append(sp)
if subs and nsub:
    subs = [subs[round(i * (len(subs) - 1) / max(nsub - 1, 1))] for i in range(min(nsub, len(subs)))]
    specs += sorted(set(subs), key=subs.index)
for x in dict.fromkeys(specs):
    print(x)
EOF
    echo "$fs s$s: log $E entries, $EP epochs (mount returned at entry $(echo "$st" | python3 -c 'import json, sys; print(json.load(sys.stdin)["end_entry"])')): $(wc -l < "$P.specs") states ($(date -u +%T))"
    while read -r spec; do trial "$spec"; done < "$P.specs"
    # the flip, bisected over entry<=N: lo replays again, hi has nothing to replay
    lo= hi=
    for n in $(grep -oE '^entry<=[0-9]+$' "$P.specs" | cut -d= -f2 | sort -n); do
      b=$(blocks_of "entry<=$n")
      [[ $b =~ ^[0-9]+$ ]] || continue
      if (( b > 0 )); then lo=$n; elif [ -n "$lo" ] && [ -z "$hi" ]; then hi=$n; fi
    done
    if [[ -n $lo && -n $hi ]]; then
      echo "$fs s$s: the flip lies in entries ($lo, $hi]: bisecting ($(date -u +%T))"
      while (( hi - lo > 1 )); do
        mid=$(( (lo + hi) / 2 )); trial "entry<=$mid"
        b=$(blocks_of "entry<=$mid")
        [[ $b =~ ^[0-9]+$ ]] || { echo "$fs s$s: bisect stopped: no result at $mid"; break; }
        if (( b > 0 )); then lo=$mid; else hi=$mid; fi
      done
      F=$hi
      e=$(grep -F "spec=entry<=$F " "$P.trials" | tail -1 | grep -oE 'last=[0-9]+/[0-9]+' | cut -d/ -f2)
      echo "$fs s$s: the flip is entry $F (epoch ${e:-?}): entry<=$((F - 1)) replays again, entry<=$F has nothing to replay"
      echo "$F ${e:-}" > "$P.flip"
      trial "entry<=$((F + 1))"
      if [[ $e =~ ^[0-9]+$ ]]; then
        trial "epoch<=$e,drop=[$F]"
        g "sudo ~/nth/bin/torner replay --log \$(cat ~/nth/log.loop) --enumerate --strategy random-subset --samples $FLIP_SUBSETS --seed $SEED" \
          < /dev/null > "$P.flipsubsets.jsonl" 2> /dev/null
        python3 - "$e" "$FLIP_SUBSETS" "$P.flipsubsets.jsonl" "$F" <<'EOF2' | while read -r spec; do trial "$spec"; done
import json, sys
e, k = int(sys.argv[1]), int(sys.argv[2])
subs = []
for line in open(sys.argv[3]):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    sp = d.get("state_spec") or ""
    if d.get("epoch") == e and sp and len(sp) <= 4096:
        subs.append(sp)
for x in [x for x in dict.fromkeys(subs) if x != "epoch<=%d,drop=[%s]" % (e, sys.argv[4])][:k]:
    print(x)
EOF2
      fi
    else
      echo "$fs s$s: no flip among the entry cuts (lo '$lo', hi '$hi')"
    fi
    scp -q -P $PORT $O jhlee@localhost:nth/record.dmesg "$P.record.dmesg" < /dev/null 2> /dev/null
    g "ls ~/nth/B.*" < /dev/null > /dev/null 2>&1 && scp -q -P $PORT $O "jhlee@localhost:nth/B.*" "$OUT/" < /dev/null
    g "sudo dmesg" < /dev/null > "$P.sweep.dmesg" 2> /dev/null
    g "bash ~/recidem/nth_guest.sh cleanup" > /dev/null 2>&1
    vm_off
    rm -f "${C:?}"
  done
done
rm -f "${IMGDIR:?}/nth-ov.qcow2"
echo "recidem nth done $(date -u --rfc-3339=seconds): $(grep -c ' PASS$' "$OUT/results.txt") PASS, $(grep -c 'FAIL' "$OUT/results.txt") FAIL"
exit
}
