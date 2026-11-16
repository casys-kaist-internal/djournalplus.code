#!/bin/bash
# FC4 -- Torner reduced: the main cells of the §6.2 table (T2b) on tau-EXT4 and tau-XFS -- the 7
# captured workloads ow4k ow16k ap2k ap4k ap16k prealloc hole, which make the table's 8 rows (ap2k
# gives "within a block" and "2 KiB into a new block"), quiet and busy -- with the state budgets cut
# to a fifth (LIMIT_TAU_ATOM 300, LIMIT_TAU_EPOCH 400; full.sh's 1500/2000), and one control that
# must fail: record_fua_only-fds on ow16k quiet (budget 300).
# tools/torner/campaign/full.sh with QUEUES="q1 q2": two VMs side by side (q1 tau-ext4 :5556, q2
# tau-xfs :5559), 8 vCPUs and 10 GiB on the 1 GiB pool each, overlays on the base copy BASE,
# scratch files on the PM1753: no PM1735, no vm.lock.
# Cases: torner/<tau-ext4|tau-xfs>/<row>/<quiet|busy> -- PASS when the cell has states and content,
#          size, durability, unmountable, torn writes, P3, and loginv's i1 (skipped, missing,
#          violations), i2 (uncovered), i3 and i4 are all 0;
#        torner/<fs>/ctl-record_fua_only-fds/ow16k/quiet -- PASS when it fails (content + size +
#          durability > 0), as it must.
# About 1 h: at the full budget these cells took 2 h 51 m (tau-ext4) and 4 h 06 m (tau-xfs) on #401
# (2026-11-12-tau401, T2b).
set -u
. "$(dirname "$(realpath "$0")")/lib.sh"
T=$FC_ROOT/tools/torner/campaign
KB=${FC4_BASEVM:-/mnt/tau_backup/build/linux-basevm-6cc650b0}
export BASE=${FC4_BASE:-/mnt/tau_backup/torner/base/qemu-image-20261021.qcow2}
export OVDIR=${FC4_OVDIR:-/mnt/tau_backup/torner-scratch}
export VM_HUGEPAGES=1 QUEUES="q1 q2" MERGE="" VARIANTS=""
export CONTROLS="record_fua_only-fds:cap=tau_record_fua_only=1:gen=--fdatasync:rows=ow16k:profiles=quiet"
export LIMIT_TAU_ATOM=${FC4_LIMIT_ATOM:-300} LIMIT_TAU_EPOCH=${FC4_LIMIT_EPOCH:-400} LIMIT_CTL=${FC4_LIMIT_CTL:-300}
# fast_correct.sh's KINITRD [none]: table.sh hands it to run_vm_torner.sh; setup.log then lists the
# guest's modules (only dm_log_writes, loaded from the pinned tree, may be there)
export TORNER_INITRD=${FC_INITRD:-none}

problems=
[ -f "$T/full.sh" ] || problems="$problems; no $T/full.sh"
[ -f "$BASE" ] || problems="$problems; no base copy $BASE"
[ -d "$KB" ] || problems="$problems; no basevm tree $KB (full.sh's second argument)"
[ -f "$FC_KDIR/drivers/md/dm-log-writes.ko" ] || problems="$problems; $FC_KDIR has no drivers/md/dm-log-writes.ko (torner loads it from the tree)"
hp=0; for n in /sys/devices/system/node/node[0-9]*; do hp=$((hp + $(cat $n/hugepages/hugepages-1048576kB/free_hugepages))); done
[ $hp -ge 20 ] || problems="$problems; only $hp free 1 GiB pages (two 10 GiB VMs)"
ps -C qemu-system-x86_64 -o args= | grep -qE 'hostfwd=tcp::(5556|5559)-' && problems="$problems; a VM holds ssh port 5556 or 5559"

if [ "$FC_DRY" = 1 ]; then
	fc_plan "kernel $FC_KDIR = $(fc_kver "$FC_KDIR")"
	fc_plan "BASE=$BASE OVDIR=$OVDIR VM_HUGEPAGES=1 QUEUES=\"q1 q2\" MERGE= VARIANTS= LIMIT_TAU_ATOM=$LIMIT_TAU_ATOM LIMIT_TAU_EPOCH=$LIMIT_TAU_EPOCH LIMIT_CTL=$LIMIT_CTL"
	fc_plan "CONTROLS=\"$CONTROLS\" TORNER_INITRD=$TORNER_INITRD"
	fc_plan "boot checks per VM: torner/boot/<queue>/kernel (table.log's boot line = the pinned build), torner/boot/<queue>/modules (setup.log: only dm_log_writes, the tree's srcversion; no W taint)"
	fc_plan "bash $T/full.sh $FC_KDIR $KB FC4/torner   (q1 tau-ext4 :5556, q2 tau-xfs :5559; 8 vCPU, 10 GiB each)"
	fc_plan "cases: torner/{tau-ext4,tau-xfs}/{ow4k,ow16k,ap2k,ap4k,ap16k,prealloc,hole}/{quiet,busy} (28) + torner/{fs}/ctl-record_fua_only-fds/ow16k/quiet (2, must fail)"
	[ -n "$problems" ] && fc_plan "NOW (would stop a real run):${problems#;}"
	fc_estimate 70
	exit 0
fi
[ -z "$problems" ] || { fc_say "cannot run:${problems#;}"; exit 2; }

