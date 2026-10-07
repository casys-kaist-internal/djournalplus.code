#!/bin/bash
# Host-side VM helpers. Source this, do not execute it.
#
# The VM is the one from tools/qemu/run_vm.sh: a kernel booted directly by
# qemu with the real NVMe passed through, reachable over ssh on localhost:5555.

set -u

TAU_TOOLS=${TAU_TOOLS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
TAUFS_KERNEL=${TAUFS_KERNEL:-$(cd "$TAU_TOOLS/.." && pwd)/codes/djournalplus-kernel.code}
SSH_PORT=${SSH_PORT:-5555}
SSH_HOST=${SSH_HOST:-jhlee@localhost}
# A key of its own for the test VM: the guest is reachable only on localhost and
# the harness runs unattended, so it must not depend on whatever key the host
# user happens to have loaded. Falls back to the default identities if absent.
TAU_VM_KEY=${TAU_VM_KEY:-$HOME/.ssh/tau_vm_ed25519}
[ -f "$TAU_VM_KEY" ] && SSH_KEY_ARGS="-i $TAU_VM_KEY -o IdentitiesOnly=yes" || SSH_KEY_ARGS=""
VM_LOG=${VM_LOG:-/tmp/tau-vm-console.log}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-150}
# Guest RAM bound to the host's nodes (run_vm.sh): the host's NUMA balancing
# skips bound memory.  Unbound, its scans over guest RAM froze the whole VM for
# ~23 s now and then (6.8 KVM; README "Reading a failure").  VM_MEM must then
# split into two whole GB halves.
export VM_NUMA=${VM_NUMA:-1}

# -n matters: several callers sit inside "something | while read ...", and an
# ssh that reads stdin swallows the rest of that list, silently running only the
# first item (xfs-hold-test.sh ran one config out of three this way).  No caller
# feeds vm_ssh on stdin.
vm_ssh() {
	ssh -n -p "$SSH_PORT" $SSH_KEY_ARGS -o BatchMode=yes -o StrictHostKeyChecking=no \
	    -o ConnectTimeout=5 "$SSH_HOST" "$@"
}

# timeout(1) execs its argument, so it cannot run a shell function: spell the
# ssh out here.  ("timeout N vm_ssh ..." fails with exit 127, which reads like a
# test failure.)
# -n matters: this is called from inside "echo $CONFIGS | while read", and an
# ssh that reads stdin swallows the remaining configs, silently running only the
# first one.
vm_ssh_timeout() {
	local t=$1; shift
	timeout "$t" ssh -n -p "$SSH_PORT" $SSH_KEY_ARGS -o BatchMode=yes \
	    -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_HOST" "$@"
}

vm_scp() {
	scp -P "$SSH_PORT" $SSH_KEY_ARGS -o BatchMode=yes -o StrictHostKeyChecking=no "$@"
}

# Find the qemu process. Match the command line start, otherwise the pattern
# also matches the shell running this script and you end up killing yourself.
vm_pid() { pgrep -f '^qemu-system-x86_64 ' | head -1; }

vm_is_up() { vm_ssh true >/dev/null 2>&1; }

# Kill qemu and WAIT for it to actually be gone.  A fixed short sleep is not
# enough: the passthrough NVMe and the preallocated guest memory are only
# released when the process finally exits, and starting the next qemu before
# that fails outright ("VM did not come up").
vm_kill() {
	local pid waited=0

	pid=$(vm_pid)
	[ -n "$pid" ] || return 0
	sudo kill -9 "$pid"
	while [ -n "$(vm_pid)" ] && [ "$waited" -lt 60 ]; do
		sleep 1
		waited=$((waited + 1))
	done
	[ -n "$(vm_pid)" ] && { echo "qemu $pid will not die" >&2; return 1; }
	sleep 3	# let vfio release the device and the memory come back
	return 0
}

# Power-cut simulation: SIGKILL qemu so nothing is flushed.
vm_crash() {
	local pid
	pid=$(vm_pid)
	[ -n "$pid" ] || { echo "no VM running"; return 1; }
	echo "crashing VM (pid $pid)"
	sudo kill -9 "$pid"
	sleep 2
}

