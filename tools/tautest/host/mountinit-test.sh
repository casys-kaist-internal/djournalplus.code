#!/bin/bash
# Mount-time journal setup (bug.md #66, #67): journald waits for the mount to
# back the journal, and a mount that cannot back it fails cleanly.  One boot
# per case.  Needs a CONFIG_TAU_PROBE_TORN kernel (delay and fault sites).
#   usage: mountinit-test.sh [xfs|ext4|both] [race,initfail]
# WARNING: runs mkfs on $TAU_DEV inside the guest.

set -u
cd "$(dirname "$0")" || exit 1
. ./vm.sh

FSLIST=${1:-both}
PARTS=${2:-race,initfail}
case "$FSLIST" in
both) FSLIST="xfs ext4" ;;
xfs|ext4) ;;
*) echo "usage: $0 [xfs|ext4|both] [race,initfail]" >&2; exit 2 ;;
esac

# the console of the running boot; vm_console_faults has no divide error
boot_faults() {
	local from

	from=$(grep -n 'Linux version' "$VM_LOG" 2>/dev/null | tail -1 | cut -d: -f1)
	tail -n +"${from:-1}" "$VM_LOG" 2>/dev/null |
		grep -E 'divide error|Oops|general protection|kernel BUG at|invalid opcode|soft lockup|blocked for more than|WARNING: CPU' |
		head -10
}

rc=0
summary=""
for fs in $FSLIST; do
	for part in ${PARTS//,/ }; do
		echo
		echo "############ $fs $part ############"
		vm_boot_tested || { rc=1; break 2; }
		vm_sync_tests || { rc=1; break 2; }
		if vm_ssh "~/tautest/guest/mountinit.sh $fs $part" &&
		   [ -z "$(boot_faults)" ]; then
			summary+="$fs $part: PASS\n"
		else
			summary+="$fs $part: FAIL\n"
			boot_faults
			rc=1
		fi
		vm_crash
	done
done

echo
echo "== summary =="
printf "%b" "$summary"
[ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES (console log: $VM_LOG)"
exit $rc