fc_say "full.sh on $(fc_kuts "$FC_KDIR")"
bash "$T/full.sh" "$FC_KDIR" "$KB" "$FC_OUT/torner" > "$FC_OUT/full.out" 2>&1 < /dev/null
echo "full.sh rc=$?" >> "$FC_OUT/full.out"
for f in "$FC_OUT"/torner/q*/console.log "$FC_OUT"/torner/q*/*.dmesg; do [ -f "$f" ] && fc_logfile "$f"; done
[ -f "$FC_OUT/torner/table.csv" ] || { fc_say "no table.csv"; exit 2; }
cp "$FC_OUT/torner/summary.md" "$FC_OUT/torner-summary.md" 2>/dev/null

# every VM ran the pinned build, and held no module but the pinned tree's dm-log-writes
want=$(fc_kver "$FC_KDIR"); tsv=$(modinfo -F srcversion "$FC_KDIR/drivers/md/dm-log-writes.ko" 2>/dev/null)
for q in "$FC_OUT"/torner/q*/; do
	qn=$(basename "$q")
	got=$(sed -n 's/^===== boot [0-9-]* [0-9:]*  //p' "$q/table.log" | sed 's/  cmdline +.*//' | sort -u)
	if [ "$got" = "$want" ]; then fc_case "torner/boot/$qn/kernel" PASS "$got"
	else fc_case "torner/boot/$qn/kernel" FAIL "guest '$got', pinned '$want'"; fi
	mods=$(sed -n 's/^modules: //p' "$q/setup.log" | tail -1)
	sv=$(sed -n 's/^srcversion dm_log_writes //p' "$q/setup.log" | tail -1)
	t=$(sed -n 's/^tainted: //p' "$q/setup.log" | tail -1)
	bad=
	for m in $mods; do [ "$m" = dm_log_writes ] || bad="$bad $m"; done
	[ -n "$sv" ] && [ "$sv" = "$tsv" ] || bad="$bad dm_log_writes(srcversion ${sv:-?}, tree ${tsv:-?})"
	[ -n "$t" ] && [ $((t & 512)) = 0 ] || bad="$bad tainted=${t:-?}"
	if [ -z "$bad" ]; then fc_case "torner/boot/$qn/modules" PASS "loaded: ${mods:-none}, dm_log_writes srcversion $sv, tainted=$t"
	else fc_case "torner/boot/$qn/modules" FAIL "${bad# }"; fi
done

python3 - "$FC_OUT/torner/table.csv" "$FC_OUT" <<'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
out = sys.argv[2]
n = lambda r, k: int(float(r.get(k) or 0))
ZERO = ("unmountable", "viol_content", "viol_size", "viol_durability", "writes_torn", "p3_dirty",
        "i1_skipped", "i1_missing", "i1_violations", "i2_uncovered", "i3_violations", "i4_violations")
seen = set()
summ = ["| case | states | unjudged | content | size | durability | torn | p3 | loginv (i1 v/s/m, i2 unc, i3, i4) | verdict |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|---|"]
with open(out + "/cases.tsv", "a") as cf:
    for r in rows:
        if not r["config"].startswith("tau-"):
            continue
        tag = r.get("tag") or ""
        if tag:
            cid = "torner/%s/ctl-%s/%s/%s" % (r["config"], tag, r["row"], r["profile"])
            bad = n(r, "viol_content") + n(r, "viol_size") + n(r, "viol_durability")
            v = "PASS" if bad > 0 else "FAIL"
            det = "control: content=%d size=%d durability=%d (must be > 0) states=%d" % (
                n(r, "viol_content"), n(r, "viol_size"), n(r, "viol_durability"), n(r, "states"))
        else:
            cid = "torner/%s/%s/%s" % (r["config"], r["row"], r["profile"])
            nz = [k for k in ZERO if n(r, k)]
            v = "PASS" if n(r, "states") > 0 and not nz else "FAIL"
            det = "states=%d unjudged=%d%s" % (n(r, "states"), n(r, "unjudged"),
                  (" nonzero: " + ", ".join("%s=%d" % (k, n(r, k)) for k in nz)) if nz else "")
            if n(r, "states") == 0:
                det += " (no state explored)"
        cf.write("%s\t%s\t%s\n" % (cid, v, det))
        seen.add(cid)
        summ.append("| %s | %d | %d | %d | %d | %d | %d | %d | %d/%d/%d, %d, %d, %d | %s |" % (
            cid, n(r, "states"), n(r, "unjudged"), n(r, "viol_content"), n(r, "viol_size"),
            n(r, "viol_durability"), n(r, "writes_torn"), n(r, "p3_dirty"), n(r, "i1_violations"),
            n(r, "i1_skipped"), n(r, "i1_missing"), n(r, "i2_uncovered"), n(r, "i3_violations"),
            n(r, "i4_violations"), v))
    for fs in ("tau-ext4", "tau-xfs"):
        for row in ("ow4k", "ow16k", "ap2k", "ap4k", "ap16k", "prealloc", "hole"):
            for p in ("quiet", "busy"):
                cid = "torner/%s/%s/%s" % (fs, row, p)
                if cid not in seen:
                    cf.write("%s\tFAIL\tno capture in table.csv\n" % cid)
        cid = "torner/%s/ctl-record_fua_only-fds/ow16k/quiet" % fs
        if cid not in seen:
            cf.write("%s\tFAIL\tno capture in table.csv\n" % cid)
with open(out + "/summary.md", "a") as sf:
    sf.write("FC4 Torner reduced (full.sh q1/q2, LIMIT 300/400, control record_fua_only-fds)\n\n" + "\n".join(summ) + "\n")
PYEOF
fc_say "done: $(cut -f2 "$FC_OUT/cases.tsv" | sort | uniq -c | xargs)"
exit 0
