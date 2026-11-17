#!/bin/bash
# A write SIGKILLed part way leaves the file all old or all new, at runtime and
# after a remount (G1 against a dying writer).  Every 4 KiB block carries its
# write's generation (src/taukill.c).
#   uffd: the source's second page sits behind a userfaultfd that never answers;
#         the writer is killed while the kernel waits on it -- gen 0 must stay whole
#   race: 1 MiB pwrites back to back, killed at a random moment, ROUNDS times
#   usage: killwrite.sh <xfs|ext4> [rounds] [size]
cd ~/tautest/guest || exit 1
. ./common.sh
FS=${1:-}
case "$FS" in ext4|xfs) ;; *) die "usage: $0 <xfs|ext4> [rounds] [size]" ;; esac
ROUNDS=${2:-100}
SIZE=${3:-1048576}
K=$TAU_BIN/taukill
F=$TAU_MNT/k
PIDF=/tmp/taukill.pid
P=/sys/module/tau_journal/parameters
probe() { cat "$P/tau_probe_$1" 2>/dev/null || echo -; }
[ -x "$K" ] || die "missing $K"

# start <mode>: taukill <mode> in the background as root, its pid in $PIDF
start() {
	rm -f "$PIDF"
	sudo bash -c "echo \$\$ > $PIDF; exec $K $1 $F $SIZE" > /tmp/taukill.out 2>&1 &
	for _ in $(seq 50); do [ -s "$PIDF" ] && return 0; sleep 0.1; done
	die "taukill $1 did not start"
}
kill9() { sudo kill -9 "$(cat "$PIDF")"; wait 2>/dev/null; }

mkfs_mount "$FS"
sudo "$K" prep "$F" "$SIZE" || die "prep failed"
k0=$(probe wr_killed)
rc=0

echo "== uffd: killed while the kernel waits on the source's second page =="
start uffd
for _ in $(seq 300); do grep -q BLOCKED /tmp/taukill.out && break; sleep 0.1; done
cat /tmp/taukill.out | sed 's/^/  /'
if ! grep -q BLOCKED /tmp/taukill.out; then
	kill9
	echo "RESULT[$FS uffd]: INCONCLUSIVE (the kernel never waited on the userfaultfd)"
	rc=1
else
	kill9
	out=$(sudo "$K" check "$F" "$SIZE"); echo "$out" | sed 's/^/  /'
	if [ "$(echo "$out" | tail -1)" = "UNIFORM gen=0" ]; then
		echo "RESULT[$FS uffd]: PASS"
	else
		echo "RESULT[$FS uffd]: FAIL ($(echo "$out" | tail -1))"
		rc=1
	fi
fi

echo "== race: $ROUNDS rounds of 1 MiB pwrites killed at a random moment =="
torn=0
gens=""
for r in $(seq "$ROUNDS"); do
	start race
	sleep "0.$(printf '%03d' $((RANDOM % 400 + 50)))"
	kill9
	out=$(sudo "$K" check "$F" "$SIZE")
	if [ $? -ne 0 ]; then
		torn=$((torn + 1))
		[ $torn -le 3 ] && echo "  round $r: $(echo "$out" | tr '\n' ' ')"
	fi
	gens="$(echo "$out" | tail -1)"
done
echo "  last: $gens"
echo "== remount =="
sudo umount "$TAU_MNT" || die "umount failed"
mount_tau "$FS"
out=$(sudo "$K" check "$F" "$SIZE") || torn=$((torn + 1))
echo "$out" | sed 's/^/  /'
k1=$(probe wr_killed)
[ "$k0" = - ] && killed=- || killed=$((k1 - k0))
echo "  wr_killed+$killed (writes the kill reached past their start, ended whole)"
if [ "$torn" -ne 0 ]; then
	echo "RESULT[$FS race]: FAIL ($torn of $ROUNDS rounds torn)"
	rc=1
elif [ "$killed" = 0 ]; then
	echo "RESULT[$FS race]: INCONCLUSIVE (no kill reached a write past its start)"
	rc=1
else
	echo "RESULT[$FS race]: PASS (0 of $ROUNDS torn, wr_killed+$killed)"
fi
show_kernel_faults
sudo umount "$TAU_MNT"
exit $rc
