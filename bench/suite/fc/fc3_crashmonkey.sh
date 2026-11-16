#!/bin/bash
# FC3: CrashMonkey ACE seq-1 (328 workloads) on ext4-tau and xfs-tau, in the CrashMonkey VM
# (tools/crashmonkey/run_tau_suite.sh: ssh 5557, a RAM scratch disk, no PM1735). build/ is
# rebuilt against FC_KDIR each time (it is read only; the output lands in
# tools/crashmonkey/build), under a lock, since there is one build/. The VM runs on an
# overlay of a copy of the tautest image (FC_CM_BASE), so a tautest VM may run beside it.
# Env: FC_OUT FC_KDIR FC_ROOT FC_DRY [FC_CM_BASE] [FC_CM_EXPECT=328]. Exit 2 = harness error.
set -u
FC_ROOT=${FC_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
: "${FC_OUT:?FC_OUT not set}" "${FC_KDIR:?FC_KDIR not set}"
CM=$FC_ROOT/tools/crashmonkey
BASE=${FC_CM_BASE:-/mnt/tau_backup/torner/base/qemu-image-20261021.qcow2}
EXP=${FC_CM_EXPECT:-328}
R=$FC_OUT/cm
CASES=$FC_OUT/cases.tsv
die() { echo "fc3: $*" >&2; exit 2; }
: > "$CASES"
echo "$R/console.log" > "$FC_OUT/logs.list"
if [ "${FC_DRY:-0}" = 1 ]; then
	{ echo "cd $CM && flock build.lock make -B KDIR=$FC_KDIR"
	  echo "cd $CM && INITRD=${FC_INITRD:-none} BASE=$BASE ./run_tau_suite.sh $FC_KDIR $R   (ssh 5557 sampled: uname -v, modules, taint)"
	  echo "ESTIMATE_MIN 12"; } > "$FC_OUT/plan.txt"
	exit 0
fi
[ -f "$BASE" ] || die "no base image $BASE"
[ -e "$R" ] && die "$R exists"
cd "$CM" || die "no $CM"
exec 8>"$CM/build.lock"
flock -w 3600 8 || die "another CrashMonkey run holds build.lock"
make -B KDIR="$FC_KDIR" > "$FC_OUT/cm-build.log" 2>&1 || die "build failed: $FC_OUT/cm-build.log"
# the guest's kernel and modules, sampled while the suite runs: CrashMonkey loads its
# own cow_brd and disk_wrapper (build/, out of tree); any other module is from elsewhere
sample() {
	local o="-i $HOME/.ssh/tau_vm_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
	while :; do
		timeout 20 ssh -p 5557 $o jhlee@localhost 'echo "K $(uname -v)"; echo "T $(cat /proc/sys/kernel/tainted)"; for m in $(cut -d" " -f1 /proc/modules); do echo "M $m $(cat /sys/module/$m/srcversion 2>/dev/null)"; done' 2>/dev/null
		sleep 15
	done
}
sample > "$FC_OUT/cm-guest.log" 8>&- &
spid=$!
INITRD=${FC_INITRD:-none} BASE=$BASE ./run_tau_suite.sh "$FC_KDIR" "$R" > "$FC_OUT/cm-run.log" 2>&1 8>&-
rc=$?
kill $spid 2>/dev/null; wait $spid 2>/dev/null
want=$(file -b "$FC_KDIR/arch/x86/boot/bzImage" | grep -o 'version [^,]*' | sed 's/^version [^ ]* ([^)]*) //')
python3 -I - "$FC_OUT/cm-guest.log" "$want" "$CM/build" >> "$CASES" <<'Q'
import subprocess, sys
log, want, build = sys.argv[1:4]
ks, mods, taint = set(), {}, 0
for l in open(log, errors='replace'):
	l = l.rstrip('\n')
	if l.startswith('K '): ks.add(l[2:])
	elif l.startswith('T ') and l[2:].strip().isdigit(): taint |= int(l[2:])
	elif l.startswith('M '):
		p = l.split()
		mods[p[1]] = p[2] if len(p) > 2 else ''
def sv(m):
	try: return subprocess.run(['modinfo', '-F', 'srcversion', f'{build}/{m}.ko'], capture_output=True, text=True).stdout.strip()
	except OSError: return ''
if not ks:
	print('cm/boot/kernel\tFAIL\tno sample of the guest')
elif ks == {want}:
	print(f'cm/boot/kernel\tPASS\t{want}')
else:
	print(f'cm/boot/kernel\tFAIL\tguest {sorted(ks)}, pinned {want!r}')
bad = [f'{m}({s or "?"})' for m, s in sorted(mods.items()) if m not in ('cow_brd', 'disk_wrapper') or s != sv(m)]
print(f'cm/boot/modules\t{"FAIL" if bad or not ks else "PASS"}\t' + (('not CrashMonkey\'s build: ' + ' '.join(bad)) if bad else 'loaded: ' + (' '.join(sorted(mods)) or 'none')))
print(f'cm/end/taint-W\t{"FAIL" if taint & 512 or not ks else "PASS"}\ttainted (or of samples)={taint}')
Q
python3 -I - "$R/campaign.log" "$EXP" "$rc" >> "$CASES" <<'P'
import re, sys
log, exp, rc = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
	txt = open(log, errors='replace').read().splitlines()
except OSError:
	txt = []
kern = next((m.group(1) for l in txt for m in [re.search(r'(#\d+) SMP', l)] if m), '#?')
seen = set()
for l in txt:
	m = re.match(r'^(ext4-tau|xfs-tau)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$', l)
	if m:
		v, p, f, c, k = m.group(1), *map(int, m.groups()[1:])
		seen.add(v)
		ok = p == exp and f == 0 and c == 0 and k == 0
		print(f'cm/seq1/{v}\t{"PASS" if ok else "FAIL"}\t{kern} {p}/{f}/{c} fault-lines {k} (rc {rc})')
for v in ('ext4-tau', 'xfs-tau'):
	if v not in seen:
		print(f'cm/seq1/{v}\tFAIL\t{kern} no result (rc {rc})')
P
exit 0
