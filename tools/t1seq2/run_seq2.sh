#!/bin/bash
# T1 seq-2 sample on τ (libra09, 2026-11-06): the workloads of a sample.py sample on ext4-tau and
# xfs-tau, one CrashMonkey VM per variant, run side by side.
# Each variant follows run_tau_suite.sh + run_tau_vm.sh step for step (same VM, kernel tree, setup,
# CrashMonkey type, CM_* environment and device sizes as the seq-1 rows), except:
#   - the sample's .so files are copied into the guest's build/tests/seq2s after the setup;
#   - its own ports, overlay and 2 GB scratch per VM;
#   - a deadline per variant.
# STOCK=1 runs CrashMonkey's stock types (ext4, xfs) instead, as results-libra09-1980/run_stock.sh:
# the guest's stock mkfs/fsck, no CM_* environment, no tjournal mount (τ compiled in, inactive).
# Guest: an overlay on vm_imgs/cm-guest-ubuntu.qcow2, the tree's bzImage, the initrd of its build.
#   run_seq2.sh <sample dir> [out dir]   env FSES ("ext4 xfs"), DEADLINE_MIN (720),
#                                         STOCK=1, SUMMARY_ONLY=1 (only the table, from a finished run)
# Exit 0 when every variant ran all its tests with no failure and no fault line. Parsed whole first.
{
set -u
H=$(cd "$(dirname "$0")" && pwd); CM=$(cd "$H/../crashmonkey" && pwd)
R=$(cd "$CM/../.." && pwd); V=$R/tools/qemu/vm_imgs; KD=$R/codes/djournalplus-kernel.code
die() { echo "run_seq2: $*" >&2; exit 1; }
KV=$(strings "$KD/arch/x86/boot/bzImage" 2>/dev/null | grep -m1 '^6\.8\.0tjournal')
BN=$(echo "$KV" | grep -oE '#[0-9]+' | tr -d '#'); [ -n "$BN" ] || die "no tau bzImage in $KD"
S=$(realpath "${1:?sample dir}"); OUT=$(realpath -m "${2:-$S/run-$BN}")
FSES=${FSES:-ext4 xfs}; DEADLINE_MIN=${DEADLINE_MIN:-720}; VS=tau; [ -n "${STOCK:-}" ] && VS=stock
BASE=$V/cm-guest-ubuntu.qcow2; INITRD=$V/initrd.img-6.8.0tjournal+-$BN
[ -f "$INITRD" ] || die "no initrd $INITRD"
N=$(ls "$S"/so/*.so 2>/dev/null | wc -l); [ "$N" -gt 0 ] || die "no workloads in $S/so"
# build/ against this tree, as run_tau_suite.sh checks
rel=$(cat "$KD/include/config/kernel.release")
for m in cow_brd disk_wrapper; do
	[ "$(modinfo -F vermagic $CM/build/$m.ko | awk '{print $1}')" = "$rel" ] && [ $CM/build/$m.ko -nt "$KD/vmlinux" ] ||
		die "build/$m.ko is not built for this tree: make -B KDIR=$KD"
done
O="-i $HOME/.ssh/tau_vm_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
   -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=30"
FAULTS='WARNING:|BUG:|Oops|soft lockup|hung_task|blocked for more than|Call Trace'
# workloads that map a file writable and shared run on plain files (CM_TAU_PLAIN), as run_tau_vm.sh
PLAIN=$(grep -lE 'PROT_WRITE.*MAP_SHARED|MAP_SHARED.*PROT_WRITE' "$S"/cpp/j-lang*.cpp 2>/dev/null |
	xargs -r -n1 basename | sed 's/\.cpp$//' | tr '\n' ' ')
mkdir -p "$OUT" || exit 1
exec > >(tee -a "$OUT/campaign.log") 2>&1
[ -z "${SUMMARY_ONLY:-}" ] && cp "$0" "$H/sample.py" "$H/classify.py" "$OUT/"
echo "run_seq2 ${SUMMARY_ONLY:+(summary only) }$(date -u --rfc-3339=seconds): $KV; $N workloads of $S; $FSES ($VS); $(wc -w <<< "$PLAIN") on plain files"

variant() {  # <fs> <ssh port> <gdb port>
	local fs=$1 port=$2 gport=$3 d=$OUT/$1-$VS
	local ov=$V/cm-seq2-$fs.qcow2 sc=$V/cm-seq2-$fs.raw
	local g="ssh -p $port $O jhlee@localhost"
	pgrep -f "hostfwd=tcp::$port-:22" > /dev/null && { echo "$fs: a VM on port $port is running"; return 1; }
	mkdir -p "$d"; rm -f "${ov:?}" "${sc:?}"
	qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$ov" || return 1
	INITRD=$INITRD ROOTFS=$ov SCRATCH=$sc SCRATCH_SIZE=2G SSH_PORT=$port GDB_PORT=$gport TAUFS_KERNEL=$KD \
		sg kvm -c "bash $R/tools/qemu/run_vm_torner.sh" > "$d/console.log" 2>&1 < /dev/null &
	local qpid=$! rc=0
	PORT=$port bash "$CM/run_tau_vm.sh" setup > "$d/setup.log" 2>&1 || rc=1
	grep -q "^#$BN " "$d/setup.log" || { echo "$fs: guest is not #$BN"; rc=1; }
	[ $rc = 0 ] && { tar -C "$S/so" -cf - . | $g "mkdir -p ~/cm/build/tests/seq2s && tar -C ~/cm/build/tests/seq2s -xf -" &&
		[ "$($g "ls ~/cm/build/tests/seq2s | grep -c '\.so\$'")" = "$N" ] || { echo "$fs: copying the sample failed"; rc=1; }; }
	if [ $rc = 0 ]; then
		local B=/home/jhlee/cm/bin ENVS SIZE TYPE=$fs-tau	# in the guest; as run_tau_vm.sh run
		case $fs in
		ext4)	ENVS="CM_MKFS='$B/mke2fs -t ext4 -b 4096 -F -E lazy_itable_init=0,lazy_journal_init=0,tau_segsize=4m' CM_FSCK='$B/e2fsck -fy' CM_NEWUUID='$B/tune2fs -U random'"; SIZE=204800 ;;
		xfs)	ENVS="CM_MKFS='$B/mkfs.xfs -f -l tjsegsize=4m' CM_FSCK='$B/xfs_repair' CM_NEWUUID='$B/xfs_db -x -c \"uuid generate\"'"; SIZE=409600 ;;
		esac
		ENVS="$ENVS CM_MNT_OPTS=tjournal CM_TAU_PLAIN='$PLAIN'"
		if [ $VS = stock ]; then	# as run_stock.sh: the guest's own tools
			ENVS= TYPE=$fs
			$g 'mke2fs -V 2>&1 | head -1; mkfs.xfs -V 2>&1 | head -1' > "$d/stock-tools.txt"
		fi
		$g "cat > ~/cm/run-$fs.sh" <<EOF
cd ~/cm && rm -rf diff_results *xfsMonkey.log
sudo mkdir -p /mnt/snapshot     # c_harness mounts there and does not create it
sudo dmesg -C; sudo dmesg -w > run-$fs.dmesg & dpid=\$!
sudo env TERM=dumb $ENVS \\
	python3 xfsMonkey.py -f /dev/vda -d /dev/cow_ram0 -t $TYPE -e $SIZE -u build/tests/seq2s/ \\
	> run-$fs.out 2>&1 < /dev/null
sleep 1; sudo kill \$dpid
echo '===== cm done' >> run-$fs.out
EOF
		echo "$fs-$VS: start $(date -u +%T)"
		$g "setsid nohup bash ~/cm/run-$fs.sh > /dev/null 2>&1 < /dev/null &"
		local end=$((SECONDS + DEADLINE_MIN * 60))
		while sleep 30; do
			timeout 60 $g "tail -c 4000 ~/cm/run-$fs.out" > "$d/run-$fs.tail" 2>/dev/null
			grep -q "===== cm done" "$d/run-$fs.tail" 2>/dev/null && break
			[ $SECONDS -lt $end ] || { echo "DEADLINE: $fs-$VS did not finish"; break; }
		done
		$g "cd ~/cm && tar -czf - run-$fs.out run-$fs.dmesg *xfsMonkey.log diff_results bugs stat missing others 2>/dev/null" |
			tar -C "$d" -xzf - || echo "$fs: pull failed"
		echo "$fs-$VS: end $(date -u +%T)"
	fi
	timeout 30 $g "sudo poweroff" 2> /dev/null
	local i; for i in $(seq 60); do kill -0 $qpid 2> /dev/null || break; sleep 2; done
	kill -0 $qpid 2> /dev/null && { echo "$fs: qemu still up: killing it"; pkill -f "hostfwd=tcp::$port-:22"; sleep 2; }
	pgrep -f "hostfwd=tcp::$port-:22" > /dev/null || rm -f "${ov:?}" "${sc:?}"
}

if [ -z "${SUMMARY_ONLY:-}" ]; then
	i=0 pids=
	for fs in $FSES; do
		variant $fs $((5557 + i)) $((1237 + i)) &
		pids+=" $!"; i=$((i + 1)); sleep 20	# staggered boots
	done
	wait $pids	# not a bare wait: that would wait for the log's tee too
fi

st=0
# pass / fail / could-not-run as copy_diff.sh printed them (run-<fs>.out)
printf '%-9s %5s %5s %14s %12s %8s\n' variant pass fail could-not-run fault-lines console
for fs in $FSES; do
	d=$OUT/$fs-$VS
	if [ ! -f $d/run-$fs.out ]; then printf '%-9s no result\n' $fs-$VS; st=1; continue; fi
	v=$(sed 's/\x1b\[[0-9;]*m//g' $d/run-$fs.out | grep -oE ': (Passed|Failed|Could not run) test')
	p=$(grep -c Passed <<< "$v"); f=$(grep -c Failed <<< "$v"); c=$(grep -c 'Could not' <<< "$v")
	k=$(grep -cE "$FAULTS" $d/run-$fs.dmesg 2>/dev/null); kc=$(grep -cE "$FAULTS" $d/console.log)
	printf '%-9s %5s %5s %14s %12s %8s\n' $fs-$VS $p $f $c "${k:-?}" "$kc"
	[ "$f" = 0 ] && [ "${k:-1}" = 0 ] && [ "$kc" = 0 ] && [ $((p + f + c)) = "$N" ] || st=1
	# the counts from xfsMonkey.log, which overrides copy_diff.sh's "Passed" for a test the harness
	# gave up on, and why each could not run (could_not_run.tsv): invalid as generated, or to look at
	echo "          from the logs: $(python3 "$H/classify.py" "$d" "$S")"
	grep -qE '(unexplained|harness-assert)$' "$d/could_not_run.tsv" && st=1
done
echo "===== done $(date -u --rfc-3339=seconds): $OUT"
exit $st
}
