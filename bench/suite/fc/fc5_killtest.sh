#!/bin/bash
# FC5 -- kill test reduced (tools/killtest db, the QEMU-SIGKILL database test libra09 runs):
# PostgreSQL and MySQL x tau-ext4 and tau-xfs, FC5_TRIALS [5] random kills each under
# oltp_write_only, on libra09's §2 setting (tools/killtest/README.md, results/libra09/SUMMARY.md §2:
# revision profile, 2.5 GiB VM, uniform keys, the databases' default log sizes, --kill-on random)
# with a shorter run and kill window: --run-s 100 --kill-delay-s 30:90 (§2: the profile's run,
# 30:270). The VM's disks are files in KILLTEST_WORK (/mnt/tau_backup/killtest-work): no PM1735,
# no vm.lock. One configuration at a time with killtest's 16 vCPUs (lane F's budget beside lane P).
# Recorded per trial: the file system's mount after the kill (tau's replay) and the database's
# recovery, in trials.jsonl (mount_ms, recovery_ms) and in each case's detail.
# Cases: kill/<postgres|mysql>/<tau-ext4|tau-xfs>/tNN -- clean PASS; torn, torn_scan,
#        recovery_failed (or anything else) FAIL; no_trigger SKIP.
# A missing golden image (KILLTEST_WORK/db-<db>-<fs>-revision-mem2560M[-logdefault].img) is
# prepared first by killtest (sysbench prepare, then a 300 s aging run: ~25 min each) and kept for
# the next runs; FC5_REPREP=1 makes them again (after an on-disk format change).
# The kill page is /dev/shm/killtest-<run> (ivshmem): with logind's RemoveIPC=yes it goes away if
# the user's last login session ends during a run (bench/workspace/machine-inventory, 11-15).
# Trials take ~3.5 min: ~75 min for 20, plus the golden images made.
set -u
. "$(dirname "$(realpath "$0")")/lib.sh"
KT=$FC_ROOT/tools/killtest/killtest.py
export KILLTEST_WORK=${KILLTEST_WORK:-/mnt/tau_backup/killtest-work}
TRIALS=${FC5_TRIALS:-5}
DELAY=${FC5_KILL_DELAY:-30:90}
RUN_S=${FC5_RUN_S:-100}
SEED=${FC5_SEED:-20261116}
DBS=${FC5_DBS:-postgres mysql}
FSS=${FC5_FSS:-tau-ext4 tau-xfs}
KIMG=$(fc_kimage "$FC_KDIR")
ARGS="--profile revision --mem 2560M --rand-type uniform --log-default --kill-on random --kill-delay-s $DELAY --run-s $RUN_S --trials $TRIALS --keep-console all --kernel $KIMG --tag fast-$FC_VERSION"
[ "${FC5_REPREP:-0}" = 1 ] && ARGS="$ARGS --reprep"
golden() { echo "$KILLTEST_WORK/db-$1-$2-revision-mem2560M$([ "$1" = mysql ] && echo -logdefault).img"; }

problems= missing=0
[ -f "$KT" ] || problems="$problems; no $KT"
[ -f "$KILLTEST_WORK/rootfs.img" ] || problems="$problems; no $KILLTEST_WORK/rootfs.img (tools/killtest/mkrootfs.sh, sudo, once)"
for db in $DBS; do for fs in $FSS; do [ -f "$(golden $db $fs)" ] || missing=$((missing + 1)); done; done
[ "${FC5_REPREP:-0}" = 1 ] && missing=$(( $(wc -w <<< "$DBS") * $(wc -w <<< "$FSS") ))

if [ "$FC_DRY" = 1 ]; then
	fc_plan "kernel $KIMG = $(fc_kver "$FC_KDIR")"
	for db in $DBS; do for fs in $FSS; do
		fc_plan "env -u LD_LIBRARY_PATH KILLTEST_WORK=$KILLTEST_WORK python3 $KT db --db $db --fs $fs $ARGS --seed $SEED --out FC5/killtest"
		[ -f "$(golden $db $fs)" ] && [ "${FC5_REPREP:-0}" != 1 ] && fc_plan "  golden $(golden $db $fs): kept ($(date -r "$(golden $db $fs)" '+%F %T'))" ||
			fc_plan "  golden $(golden $db $fs): to prepare first (~25 min)"
	done; done
	fc_plan "cases: kill/{postgres,mysql}/{tau-ext4,tau-xfs}/t00..t$(printf %02d $((TRIALS - 1))); recovery: mount_ms (tau replay), recovery_ms (database)"
	fc_plan "kernel check: kill/<db>/<fs>/kernel -- every trial's guest uname -v = the pinned build; no initrd (killtest boots its rootfs, root=/dev/vda)"
	[ -n "$problems" ] && fc_plan "NOW (would stop a real run):${problems#;}"
	fc_estimate $(( $(wc -w <<< "$DBS") * $(wc -w <<< "$FSS") * TRIALS * 7 / 2 + missing * 25 + 2 ))
	exit 0