vm_boot() {
	[ -f "$TAUFS_KERNEL/arch/x86/boot/bzImage" ] ||
		{ echo "no bzImage at $TAUFS_KERNEL" >&2; return 1; }
	echo "booting VM (kernel $TAUFS_KERNEL/arch/x86/boot/bzImage)"
	# setsid --fork, not plain setsid: a background job in a non-interactive
	# shell is not a process group leader, so setsid(1) skips its fork and
	# just execs -- qemu stays a child of this shell and the calling test
	# script then blocks at exit for as long as the VM lives.  Two crash-test
	# runs sat in do_wait for an hour and a half each before this was caught.
	( cd "$TAU_TOOLS/qemu" && TAUFS_KERNEL="$TAUFS_KERNEL" \
		setsid --fork sudo -E bash run_vm.sh >> "$VM_LOG" 2>&1 & )

	local waited=0
	while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
		sleep 3
		waited=$((waited + 3))
		if vm_is_up; then
			echo "VM up ($(vm_ssh 'uname -r; uname -a | grep -o "#[0-9]*"' | tr '\n' ' '))"
			return 0
		fi
	done
	echo "VM did not come up in ${BOOT_TIMEOUT}s; see $VM_LOG" >&2
	return 1
}

vm_reboot() { vm_kill; vm_boot; }

# The build counter of the tree we are about to test ("#173" style).
vm_expected_build() {
	local v
	v=$(cat "$TAUFS_KERNEL/.version" 2>/dev/null) || return 1
	[ -n "$v" ] && echo "#$v"
}

# What the guest is actually running.
vm_running_build() { vm_ssh 'uname -a' 2>/dev/null | grep -o '#[0-9]*'; }

# Boot the tree we just built, ALWAYS.
#
# The old "vm_is_up || vm_boot" silently reused whatever VM was already
# running.  After any test the VM is up again (the crash tests reboot it), so
# the next run wrote its workload with the PREVIOUS kernel and only verified
# with the new one - a mixed-kernel run that looks like a real result and
# quietly invalidates every A/B comparison.  Boot fresh and prove the version.
vm_boot_tested() {
	local want got

	vm_kill
	vm_boot || return 1

	want=$(vm_expected_build)
	got=$(vm_running_build)
	if [ -n "$want" ] && [ "$want" != "$got" ]; then
		echo "kernel mismatch: built $want but guest runs $got" >&2
		echo "(is $TAUFS_KERNEL/arch/x86/boot/bzImage the tree you built?)" >&2
		return 1
	fi
	echo "testing kernel ${got:-unknown}"
}

# Copy the guest scripts and (optionally) rebuild the binaries in the guest.
vm_sync_tests() {
	echo "syncing test scripts to guest"
	vm_ssh 'mkdir -p ~/tautest/guest ~/tautest/src' || return 1
	vm_scp "$TAU_TOOLS/tautest/guest/"*.sh "$SSH_HOST:~/tautest/guest/" || return 1
	vm_scp "$TAU_TOOLS/tautest/src/"*.c "$SSH_HOST:~/tautest/src/" || return 1
	vm_scp "$TAU_TOOLS/tautest/Makefile" "$SSH_HOST:~/tautest/" || return 1
	vm_ssh 'chmod +x ~/tautest/guest/*.sh && cd ~/tautest && make >/dev/null && make install PREFIX=$HOME/tautest >/dev/null && sync' ||
		{ echo "guest build failed" >&2; return 1; }
	# ...and confirm it, so a build that somehow produced nothing cannot pass
	# for a successful sync again.
	vm_ssh 'cd ~/tautest && for b in tauwrite tauwrite_nofsync taurace tauappend tauoverwrite tausync tautorn pgscan taushort tauabort; do
			[ -s "$b" ] && [ -x "$b" ] || { echo "bad binary: $b" >&2; exit 1; }
		done' || { echo "guest binaries missing or empty" >&2; return 1; }
	echo "guest tools built"
}

# Show what the kernel printed on the serial console (survives a wedged VM).
# the last two boots only: the console log keeps every boot
vm_console_faults() {
	local from

	from=$(grep -n 'Linux version' "$VM_LOG" 2>/dev/null | tail -2 | head -1 | cut -d: -f1)
	tail -n +"${from:-1}" "$VM_LOG" 2>/dev/null |
		grep -E 'kernel BUG at|invalid opcode|soft lockup|blocked for more than|WARNING: CPU' |
		head -10
}
