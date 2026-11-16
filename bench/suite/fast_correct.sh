#!/bin/bash
# fast_correct.sh -- libra08's fast correctness test of a tau version (the "fast test").
# The user's decision (2026-11-16, relayed by tau-ops): every tau change runs it, in about 6 h;
# libra08 takes the VM correctness side, libra09 the performance side, in parallel.
#
#   VERSION=v1.0 \
#   KDIR=/mnt/tau_backup/torner/kernels/tau-403 KMD5=45d5798546af47b7af84b80bac10d015 \
#   KDIR_LOCKDEP=/mnt/tau_backup/torner/kernels/tau-403-lockdep KMD5_LOCKDEP=<md5> \
#   [KINITRD=<file>|none] [KINITRD_LOCKDEP=<file>|none] \
#   [ITEMS="FC1 FC2 FC7 FC3 FC4 FC5 FC6"] [LANES=parallel|serial] [EXPECT=<file>] [DRY=1] \
#   bash bench/suite/fast_correct.sh
# KINITRD: the initrd the items' VMs boot with [none]; never /boot's by name (any build pairs with
# it). After each boot an item checks that the guest runs the pinned build (uname -v) and holds no
# module of another build (cases <prefix>/boot/kernel, <prefix>/boot/modules).
#
# Items: bench/suite/fc/fcN_*.sh (contract: bench/suite/README.md)
#   lane P, the PM1735 (86:00.0, vfio) in a tautest VM, one item at a time; the item takes
#           ~/soak-268/vm.lock itself:  FC1 tautest set, FC2 lockdep set (KDIR_LOCKDEP), FC7 DB counters
#   lane F, VMs on files only (no PM1735): FC3 CrashMonkey seq-1, FC4 Torner, FC5 kill test, FC6 R3
# LANES=serial [default]: P, then F. P's tautest VM alone takes the host's 32 CPUs (VM_NUMA=1: 2
# sockets x 16 vCPUs, 16 GiB of 1 GiB pages per node), so parallel (P beside F) overcommits, and
# starved vCPUs print soft lockups and hung tasks, which the log check counts (develop, 11-16).
#
# First, DRY or not: each kernel directory must hold PINNED and a bzImage of the given md5, or
# nothing runs (exit 3). DRY=1 then asks every item for its plan (commands, ESTIMATE_MIN), starts
# no VM and writes only under RAW_BASE/<VERSION>/dry-<UTC>/.
#
# Results
#   raw:    RAW_BASE/<VERSION>/<UTC>/FCn/          (RAW_BASE [/mnt/tau_backup/fast])
#   report: <umbrella>/bench/results/libra08/versions/<VERSION>/fast/<UTC>/
#           MANIFEST, REPORT.md, FCn/{cases.tsv,verdicts.tsv,faults.txt,summary.md}
# Verdict: PASS when every item finished (rc 0) with cases, no case is FAIL or XPASS once the
#   expected list is applied (bench/suite/expect/<VERSION>.txt, or EXPECT: an expected FAIL is
#   XFAIL; an expected FAIL that passed is XPASS, a control that lost its teeth), every kernel log
#   an item lists exists, and none has a fault line (FAULT_RE below) its allow.txt does not cover.
set -u
SUITE=$(cd "$(dirname "$(realpath "$0")")" && pwd)
R=$(cd "$SUITE/../.." && pwd)
die() { echo "fast_correct: $*" >&2; exit 3; }
VERSION=${VERSION:-}; [[ $VERSION =~ ^[A-Za-z0-9._-]+$ ]] || die "VERSION= (letters, digits, . _ -)"
KDIR=${KDIR:-}; KMD5=${KMD5:-}; KDIR_LOCKDEP=${KDIR_LOCKDEP:-}; KMD5_LOCKDEP=${KMD5_LOCKDEP:-}
# the initrd each VM boots with, given, never found by name (tau-ops 11-16: /boot/initrd.img-6.8.0tjournal+
# pairs with any build); none: no initrd -- the test kernels have the VMs' root drivers built in
KINITRD=${KINITRD:-none}; KINITRD_LOCKDEP=${KINITRD_LOCKDEP:-none}
for i in "$KINITRD" "$KINITRD_LOCKDEP"; do [ "$i" = none ] || [ -f "$i" ] || die "no initrd '$i' (a file, or none)"; done
ITEMS=${ITEMS:-FC1 FC2 FC7 FC3 FC4 FC5 FC6}
LANES=${LANES:-serial}; [[ $LANES == parallel || $LANES == serial ]] || die "LANES=parallel|serial"
DRY=${DRY:-0}
RAW_BASE=${RAW_BASE:-/mnt/tau_backup/fast}
EXPECT=${EXPECT-$SUITE/expect/$VERSION.txt}; [ -n "$EXPECT" ] && [ ! -f "$EXPECT" ] && EXPECT=
declare -A LANE=([FC1]=P [FC2]=P [FC7]=P [FC3]=F [FC4]=F [FC5]=F [FC6]=F)
declare -A TIMEOUT_MIN=([FC1]=180 [FC2]=90 [FC7]=60 [FC3]=40 [FC4]=150 [FC5]=240 [FC6]=40)
# kernel splats and lockdep / RCU / watchdog reports; the logs an item lists are kernel logs only
FAULT_RE='BUG:|BUG at |kernel BUG|WARNING:|Oops|general protection fault|Call Trace:|Kernel panic|possible circular locking|possible recursive locking|inconsistent lock state|possible irq lock inversion|suspicious RCU usage|bad unlock balance|turning off the locking correctness validator|MAX_LOCKDEP|UBSAN:|KASAN:|soft lockup|hung_task|blocked for more than|self-detected stall|rcu: INFO:'

