#!/bin/bash
# Every tautest host test once -- or, with HOURS set, over and over until the
# deadline: the overnight soak.  A new test goes into TESTS below and is then
# part of both.  One line per test in <dir>/summary.txt, every test's log
# next to it, and for a failure the console tail and the guest's dmesg too.
#   usage: suite.sh [results-dir]
#   env:   HOURS (0: one pass), ONLY (regex on the names), TAU_VM_LOCK (file)
# WARNING: runs mkfs on $TAU_DEV inside the guest, test after test.

set -u
cd "$(dirname "$0")" || exit 1

# one VM job at a time; qemu must not inherit the lock (fd 9)
if [ -z "${TAU_VM_LOCKED:-}" ]; then
	exec 9>"${TAU_VM_LOCK:-/tmp/tau-vm.lock}"
	flock -n 9 || { echo "another VM job holds ${TAU_VM_LOCK:-/tmp/tau-vm.lock}" >&2; exit 1; }
	export TAU_VM_LOCKED=1
fi
. ./vm.sh

R=${1:-$HOME/tau-suite/$(date +%m%d-%H%M)}
mkdir -p "$R" || exit 1
OUT=$R/summary.txt
HOURS=${HOURS:-0}
DEADLINE=$(( $(date +%s) + HOURS * 3600 ))

# name, deadline in seconds, command
TESTS=(
	"abort		2400	./abort-test.sh both"
	"crash		900	./crash-test.sh both"
	"sync		1800	./sync-test.sh both"
	"sync-race	1800	./sync-race-test.sh both 6"
	"revoke		1800	./revoke-test.sh both all 1"
	"seg-order	900	./seg-order-test.sh xfs"
	"seg-reuse	900	./seg-reuse-test.sh xfs"
	"seg-straddle-xfs 900	./seg-straddle-test.sh xfs"
	"seg-straddle-ext4 900	./seg-straddle-test.sh ext4"
	"seg-adopt	900	./seg-adopt-test.sh xfs"
	"split		1800	./split-test.sh both all 1"
	"epoch-ext4	1800	./epoch-test.sh ext4 all 1"
	"epoch-xfs	1800	./epoch-test.sh xfs all,partial 1"
	"trunc-reuse	2400	./trunc-reuse-test.sh both all"
	"range		2400	./range-test.sh both all"
	"shortcopy	900	./shortcopy-test.sh both"
	"odirect	900	./odirect-test.sh both"
	"unlink		2400	./unlink-test.sh both all"
	"writeend	1200	./writeend-test.sh both"
	"mtime		1800	./mtime-test.sh both all"
	"falloc		1800	./falloc-test.sh both"
	"repair		1800	./repair-test.sh"
	"cp-race	2400	./cp-race-test.sh"
	"xfs-hold	2400	./xfs-hold-test.sh"
	"trunc-race	900	./trunc-race-test.sh both 60"
	"stress-ext4	2400	./stress-test.sh ext4 150 6 5"
	"stress-xfs	2400	./stress-test.sh xfs 150 6 5"
	"torn		3600	./torn-test.sh both 1 300"
	"db-crash-pg	2400	./db-crash-test.sh both postgres 20"
	"db-crash-mysql	2400	./db-crash-test.sh both mysql 20"
	"db-rollback	2400	./db-rollback-test.sh both 1"
	"flushorder	1800	./flushorder-test.sh both append,falloc,subappend,overwrite 24"
	"pg-torn-ext4	5400	env FS=ext4 ./pg-torn-test.sh 1 300"
	"pg-torn-xfs	5400	env FS=xfs ./pg-torn-test.sh 1 300"
)

pass=0; fail=0; inconc=0
log() { echo "$(date '+%m-%d %H:%M') $*" | tee -a "$OUT"; }

# run <name> <deadline> <cmd...>: past the deadline qemu is killed -- a wedged
# guest ignores everything else -- and the test is failed
run() {
	local n=$1 d=$2 f=$R/$1.log pid end rc r
	shift 2
	"$@" > "$f" 2>&1 9>&- &
	pid=$!
	end=$((SECONDS + d))
	while kill -0 $pid 2>/dev/null; do
		if [ $SECONDS -ge $end ]; then
			echo "DEADLINE: ${d}s passed, killing qemu" >> "$f"
			tail -3000 "$VM_LOG" > "$f.console" 2>/dev/null
			vm_kill
			sleep 5
			kill $pid 2>/dev/null
			break
		fi
		sleep 10
	done
	wait $pid
	rc=$?
	r=$(grep -hE 'ALL PASS|FAILURES|NO LOSS SEEN|^RESULT' "$f" | tail -1)
	if [ $rc -eq 0 ]; then
		pass=$((pass + 1))
		rm -f "$f.console"
		log "$n: ok | $r"
	elif [ $rc -eq 2 ] && grep -qE 'INCONCLUSIVE|NO LOSS SEEN' "$f"; then
		inconc=$((inconc + 1))
		log "$n: INCONCLUSIVE | $r"
	else
		fail=$((fail + 1))
		[ -s "$f.console" ] || tail -3000 "$VM_LOG" > "$f.console" 2>/dev/null
		vm_ssh_timeout 30 'sudo dmesg' > "$R/$n.dmesg" 2>&1
		log "$n: FAIL rc=$rc | $r"
	fi
}

log "start: kernel #$(cat "$TAUFS_KERNEL/.version" 2>/dev/null), ${HOURS}h, results in $R"
c=0
while :; do
	c=$((c + 1))
	for t in "${TESTS[@]}"; do
		read -r name dl cmd <<< "$t"
		[ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]] && continue
		[ "$HOURS" -gt 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ] && break 2
		run "c$c-$name" "$dl" $cmd
	done
	log "== pass $c done: ok=$pass fail=$fail inconclusive=$inconc"
	[ "$HOURS" -gt 0 ] && [ "$(date +%s)" -lt "$DEADLINE" ] || break
done
log "done: ok=$pass fail=$fail inconclusive=$inconc"
[ $fail -eq 0 ]