fi
[ -z "$problems" ] || { fc_say "cannot run:${problems#;}"; exit 2; }

mkdir -p "$FC_OUT/killtest"
for db in $DBS; do for fs in $FSS; do
	fc_say "killtest db $db $fs ($TRIALS trials$([ -f "$(golden $db $fs)" ] || echo ", golden image first"))"
	env -u LD_LIBRARY_PATH python3 "$KT" db --db $db --fs $fs $ARGS --seed $SEED --out "$FC_OUT/killtest" \
		> "$FC_OUT/killtest-$db-$fs.out" 2>&1 < /dev/null
	echo "rc=$?" >> "$FC_OUT/killtest-$db-$fs.out"
	tail -3 "$FC_OUT/killtest-$db-$fs.out"
done; done
for f in "$FC_OUT"/killtest/*/logs/*.console; do [ -f "$f" ] && fc_logfile "$f"; done

python3 - "$FC_OUT" "$TRIALS" "$DBS" "$FSS" "$(fc_kuts "$FC_KDIR")" <<'PYEOF'
import glob, json, os, statistics, sys
out, trials, dbs, fss = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(), sys.argv[4].split()
want = sys.argv[5].replace("_", " ")     # killtest keeps the guest's uname -v with "_" as " "
summ = ["| db | fs | trials | clean | not clean | mount ms median (max) | DB recovery s median (max) |",
        "|---|---|---:|---:|---:|---:|---:|"]
with open(out + "/cases.tsv", "a") as cf:
    for db in dbs:
        for fs in fss:
            runs = sorted(d for d in glob.glob(out + "/killtest/*_%s_%s_*" % (db, fs)) if os.path.isdir(d))
            recs = []
            for d in runs:
                p = os.path.join(d, "trials.jsonl")
                if os.path.exists(p):
                    recs += [json.loads(l) for l in open(p) if l.strip()]
            got = {r["trial"]: r for r in recs}
            mts, rts = [], []
            for t in range(trials):
                cid = "kill/%s/%s/t%02d" % (db, fs, t)
                r = got.get(t)
                if r is None:
                    cf.write("%s\tFAIL\tno trial record\n" % cid)
                    continue
                v = r.get("verdict", "?")
                st = "PASS" if v == "clean" else ("SKIP" if v == "no_trigger" else "FAIL")
                mt, rt = r.get("mount_ms"), r.get("recovery_ms")
                if isinstance(mt, (int, float)): mts.append(mt)
                if isinstance(rt, (int, float)) and r.get("db_start_rc") == 0: rts.append(rt / 1000)
                det = "verdict=%s kill_after_start_ms=%s mount_ms=%s recovery_ms=%s db_start_rc=%s in_flight=%s" % (
                    v, r.get("kill_after_start_ms"), mt, rt, r.get("db_start_rc"), (r.get("at_kill") or {}).get("w"))
                cf.write("%s\t%s\t%s\n" % (cid, st, det))
            vs = sorted({r.get("version", "?") for r in got.values()})
            ok = bool(got) and vs == [want]
            cf.write("kill/%s/%s/kernel\t%s\tguest uname -v %s; pinned %s (no initrd: killtest boots its rootfs directly)\n"
                     % (db, fs, "PASS" if ok else "FAIL", " | ".join(vs) or "-", want))
            nc = sum(1 for r in got.values() if r.get("verdict") == "clean")
            fm = lambda xs, f: ("%s (%s)" % (f(statistics.median(xs)), f(max(xs)))) if xs else "-"
            summ.append("| %s | %s | %d | %d | %d | %s | %s |" % (db, fs, len(got), nc, len(got) - nc,
                        fm(mts, lambda x: "%.0f" % x), fm(rts, lambda x: "%.1f" % x)))
with open(out + "/summary.md", "a") as sf:
    sf.write("FC5 kill test reduced (killtest db, §2 setting, --run-s/--kill-delay-s shortened)\n\n" + "\n".join(summ) + "\n")
PYEOF
fc_say "done: $(cut -f2 "$FC_OUT/cases.tsv" | sort | uniq -c | xargs)"
exit 0
