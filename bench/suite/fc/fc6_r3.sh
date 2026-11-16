#!/bin/bash
# FC6 -- R3 reduced (EVAL_PLAN §6.5 tools, bench/scripts/costs): a 1 GiB ftruncate(0) and an unlink at
# journal residency res1g, on tau-EXT4 and tau-XFS, once each, in libra08's R3 VM
# (/mnt/tau_backup/r3/vm: its disks are files on the PM1753; no PM1735, no vm.lock).
# The regression check of kernel #403's B1 (435978dd): a truncate writes nothing to the file's home
# blocks during the call. On #401 the REMOVED checkpoint policy wrote 10-22 MiB there (2026-11-15).
#   run_r3.sh CONFIGS="tau-EXT4 tau-XFS" OPS="truncate unlink" STATES=res1g AFTERS=wait REPS=1
# AFTERS=wait: the segments come back with the host's own commit, the window in which #401 ran empty
# checkpoint walks (cp_runs, in the case detail). Before the run the guest's tool copy (~/r3tree)
# gets this tree's set_env.sh, bench/scripts/common.sh, bench/scripts/costs/ and
# bench/machines/libra08-r3vm.env.
# Cases: r3/<ext4|xfs>/<truncate|unlink>-res1g/home-call -- PASS when the call wrote 0 bytes home;
#        SKIP when r3_report.py calls the run void (reclaim ran, device busy, trace incomplete).
# About 3 min (2 min on 11-16). FC6_CORES [16] vCPUs, FC6_VMDIR [/mnt/tau_backup/r3/vm], FC6_DEADLINE_MIN [30].
set -u
. "$(dirname "$(realpath "$0")")/lib.sh"
VMDIR=${FC6_VMDIR:-/mnt/tau_backup/r3/vm}
CORES=${FC6_CORES:-16}
DEADLINE_MIN=${FC6_DEADLINE_MIN:-30}
PORT=5560                       # run_vm_r3.sh's ssh port
TAG=fast-$FC_VERSION
RUN_ENV='HOST_CHECK=0 CONFIGS="tau-EXT4 tau-XFS" OPS="truncate unlink" STATES=res1g AFTERS=wait REPS=1'
UTS=$(fc_kuts "$FC_KDIR")
INITRD=${FC_INITRD:-none}      # fast_correct.sh's KINITRD; none: the root disk's drivers are built in

problems=
[ -x "$VMDIR/run_vm_r3.sh" ] || problems="$problems; no $VMDIR/run_vm_r3.sh"
[ -f "$VMDIR/r3-root.qcow2" ] || problems="$problems; no $VMDIR/r3-root.qcow2"
[ "$(fc_hp1g_most)" -ge 24 ] || problems="$problems; no node has 24 free 1 GiB pages now ($(fc_hp1g_most))"
ps -C qemu-system-x86_64 -o args= | grep -q "$VMDIR/r3-root.qcow2" && problems="$problems; an R3 VM is up"

if [ "$FC_DRY" = 1 ]; then
	fc_plan "kernel $(fc_kimage "$FC_KDIR") = $UTS"
	fc_plan "VM: INITRD=$INITRD KD=$FC_KDIR CORES=$CORES $VMDIR/run_vm_r3.sh (24 GiB on 1 GiB pages, ssh :$PORT; console -> FC6/console.log)"
	fc_plan "after boot: r3/boot/kernel (uname -v = the pinned build), r3/boot/modules (none loaded); at the end r3/end/taint-W"
	fc_plan "guest ~/r3tree <- set_env.sh, bench/scripts/common.sh, bench/scripts/costs/, bench/machines/libra08-r3vm.env"
	fc_plan "guest: $RUN_ENV bash bench/scripts/costs/run_r3.sh $TAG"
	fc_plan "cases: r3/{ext4,xfs}/{truncate,unlink}-res1g/home-call (sync_home_bytes == 0); logs: console, guest journalctl -k"
	[ -n "$problems" ] && fc_plan "NOW (would stop a real run):${problems#;}"
	fc_estimate 4
	exit 0
fi
[ -z "$problems" ] || { fc_say "cannot run:${problems#;}"; exit 2; }

fc_say "boot $UTS, initrd $INITRD"
INITRD=$INITRD KD=$FC_KDIR CORES=$CORES setsid nohup "$VMDIR/run_vm_r3.sh" > "$FC_OUT/console.log" 2>&1 < /dev/null &
QPID=$!
fc_logfile "$FC_OUT/console.log"
cleanup() {
	kill -0 "$QPID" 2>/dev/null || return 0
	fc_ssh $PORT "sync; sudo systemctl poweroff" > /dev/null 2>&1
	for _ in $(seq 45); do kill -0 "$QPID" 2>/dev/null || return 0; sleep 2; done
	fc_say "VM did not power off: kill $QPID"; kill "$QPID" 2>/dev/null
}
trap cleanup EXIT
fc_wait_ssh $PORT 240 || { fc_say "VM did not come up"; exit 2; }
taint0=$(fc_guest_check $PORT r3 "")      # the pinned build, no module loaded (all built in)
grep -q $'^r3/boot/kernel\tPASS' "$FC_OUT/cases.tsv" || { fc_say "the guest does not run $UTS"; exit 2; }
fc_note "R3 VM at boot: initrd $INITRD, tainted=$taint0"