script_of() { ls "$SUITE"/fc/"$(tr 'A-Z' 'a-z' <<< "$1")"_*.sh 2>/dev/null | head -1; }
kimage() { if [ -f "$1/arch/x86/boot/bzImage" ]; then echo "$1/arch/x86/boot/bzImage"; else echo "$1/bzImage"; fi; }
kver() { file -b "$(kimage "$1")" | grep -o 'version [^,]*' | sed 's/^version //'; }
check_kdir() {	# <label> <dir> <md5>
	[ -n "$2" ] && [ -d "$2" ] || die "$1: no kernel directory '$2'"
	[ -f "$2/PINNED" ] || die "$1: $2 has no PINNED (pin it as /mnt/tau_backup/torner/kernels/tau-<N>)"
	[ -f "$(kimage "$2")" ] || die "$1: no bzImage in $2"
	local got; got=$(md5sum < "$(kimage "$2")" | cut -c1-32)
	[ "$got" = "$3" ] || die "$1: $(kimage "$2") md5 $got, expected '$3'"
}
for it in $ITEMS; do [ -n "${LANE[$it]:-}" ] || die "unknown item $it"; done
check_kdir KDIR "$KDIR" "$KMD5"
case " $ITEMS " in *" FC2 "*) check_kdir KDIR_LOCKDEP "$KDIR_LOCKDEP" "$KMD5_LOCKDEP" ;; esac
UTC=$(date -u +%Y%m%dT%H%M%SZ)
REP_BASE=${REP_BASE:-$R/bench/results/libra08/versions}   # a trial run of the harness: point it elsewhere
if [ "$DRY" = 1 ]; then RAW=$RAW_BASE/$VERSION/dry-$UTC; REP=; else RAW=$RAW_BASE/$VERSION/$UTC; REP=$REP_BASE/$VERSION/fast/$UTC; fi
mkdir -p "$RAW" || die "cannot make $RAW"
exec 9> "$RAW_BASE/.fast_correct.lock"
if [ "$DRY" != 1 ]; then flock -n 9 || die "another fast_correct.sh runs ($RAW_BASE/.fast_correct.lock)"; fi

