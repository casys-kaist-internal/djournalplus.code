#!/bin/bash
# thp-write.sh -- XFS tau with THP on, first half (host/thp-test.sh)
#   1. a plain XFS mount: random writes, truncates and punches with large
#      folios match a reference copy, also after a remount
#   2. the tjournal mount, files that are not tau: a plain file gets large
#      folios (the control), a file under the random operations matches
#   3. a file with large folios cached, clean and dirty, is activated and
#      rewritten through tau: the activation writes the dirty ones back, and a
#      tau write splits (or drops) the large folio it lands on, so its block
#      gets an order-0 folio
#   4. files an mmap reader (MADV_HUGEPAGE) faults while they are activated
#      and rewritten: the tau writes meet PMD-sized folios, some mapped
# Folios added are counted with the mm_filemap_add_to_page_cache tracepoint,
# splits and drops with tau's probes; a WARNING in dmesg fails the run.  The
# tjournal file system is left mounted for the power cut.
cd ~/tautest/guest || exit 1
. ./common.sh
THP=$TAU_BIN/tauthp
REF=/var/tmp/tauthp
EV=/sys/kernel/tracing/events/filemap/mm_filemap_add_to_page_cache
PROBES=/sys/module/tau_journal/parameters/tau_probe_wr_large_
NR=16
TRIG=

[ -x "$THP" ] || die "missing $THP (build with tools/tautest/Makefile)"
grep -qE '\[(always|madvise)\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null ||
	die "THP is off in this kernel"

# hist_on: count the folios added on the test file system, per inode and order
hist_on() {
	local mm kdev

	[ -n "$TRIG" ] && sudo sh -c "echo '!$TRIG' > $EV/trigger"
	mm=$(mountpoint -d "$TAU_MNT") || die "$TAU_MNT is not mounted"
	kdev=$(( (${mm%:*} << 20) | ${mm#*:} ))
	TRIG="hist:keys=i_ino,order:size=4096 if s_dev == $kdev"
	sudo sh -c "echo '$TRIG' > $EV/trigger" || die "cannot set the hist trigger"
}
# large <path>: folios of order > 0 added for it since hist_on
large() {
	local ino

	ino=$(stat -c %i "$1") || { echo 0; return; }
	sudo cat $EV/hist |
		sed -nE 's/^\{ i_ino: *([0-9]+), order: *([0-9]+) \} hitcount: *([0-9]+).*/\1 \2 \3/p' |
		awk -v ino="$ino" '$1 == ino && $2 > 0 {n += $3} END {print n + 0}'
}
# met: large folios a tau write split or dropped so far
met() { echo $(( $(cat ${PROBES}split 2>/dev/null || echo 0) + $(cat ${PROBES}drop 2>/dev/null || echo 0) )); }

sudo rm -rf "$REF"; sudo mkdir -p "$REF" || die "$REF"
sudo dmesg -C
fail=0; weak=0

echo "== 1. plain XFS mount =="
TAU_MOUNT_OPTS=defaults
mkfs_mount xfs
hist_on
sudo "$THP" ops "$TAU_MNT/o" "$REF/o" 1 3000 64 || fail=1
lo=$(large "$TAU_MNT/o")
sudo umount "$TAU_MNT" || die "umount"
mount_tau xfs
if [ "$(md5_of_file "$TAU_MNT/o")" = "$(md5_of_file "$REF/o")" ]; then
	echo "  after a remount: same as the reference"
else
	echo "  after a remount: DIFFERS from the reference"; fail=1
fi
echo "  large folios added: $lo"
[ "$lo" -gt 0 ] || weak=1

echo "== 2. tjournal mount, files that are not tau =="
export TAU_MOUNT_OPTS=tjournal
mkfs_mount xfs
hist_on
m0=$(met)
sudo "$THP" plain "$TAU_MNT/p" 64 1 1 0 fsync || fail=1
lp=$(large "$TAU_MNT/p")
sudo "$THP" ops "$TAU_MNT/q" "$REF/q" 2 3000 64 || fail=1
lq=$(large "$TAU_MNT/q")
echo "  large folios added: p $lp, q $lq"
[ "$lp" -gt 0 ] && [ "$lq" -gt 0 ] || weak=1

echo "== 3. activating a file with large folios cached =="
sudo "$THP" plain "$TAU_MNT/t" 64 2 1 0 fsync || fail=1
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
sudo "$THP" read "$TAU_MNT/t" 0 32 || fail=1		# clean ones, by readahead
sudo "$THP" plain "$TAU_MNT/t" 64 2 3 32 || fail=1	# dirty ones
lt0=$(large "$TAU_MNT/t")
m1=$(met)
sudo "$THP" tau "$TAU_MNT/t" 64 2 2 || fail=1
m2=$(met)
echo "  large folios cached before the activation: $lt0; split or dropped by its tau writes: $((m2 - m1))"
[ "$lt0" -gt 0 ] && [ $((m2 - m1)) -gt 0 ] || weak=1

echo "== 4. activating files an mmap reader is faulting =="
for i in $(seq 1 $NR); do
	sudo "$THP" plain "$TAU_MNT/r$i" 16 $((10 + i)) 1 0 fsync >/dev/null || fail=1
done
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
rm -f /tmp/thp.reader
lr=0; m3=$(met)
for i in $(seq 1 $NR); do
	sudo rm -f /tmp/thp.stop
	sudo "$THP" mmapread "$TAU_MNT/r$i" /tmp/thp.stop >> /tmp/thp.reader 2>&1 &
	rpid=$!
	sleep 0.3
	sudo "$THP" tau "$TAU_MNT/r$i" 16 $((10 + i)) 2 >/dev/null || fail=1
	sleep 0.3
	sudo touch /tmp/thp.stop
	wait $rpid || fail=1
	lr=$((lr + $(large "$TAU_MNT/r$i")))
done
m4=$(met)
cat /tmp/thp.reader
echo "  large folios the readers added: $lr; split or dropped by the tau writes: $((m4 - m3))"
[ "$lr" -gt 0 ] && [ $((m4 - m3)) -gt 0 ] || weak=1
echo "  of all of them, split $(cat ${PROBES}split 2>/dev/null), dropped $(cat ${PROBES}drop 2>/dev/null) (since boot)"
sudo sync -f "$REF"
n=$(kernel_faults); w=$(sudo dmesg | grep -c 'WARNING:')
echo "== kernel faults: $n, warnings: $w =="
[ "$n" -eq 0 ] && [ "$w" -eq 0 ] || { show_kernel_faults; sudo dmesg | grep -A5 'WARNING:' | head -20; fail=1; }
echo "THP_MET=$(( $(met) - m0 )) THP_WEAK=$weak"
[ $fail -eq 0 ] || { echo "RESULT: FAIL"; exit 1; }
echo "READY-FOR-CRASH"
