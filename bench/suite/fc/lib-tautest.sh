#!/bin/bash
# Shared by fc1_tautest.sh, fc2_lockdep.sh, fc7_dbcounters.sh: a tautest VM on the test
# NVMe (86:00.0), booted from a pinned kernel, under ~/soak-268/vm.lock.
# Sourced; the caller sets FC_OUT, FC_ROOT, FC_DRY and the kernel dir in TAUFS_KERNEL.
set -u
FC_ROOT=${FC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
FC_DRY=${FC_DRY:-0}
: "${FC_OUT:?FC_OUT not set}"
TT=$FC_ROOT/tools/tautest/host
FC_DEV=${FC_DEV:-0000:86:00.0}
FC_LOCK=${FC_LOCK:-$HOME/soak-268/vm.lock}
CASES=$FC_OUT/cases.tsv
FC_VERSION=${FC_VERSION:-?} FC_KDIR=${FC_KDIR:-${TAUFS_KERNEL:-}}
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fc_die() { echo "$(basename "$0"): $*" >&2; exit 2; }

# fc_setup: VM settings of every b403 run, the lock, the env; not in a dry run
fc_setup() {
	: > "$CASES"
	export VM_MEM=32G VM_HUGEPAGES=1 VM_NUMA=1
	export VM_LOG=$FC_OUT/console.log
	export VM_KCMDLINE_EXTRA="ignore_loglevel printk.devkmsg=on"
	export TAU_SEGSIZE=16m ARM_DEADLINE=240
	# the initrd fast_correct.sh names (default none); run_vm.sh's own default pairs any
	# bzImage with /boot's initrd of the release, whatever build that came from
	export VM_INITRD=${FC_INITRD:-none}
	echo "$VM_LOG" > "$FC_OUT/logs.list"
	[ "$FC_DRY" = 1 ] && return 0
	[ -f "$TAUFS_KERNEL/arch/x86/boot/bzImage" ] || fc_die "no bzImage in $TAUFS_KERNEL"
	[ "$(basename "$(readlink /sys/bus/pci/devices/$FC_DEV/driver)")" = vfio-pci ] ||
		fc_die "$FC_DEV is not on vfio-pci"
	exec 9>"$FC_LOCK"
	flock -w 1800 9 || fc_die "another VM job holds $FC_LOCK"
	export TAU_VM_LOCKED=1
	# set_env.sh sets TAUFS_KERNEL to the working tree: keep the pinned one
	local k=$TAUFS_KERNEL
	cd "$FC_ROOT" && { set +u; source set_env.sh >/dev/null 2>&1; set -u; }
	TAUFS_KERNEL=$k
	export TAUFS_ENV_SOURCED=1 TAUFS_KERNEL
	cd "$TT" || fc_die "no $TT"
	. ./vm.sh
}

# fc_boot_check <case prefix>: one boot of the pinned kernel before the tests --
# <prefix>/boot/kernel, <prefix>/boot/modules (fc/lib.sh: uname -v is the pinned build's,
# no module loaded, as the tests load none) and <prefix>/boot/taint-W
fc_boot_check() {
	if [ "$FC_DRY" = 1 ]; then
		echo "boot $TAUFS_KERNEL (initrd ${VM_INITRD}); check uname -v, /proc/modules, taint" >> "$FC_OUT/plan.txt"
		return 0
	fi
	vm_boot_tested 9>&- > "$FC_OUT/boot-check.log" 2>&1 || { fc_case "$1/boot/kernel" FAIL "no boot (boot-check.log)"; return 0; }
	fc_guest_check "$SSH_PORT" "$1" "" "$TAUFS_KERNEL" >> "$FC_OUT/boot-check.log"
	fc_guest_taint_w "$SSH_PORT" "$1/boot"
	[ "${FC_LOCKDEP:-0}" = 1 ] && fc_debug_locks_live "$1/boot/debug_locks"
	vm_kill 9>&-
}

# lockdep kernels (FC2, FC_LOCKDEP=1): lockdep turns itself off after its first report, or
# quietly on some taints, and a run with it off tests no lock order. Two checks:
# fc_debug_locks_live <case>: the running guest's /proc/lockdep_stats says debug_locks 1
fc_debug_locks_live() {
	local v
	v=$(vm_ssh "sudo awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats" 2>/dev/null)
	if [ "$v" = 1 ]; then fc_case "$1" PASS "debug_locks 1"; else fc_case "$1" FAIL "debug_locks '${v:-unreadable}'"; fi
}
# fc_debug_locks_span <case> <console line from>: every boot in the console since that line
# started lockdep, and none turned it off
fc_debug_locks_span() {
	local s boots ld off
	s=$(tail -n +"$2" "$VM_LOG" 2>/dev/null)
	boots=$(grep -ac 'Linux version' <<< "$s")
	ld=$(grep -ac 'Lock dependency validator' <<< "$s")
	off=$(grep -aiE 'Disabling lock debugging|turning off the locking correctness validator|lockdep is turned off|debug_locks.*off' <<< "$s" | head -3 | tr '\n' ' ')
	if [ "$boots" -gt 0 ] && [ "$boots" = "$ld" ] && [ -z "$off" ]; then
		fc_case "$1" PASS "$boots boots, lockdep on in each, never turned off"
	else
		fc_case "$1" FAIL "boots $boots, lockdep started $ld${off:+, off: $off}"
	fi
}

# fc_run <name> <deadline s> <command...>: one tautest host script, log $FC_OUT/<name>.log,
# qemu killed past the deadline (a wedged guest ignores SIGKILL of the script)
fc_run() {
	local n=$1 d=$2 f=$FC_OUT/$1.log pid end
	shift 2
	if [ "$FC_DRY" = 1 ]; then
		echo "(cd $TT && TAUFS_KERNEL=$TAUFS_KERNEL $*) > $f    # deadline ${d}s" >> "$FC_OUT/plan.txt"
		return 0
	fi
	echo "$(date '+%H:%M:%S') start $n"
	local c0=$(( $(cat "$VM_LOG" 2>/dev/null | wc -l) + 1 ))
	"$@" > "$f" 2>&1 9>&- &
	pid=$!
	end=$((SECONDS + d))
	while kill -0 $pid 2>/dev/null; do
		if [ $SECONDS -ge $end ]; then
			echo "DEADLINE: ${d}s passed, killing qemu" >> "$f"
			vm_kill 9>&-; sleep 5
			kill $(ps -o pid= --ppid $pid) $pid 2>/dev/null
			break
		fi
		sleep 10
	done
	wait $pid
	echo "$(date '+%H:%M:%S') $n rc=$?"
	fc_cases "$n" "$f"
	[ "${FC_LOCKDEP:-0}" = 1 ] && fc_debug_locks_span "$n/debug_locks" "$c0"
	return 0
}

# fc_cases <test> <log>: case lines into cases.tsv. A case is <test>/<case>/<fs>
# (<test>/<fs> when the script has no cases); rounds fold into one line, worst first.
# INCONCLUSIVE counts as FAIL; a log with no result, or past its deadline, is <test>/harness FAIL.
fc_cases() {
	python3 -I - "$1" "$2" >> "$CASES" <<'P'
import re, sys
test, log = sys.argv[1], sys.argv[2]
txt = open(log, errors='replace').read().splitlines()
kern = next((m.group(1) for l in txt for m in [re.search(r'testing kernel (#\d+)', l)] if m), '#?')
res, order = {}, []
def put(cid, verdict, detail):
	v = 'PASS' if verdict == 'PASS' else 'FAIL'
	d = detail.strip()
	if verdict == 'INCONCLUSIVE':
		d = 'INCONCLUSIVE ' + d
	if cid not in res:
		order.append(cid)
		res[cid] = (v, d)
	elif v == 'FAIL' and res[cid][0] == 'PASS':
		res[cid] = (v, d)
summ = re.compile(r'^(xfs|ext4) (?:(.+?) )?(?:round \d+/\d+)?: ?(PASS|FAIL|INCONCLUSIVE)\b(.*)$')
summ2 = re.compile(r'^(xfs|ext4) (.+?): (PASS|FAIL|INCONCLUSIVE)\b(.*)$')
tag = re.compile(r'^RESULT\[(xfs|ext4)(?: r\d+)?\]: (PASS|FAIL|INCONCLUSIVE)\b(.*)$')
plain = re.compile(r'^RESULT: (PASS|FAIL|INCONCLUSIVE)\b(.*)$')
head = re.compile(r'^#+ (xfs|ext4)\b')
insum, fs, plains = False, None, []
for l in txt:
	if l.startswith('== summary =='):
		insum = True
		continue
	m = head.match(l)
	if m:
		fs = m.group(1)
	m = tag.match(l)
	if m:
		put(f'{test}/{m.group(1)}', m.group(2), m.group(3))
		continue
	if insum:
		m = summ.match(l) or summ2.match(l)
		if m:
			fsx, case = m.group(1), (m.group(2) or '').strip()
			put(f'{test}/{case}/{fsx}' if case else f'{test}/{fsx}', m.group(3), m.group(4))
		continue
	m = plain.match(l)
	if m and fs:
		plains.append((f'{test}/{fs}', m.group(1), m.group(2)))
if not res:
	for c in plains:
		put(*c)
dead = any(l.startswith('DEADLINE') for l in txt)
if dead or not res:
	order.append(f'{test}/harness')
	res[f'{test}/harness'] = ('FAIL', 'deadline' if dead else 'no result in ' + log)
for c in order:
	v, d = res[c]
	print(f'{c}\t{v}\t{kern} {d}'.rstrip())
P
}