host_state() {
	echo "host: $(hostname -s), $(uname -rv), load $(cut -d' ' -f1-3 /proc/loadavg)"
	echo "86:00.0 driver: $(basename "$(readlink /sys/bus/pci/devices/0000:86:00.0/driver 2>/dev/null)" 2>/dev/null)"
	echo "VMs up: $(ps -C qemu-system-x86_64 -o pid=,args= | sed 's/ -.*hostfwd=tcp::\([0-9]*\)-.*/ ssh:\1/' | cut -c1-120 | xargs -d '\n' printf '[%s] ' 2>/dev/null)"
	echo "vm.lock holders: $(fuser ~/soak-268/vm.lock 2>/dev/null | xargs)"
	echo "1 GiB pages free: $(for n in /sys/devices/system/node/node[0-9]*; do printf '%s=%s ' "${n##*/}" "$(cat $n/hugepages/hugepages-1048576kB/free_hugepages)"; done)"
	echo "disk free: / $(df -h --output=avail / | tail -1 | xargs), /mnt/tau_backup $(df -h --output=avail /mnt/tau_backup | tail -1 | xargs)"
}
manifest() {
	echo "version: $VERSION"
	echo "run: $UTC$([ "$DRY" = 1 ] && echo " (DRY)")"
	echo "kernel: $KDIR | $(kver "$KDIR") | bzImage md5 $KMD5 | PINNED: $(head -c 160 "$KDIR/PINNED" | head -1)"
	[ -n "$KDIR_LOCKDEP" ] && echo "kernel_lockdep: $KDIR_LOCKDEP | $(kver "$KDIR_LOCKDEP") | bzImage md5 ${KMD5_LOCKDEP:-unchecked} | PINNED: $(head -c 160 "$KDIR_LOCKDEP/PINNED" 2>/dev/null | head -1)"
	for i in KINITRD KINITRD_LOCKDEP; do echo "$(tr 'A-Z' 'a-z' <<< "${i#K}"): ${!i}$([ "${!i}" != none ] && echo " (md5 $(md5sum < "${!i}" | cut -c1-32))")"; done
	echo "items: $ITEMS"
	echo "lanes: $LANES"
	echo "expect: ${EXPECT:-none}$([ -n "$EXPECT" ] && echo " (md5 $(md5sum < "$EXPECT" | cut -c1-32))")"
	echo "umbrella: $(git -C "$R" log -1 --format='%h %ci %s')"
	echo "umbrella_dirty: $(git -C "$R" status --short | tr '\n' ';')"
	echo "suite_md5: $(cd "$SUITE" && md5sum fast_correct.sh fc/*.sh | awk '{printf "%s=%s ", $2, substr($1,1,8)}')"
	# what the items call: the entry scripts, and a digest of each tool tree's tracked files as they are
	# on disk -- the same harness can be shown after a rebase changes the commit hashes
	echo "tools_md5: $(cd "$R" && md5sum tools/qemu/run_vm.sh tools/qemu/run_vm_torner.sh tools/torner/campaign/full.sh \
		tools/torner/campaign/table.sh tools/torner/campaign/table_guest.sh tools/torner/campaign/cell_csv.py \
		tools/killtest/killtest.py tools/crashmonkey/run_tau_suite.sh bench/scripts/costs/run_r3.sh \
		bench/scripts/costs/r3op.py bench/scripts/costs/r3_report.py /mnt/tau_backup/r3/vm/run_vm_r3.sh 2>/dev/null |
		awk '{printf "%s=%s ", $2, substr($1,1,8)}')"
	echo "tree_md5: $(cd "$R" && for t in tools/tautest tools/torner tools/killtest tools/crashmonkey bench/scripts/costs; do
		if [ -e "$t/.git" ]; then	# a repository of its own (crashmonkey)
			printf '%s=%s ' "$t" "$(cd "$t" && git ls-files -z 2>/dev/null | xargs -0 md5sum 2>/dev/null | md5sum | cut -c1-8)"
		else
			printf '%s=%s ' "$t" "$(git ls-files -z "$t" 2>/dev/null | xargs -0 md5sum 2>/dev/null | md5sum | cut -c1-8)"
		fi; done)"
	echo "raw: $RAW"
	host_state | sed 's/^/state_at_start: /'
}

# <FCn>: run one item (DRY: its plan); evaluate() turns its output into verdicts
run_item() {
	local it=$1 s d t0 rc to
	s=$(script_of "$it"); d=$RAW/$it; mkdir -p "$d"
	if [ -z "$s" ]; then echo "$it no script in $SUITE/fc" > "$d/run.log"; echo "$it rc=127 sec=0" >> "$RAW/items.txt"; return; fi
	rm -f "$d"/{cases.tsv,logs.list,allow.txt,plan.txt,summary.md}
	to=${TIMEOUT_MIN[$it]}; [ "$DRY" = 1 ] && to=5
	echo "[$(date '+%F %T')] $it start ($s)" >> "$RAW/progress.log"
	t0=$(date +%s)
	FC_OUT=$d FC_KDIR=$KDIR FC_KDIR_LOCKDEP=$KDIR_LOCKDEP FC_VERSION=$VERSION FC_ROOT=$R FC_DRY=$DRY \
		FC_INITRD=$KINITRD FC_INITRD_LOCKDEP=$KINITRD_LOCKDEP \
		timeout --kill-after=120 "${to}m" bash "$s" > "$d/run.log" 2>&1 < /dev/null
	rc=$?
	echo "$it rc=$rc sec=$(( $(date +%s) - t0 ))" >> "$RAW/items.txt"
	echo "[$(date '+%F %T')] $it end rc=$rc" >> "$RAW/progress.log"
	[ "$DRY" = 1 ] || evaluate "$it" "$rc"
}