fc_say "sync the tools into the guest"
E="ssh -p $PORT $FC_SSH_OPTS"
rsync -a -e "$E" "$FC_ROOT/set_env.sh" jhlee@localhost:r3tree/set_env.sh &&
rsync -a -e "$E" "$FC_ROOT/bench/scripts/common.sh" jhlee@localhost:r3tree/bench/scripts/common.sh &&
rsync -a --delete --exclude __pycache__ -e "$E" "$FC_ROOT/bench/scripts/costs/" jhlee@localhost:r3tree/bench/scripts/costs/ &&
rsync -a -e "$E" "$FC_ROOT/bench/machines/libra08-r3vm.env" jhlee@localhost:r3tree/bench/machines/libra08-r3vm.env ||
	{ fc_say "rsync into the guest failed"; exit 2; }
( cd "$FC_ROOT" && md5sum set_env.sh bench/scripts/common.sh bench/scripts/costs/*.sh bench/scripts/costs/*.py \
	bench/machines/libra08-r3vm.env ) > "$FC_OUT/tools.md5"

fc_say "run: $RUN_ENV run_r3.sh $TAG"
fc_ssh $PORT "cat > ~/fc6-run.sh" <<EOF
cd ~/r3tree && source set_env.sh > /dev/null 2>&1
env $RUN_ENV bash bench/scripts/costs/run_r3.sh $TAG
echo "rc=\$?"
sudo journalctl -k -b -o short-monotonic --no-pager > ~/fc6-kernel.log 2>&1
echo "### fc6 done"
EOF
fc_ssh $PORT "bash -c 'rm -f ~/fc6.out; setsid nohup bash ~/fc6-run.sh > ~/fc6.out 2>&1 < /dev/null &'"
end=$(( $(date +%s) + DEADLINE_MIN * 60 ))
until fc_ssh $PORT "grep -q '^### fc6 done' ~/fc6.out" 2>/dev/null; do
	[ "$(date +%s)" -lt $end ] || { fc_say "no result in $DEADLINE_MIN min"; fc_ssh $PORT "tail -5 ~/fc6.out"; exit 2; }
	kill -0 "$QPID" 2>/dev/null || { fc_say "the VM went away"; exit 2; }
	sleep 20
done
fc_ssh $PORT "cat ~/fc6.out" > "$FC_OUT/run_r3.out"
rd=$(sed -n 's|^=== done .*: \(/.*\)$|\1|p' "$FC_OUT/run_r3.out" | tail -1)
[ -n "$rd" ] || rd=$(grep -o '/home/jhlee/r3tree/bench/workspace/results/[^ ]*_r3_'"$TAG" "$FC_OUT/run_r3.out" | tail -1)
[ -n "$rd" ] || { fc_say "no result directory in run_r3.out"; exit 2; }
fc_guest_taint_w $PORT r3
mkdir -p "$FC_OUT/r3"
rsync -a -e "$E" "jhlee@localhost:$rd" "$FC_OUT/r3/" && rsync -a -e "$E" jhlee@localhost:fc6-kernel.log "$FC_OUT/guest-kernel.log" ||
	{ fc_say "copy back failed"; exit 2; }
fc_logfile "$FC_OUT/guest-kernel.log"
J=$(ls "$FC_OUT"/r3/*/results.jsonl | head -1)

python3 - "$J" "$FC_ROOT/bench/scripts/costs" "$FC_OUT" <<'PYEOF'
import json, sys
sys.path.insert(0, sys.argv[2])
from r3_report import void_reason
out = sys.argv[3]
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
seen = set()
summ = ["| case | home KiB in call | other KiB in call | lat ms | flush_submit in call | cp_runs call+after | seg back ms | void |",
        "|---|---:|---:|---:|---:|---:|---:|---|"]
with open(out + "/cases.tsv", "a") as cf:
    for r in rows:
        if r.get("state") != "res1g" or not str(r.get("config", "")).startswith("tau-"):
            continue
        fs = r["config"].split("-", 1)[1].lower()
        cid = "r3/%s/%s-res1g/home-call" % (fs, r["op"])
        pc, pa = r.get("probe_call") or {}, r.get("probe_after") or {}
        cp = pc.get("cp_runs", 0) + pa.get("cp_runs", 0)
        home = r.get("sync_home_bytes", 0)
        why = void_reason(r)
        det = "home=%.0fKiB other=%.0fKiB lat=%.1fms flush_submit=%d cp_runs=%d" % (
            home / 1024, r.get("sync_other_bytes", 0) / 1024, r.get("lat_ms", 0), pc.get("flush_submit", 0), cp)
        verdict = "SKIP" if why else ("PASS" if home == 0 else "FAIL")
        cf.write("%s\t%s\t%s%s\n" % (cid, verdict, det, ("; void: " + why) if why else ""))
        seen.add(cid)
        summ.append("| %s | %.0f | %.0f | %.1f | %d | %d | %s | %s |" % (
            cid, home / 1024, r.get("sync_other_bytes", 0) / 1024, r.get("lat_ms", 0),
            pc.get("flush_submit", 0), cp, r.get("seg_return_ms", "-"), why or "-"))
    for fs in ("ext4", "xfs"):
        for op in ("truncate", "unlink"):
            cid = "r3/%s/%s-res1g/home-call" % (fs, op)
            if cid not in seen:
                cf.write("%s\tFAIL\tno run in results.jsonl\n" % cid)
with open(out + "/summary.md", "a") as sf:
    sf.write("FC6 R3 reduced (run_r3.sh, tau-EXT4/tau-XFS, res1g, AFTERS=wait, REPS=1)\n\n" + "\n".join(summ) + "\n")
PYEOF
fc_say "done: $(cut -f1,2 "$FC_OUT/cases.tsv" | tr '\t\n' ' ;')"
exit 0
