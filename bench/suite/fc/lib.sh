# bench/suite/fc/lib.sh -- helpers for the fast_correct.sh items; source it from an item script.
# The contract (bench/suite/README.md): fast_correct.sh passes
#   FC_OUT (this item's directory, made already), FC_KDIR (probe kernel, pinned),
#   FC_KDIR_LOCKDEP (lockdep kernel, pinned), FC_VERSION, FC_ROOT (umbrella), FC_DRY (1: plan only)
# and reads back from FC_OUT: cases.tsv, logs.list, allow.txt, plan.txt (DRY), summary.md.
set -u
: "${FC_OUT:?FC_OUT}" "${FC_ROOT:?FC_ROOT}" "${FC_VERSION:?FC_VERSION}" "${FC_KDIR:?FC_KDIR}"
FC_DRY=${FC_DRY:-0}
FC_KDIR_LOCKDEP=${FC_KDIR_LOCKDEP:-}
mkdir -p "$FC_OUT"

# one case: <id> <PASS|FAIL|SKIP> [detail]; ids stay the same from run to run (expect/*.txt names them)
fc_case() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$FC_OUT/cases.tsv"; }
# kernel logs (console, journalctl -k, dmesg) that fast_correct.sh scans for BUG / WARNING / lockdep
fc_logfile() { local f; for f in "$@"; do printf '%s\n' "$f" >> "$FC_OUT/logs.list"; done; }
# a fault line the item expects (an injected abort's dump, ...): <ERE> <why>
fc_allow() { printf '%s\t%s\n' "$1" "$2" >> "$FC_OUT/allow.txt"; }
# DRY: what would run, and the minutes it takes
fc_plan() { printf '%s\n' "$*" >> "$FC_OUT/plan.txt"; }
fc_estimate() { printf 'ESTIMATE_MIN %s\n' "$1" >> "$FC_OUT/plan.txt"; }
fc_note() { printf '%s\n' "$*" >> "$FC_OUT/summary.md"; }
fc_say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# a pinned kernel dir: a whole tree (arch/x86/boot/bzImage) or a flat copy (bzImage)
fc_kimage() { if [ -f "$1/arch/x86/boot/bzImage" ]; then echo "$1/arch/x86/boot/bzImage"; else echo "$1/bzImage"; fi; }
# "6.8.0tjournal+ (jhlee@libra08) #403 SMP PREEMPT_DYNAMIC Sun Nov 15 14:16:46 KST 2026"
fc_kver() { file -b "$(fc_kimage "$1")" | grep -o 'version [^,]*' | sed 's/^version //'; }
# what the guest's `uname -v` prints: "#403 SMP PREEMPT_DYNAMIC Sun Nov 15 14:16:46 KST 2026"
fc_kuts() { fc_kver "$1" | sed 's/^[^ ]* ([^)]*) //'; }
fc_kbuild() { fc_kuts "$1" | awk '{print $1}'; }

# the tau_vm key, as every libra08 VM script uses it
FC_SSH_KEY=${FC_SSH_KEY:-$HOME/.ssh/tau_vm_ed25519}
FC_SSH_OPTS="-i $FC_SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"
fc_ssh() { local port=$1; shift; ssh -p "$port" $FC_SSH_OPTS jhlee@localhost "$@"; }
fc_wait_ssh() { local port=$1 limit=${2:-180} t=0; until fc_ssh "$port" true 2>/dev/null; do sleep 5; t=$((t + 5)); [ $t -lt "$limit" ] || return 1; done; }
# After a boot: the guest runs the pinned build and holds no module of another build (tau-ops, 11-16:
# an initrd or /lib/modules of another build can pair with a bzImage without an error; MODVERSIONS
# refuses most such modules, but not one whose symbols happen to match).
# fc_guest_check <ssh port> <case prefix> "<modules allowed, from the pinned tree>" [<kernel dir>]
#   <prefix>/boot/kernel   uname -v is the pinned bzImage's
#   <prefix>/boot/modules  every loaded module is allowed and has the pinned tree's srcversion
# and prints the guest's taint value (fc_guest_taint_w checks it again at the end).
fc_guest_check() {
	local port=$1 pre=$2 allow=" $3 " kd=${4:-$FC_KDIR} want g mods m sv tsv ko bad=
	want=$(fc_kuts "$kd")
	g=$(fc_ssh "$port" "uname -v" 2>/dev/null)
	if [ "$g" = "$want" ]; then fc_case "$pre/boot/kernel" PASS "$g"; else fc_case "$pre/boot/kernel" FAIL "guest '$g', pinned '$want'"; fi
	mods=$(fc_ssh "$port" "cut -d' ' -f1 /proc/modules" 2>/dev/null | xargs)
	for m in $mods; do
		if [[ $allow == *" $m "* ]]; then
			ko=$(find "$kd" -name "$(tr _ '?' <<< "$m").ko" 2>/dev/null | head -1)
			sv=$(fc_ssh "$port" "cat /sys/module/$m/srcversion" 2>/dev/null)
			tsv=$( [ -n "$ko" ] && modinfo -F srcversion "$ko" 2>/dev/null)
			[ -n "$sv" ] && [ "$sv" = "$tsv" ] || bad="$bad $m(srcversion ${sv:-?}, tree ${tsv:-?})"
		else
			bad="$bad $m"
		fi
	done
	if [ -z "$bad" ]; then fc_case "$pre/boot/modules" PASS "loaded: ${mods:-none}"; else fc_case "$pre/boot/modules" FAIL "not from the pinned build:$bad"; fi
	fc_ssh "$port" "cat /proc/sys/kernel/tainted" 2>/dev/null
}
# <prefix>/end/taint-W: no WARN in the guest (taint bit 9) by the end of the item
fc_guest_taint_w() {
	local t; t=$(fc_ssh "$1" "cat /proc/sys/kernel/tainted" 2>/dev/null)
	if [ -n "$t" ] && [ $(( t & 512 )) = 0 ]; then fc_case "$2/end/taint-W" PASS "tainted=$t"; else fc_case "$2/end/taint-W" FAIL "tainted=${t:-?} (512 = a WARN fired)"; fi
}

# free 1 GiB pages on the node that has the most
fc_hp1g_most() { local n m=0 f; for n in /sys/devices/system/node/node[0-9]*; do f=$(cat "$n/hugepages/hugepages-1048576kB/free_hugepages" 2>/dev/null || echo 0); [ "$f" -gt "$m" ] && m=$f; done; echo "$m"; }