evaluate() {
	local it=$1 rc=$2 d=$RAW/$1 f allow=
	: > "$d/faults.txt"
	[ -s "$d/allow.txt" ] && allow=$(cut -f1 "$d/allow.txt" | paste -sd'|')
	if [ -s "$d/logs.list" ]; then
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			[[ $f == /* ]] || f=$d/$f
			if [ ! -f "$f" ]; then echo "MISSING_LOG $f" >> "$d/faults.txt"; continue; fi
			grep -anE "$FAULT_RE" "$f" | { if [ -n "$allow" ]; then grep -vE "$allow"; else cat; fi; } |
				sed "s|^|$f:|" >> "$d/faults.txt"
		done < "$d/logs.list"
	fi
	python3 - "$d/cases.tsv" "${EXPECT:-/dev/null}" "$it" > "$d/verdicts.tsv" <<'PYEOF'
import fnmatch, os, sys
cases_f, expect_f, item = sys.argv[1:4]
exp = []
for l in open(expect_f):
    l = l.strip()
    if not l or l.startswith("#"):
        continue
    p = l.split(None, 2)
    if len(p) >= 2 and p[0] == item:
        exp.append((p[1], p[2] if len(p) > 2 else ""))
used = set()
if os.path.exists(cases_f):
    for l in open(cases_f):
        if not l.strip():
            continue
        c = (l.rstrip("\n").split("\t") + ["", ""])[:3]
        cid, raw, det = c
        hit = next(((g, why) for g, why in exp if fnmatch.fnmatchcase(cid, g)), None)
        if hit:
            used.add(hit[0])
        if raw == "PASS":
            fin, why = ("XPASS", "expected to fail on this version: " + hit[1]) if hit else ("PASS", "")
        elif raw == "FAIL":
            fin, why = ("XFAIL", hit[1]) if hit else ("FAIL", "")
        elif raw == "SKIP":
            fin, why = "SKIP", ""
        else:
            fin, why = "FAIL", "unknown status " + raw
        print("\t".join((cid, raw, fin, det, why)))
for g, why in exp:
    if g not in used:   # e.g. one file system never ran: an expected FAIL must be seen failing
        print("\t".join(("expect:" + g, "-", "FAIL", "expected to fail, but no such case ran", why)))
PYEOF
	local n_fail n_xpass n_cases n_faults n_missing v
	n_cases=$(grep -vc '^expect:' "$d/verdicts.tsv")	# the expect: rows count in n_fail
	n_fail=$(awk -F'\t' '$3=="FAIL"' "$d/verdicts.tsv" | wc -l)
	n_xpass=$(awk -F'\t' '$3=="XPASS"' "$d/verdicts.tsv" | wc -l)
	n_missing=$(grep -c '^MISSING_LOG' "$d/faults.txt")
	n_faults=$(( $(wc -l < "$d/faults.txt") - n_missing ))
	if [ "$rc" != 0 ]; then v=ERROR; [ "$rc" = 124 ] && v=TIMEOUT
	elif [ "$n_cases" = 0 ]; then v=ERROR
	elif [ $((n_fail + n_xpass + n_faults + n_missing)) -gt 0 ]; then v=FAIL
	elif [ ! -s "$d/logs.list" ]; then v=FAIL; echo "NO_LOGS the item listed no kernel log" >> "$d/faults.txt"
	else v=PASS; fi
	echo "$v" > "$d/VERDICT"
}

lane_items() { local it out=; for it in $ITEMS; do [ "${LANE[$it]}" = "$1" ] && out="$out $it"; done; echo $out; }
run_lane() { local it; for it in $(lane_items "$1"); do run_item "$it"; done; }

manifest > "$RAW/MANIFEST"
echo "fast_correct: $VERSION, $(kver "$KDIR"); $( [ "$DRY" = 1 ] && echo DRY || echo run) $UTC -> $RAW"
if [ "$LANES" = parallel ] || [ "$DRY" = 1 ]; then
	run_lane P & pp=$!
	run_lane F & pf=$!
	wait $pp $pf
else
	run_lane P; run_lane F
fi

if [ "$DRY" = 1 ]; then
	{
		echo "# fast_correct DRY: $VERSION ($UTC)"
		echo
		sed 's/^/    /' "$RAW/MANIFEST"
		echo
		echo "| item | lane | script | estimate min | notes |"
		echo "|---|---|---|---:|---|"
		tp=0; tf=0
		for it in $ITEMS; do
			d=$RAW/$it; est=$(sed -n 's/^ESTIMATE_MIN //p' "$d/plan.txt" 2>/dev/null | tail -1)
			note=$(grep -m1 '^NOW' "$d/plan.txt" 2>/dev/null)
			[ -z "$(script_of "$it")" ] && note="script not written yet"
			grep -q "rc=0 " <<< "$(grep "^$it " "$RAW/items.txt")" || [ -z "$(script_of "$it")" ] || note="$note dry rc: $(grep "^$it " "$RAW/items.txt" | cut -d' ' -f2)"
			echo "| $it | ${LANE[$it]} | $(basename "$(script_of "$it")" 2>/dev/null) | ${est:--} | ${note:--} |"
			[ "${LANE[$it]}" = P ] && tp=$((tp + ${est:-0})) || tf=$((tf + ${est:-0}))
		done
		echo
		echo "lane P ${tp} min, lane F ${tf} min: parallel ~$(( tp > tf ? tp : tf )) min, serial ~$((tp + tf)) min"
		for it in $ITEMS; do [ -s "$RAW/$it/plan.txt" ] && { echo; echo "## $it plan"; sed 's/^/    /' "$RAW/$it/plan.txt"; }; done
	} > "$RAW/REPORT.md"
	cat "$RAW/REPORT.md"
	exit 0
fi

# the report, and its copy in the umbrella
{
	all=PASS
	for it in $ITEMS; do [ "$(cat "$RAW/$it/VERDICT" 2>/dev/null)" = PASS ] || all=FAIL; done
	echo "# libra08 fast correctness: $VERSION ($UTC)"
	echo
	echo "VERDICT: $all"
	echo
	sed 's/^/    /' "$RAW/MANIFEST"
	echo "    end: $(date -u '+%F %T UTC')"
	echo
	echo "| item | lane | verdict | PASS | FAIL | XFAIL | XPASS | SKIP | fault lines | min |"
	echo "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"
	for it in $ITEMS; do
		d=$RAW/$it; c() { awk -F'\t' -v s="$1" '$3==s' "$d/verdicts.tsv" 2>/dev/null | wc -l; }
		sec=$(grep "^$it " "$RAW/items.txt" | sed -n 's/.*sec=\([0-9]*\).*/\1/p')
		echo "| $it | ${LANE[$it]} | $(cat "$d/VERDICT" 2>/dev/null || echo ERROR) | $(c PASS) | $(c FAIL) | $(c XFAIL) | $(c XPASS) | $(c SKIP) | $(grep -vc '^MISSING_LOG\|^NO_LOGS' "$d/faults.txt" 2>/dev/null) | $(( ${sec:-0} / 60 )) |"
	done
	echo
	echo "## Not passed (FAIL, XPASS) and expected failures (XFAIL)"
	for it in $ITEMS; do awk -F'\t' -v it="$it" '$3=="FAIL"||$3=="XPASS"||$3=="XFAIL" {print "- " it " " $1 ": " $3 " -- " $4 ($5 != "" ? " (" $5 ")" : "")}' "$RAW/$it/verdicts.tsv" 2>/dev/null; done
	echo
	echo "## Fault lines in the kernel logs (first 10 per item)"
	for it in $ITEMS; do [ -s "$RAW/$it/faults.txt" ] && { echo "- $it:"; head -10 "$RAW/$it/faults.txt" | cut -c1-300 | sed 's/^/    /'; }; done
	echo
	echo "## Item summaries"
	for it in $ITEMS; do [ -s "$RAW/$it/summary.md" ] && { echo; echo "### $it"; echo; cat "$RAW/$it/summary.md"; }; done
	echo
	echo "Raw: $RAW (run.log, cases.tsv, verdicts.tsv, faults.txt, logs.list per item)"
} > "$RAW/REPORT.md"
mkdir -p "$REP"
cp "$RAW/MANIFEST" "$RAW/REPORT.md" "$RAW/items.txt" "$REP/"
for it in $ITEMS; do
	mkdir -p "$REP/$it"
	for f in cases.tsv verdicts.tsv faults.txt summary.md VERDICT; do [ -f "$RAW/$it/$f" ] && cp "$RAW/$it/$f" "$REP/$it/"; done
done
grep '^VERDICT' "$RAW/REPORT.md"
echo "report: $REP/REPORT.md"
