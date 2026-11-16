#!/bin/bash
# FC7: PostgreSQL and MySQL, 120 s sysbench (16 threads, 100k rows) on ext4-tau and xfs-tau:
# the run finishes, and the counters that must stay 0 under a DB are 0 -- atoz_twotx (a DB
# page's blocks share one tx), act_flush / act_dirty (DB files are opened with the flag
# before any write). A kernel without a counter (beta has no atoz_twotx, act_flush) gives
# SKIP for it. TPS goes in the detail only: performance is libra09's.
# Env: FC_OUT FC_KDIR FC_ROOT FC_DRY. Exit 2 = harness error.
. "$(dirname "$0")/lib-tautest.sh"
: "${FC_KDIR:?FC_KDIR not set}"
TAUFS_KERNEL=$FC_KDIR
CTRS="atoz_twotx act_flush act_dirty"
[ "$FC_DRY" = 1 ] && : > "$FC_OUT/plan.txt"
fc_setup
fc_boot_check fc7
db() {
	local w=$1 fs=$2 f=$FC_OUT/db-$1-$2.log rc
	if [ "$FC_DRY" = 1 ]; then
		echo "boot $TAUFS_KERNEL; guest: ~/tautest/guest/db-bench.sh $fs $w 120 16 100000; read tau_probe_{${CTRS// /,}}" >> "$FC_OUT/plan.txt"
		return
	fi
	echo "$(date '+%H:%M:%S') db $w $fs"
	{ vm_boot_tested && vm_sync_tests &&
	  vm_ssh_timeout 2400 "~/tautest/guest/db-bench.sh $fs $w 120 16 100000" &&
	  vm_ssh_timeout 30 "cd /sys/module/tau_journal/parameters && for c in $CTRS; do if [ -r tau_probe_\$c ]; then echo \"CTR \$c \$(cat tau_probe_\$c)\"; else echo \"CTR \$c -\"; fi; done"
	} > "$f" 2>&1 9>&-
	rc=$?
	vm_kill 9>&-
	python3 -I - "$w" "$fs" "$f" "$rc" "$CTRS" >> "$CASES" <<'P'
import re, sys
w, fs, log, rc, ctrs = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5].split()
txt = open(log, errors='replace').read().splitlines()
kern = next((m.group(1) for l in txt for m in [re.search(r'testing kernel (#\d+)', l)] if m), '#?')
tps = [f'{m.group(1)} {m.group(2)}' for l in txt for m in [re.match(r'^RESULT\s+(\S+)\s+TPS\s+(\S+)', l)] if m]
ok = rc == 0 and len(tps) == 2
print(f'db/{w}/{fs}/run\t{"PASS" if ok else "FAIL"}\t{kern} rc={rc} ' + ', '.join(tps))
ctr = {m.group(1): m.group(2) for l in txt for m in [re.match(r'^CTR (\S+) (\S+)$', l)] if m}
for c in ctrs:
	v = ctr.get(c)
	if v is None:
		print(f'db/{w}/{fs}/{c}\tFAIL\t{kern} not read')
	elif v == '-':
		print(f'db/{w}/{fs}/{c}\tSKIP\t{kern} no such counter')
	else:
		print(f'db/{w}/{fs}/{c}\t{"PASS" if v == "0" else "FAIL"}\t{kern} {v}')
P
}
for w in postgres mysql; do
	for fs in ext4-tau xfs-tau; do
		db $w $fs
	done
done
[ "$FC_DRY" = 1 ] && { echo "ESTIMATE_MIN 20" >> "$FC_OUT/plan.txt"; exit 0; }
exit 0
