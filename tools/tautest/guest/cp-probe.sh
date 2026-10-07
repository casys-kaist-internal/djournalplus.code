#!/bin/bash
# plan.md §1, measurement only: which checkpoint rule writes how much home, and
# how much of that a later rewrite undoes.  PostgreSQL, sysbench
# oltp_update_non_index (pg-torn.sh), one setting of the rules per call.
# Needs CONFIG_TAU_PROBE_TORN.
#   usage: cp-probe.sh <xfs|ext4> [secs]
#   env:   SMALL (tau_cp_small_tx, 512), AGE (tau_max_transaction_age, 120),
#          JGB (journal, both phases, 32)
cd ~/tautest/guest || exit 1
. ./common.sh
FS=$1; SECS=${2:-600}
P=/sys/module/tau_journal/parameters

echo "${SMALL:-512}" | sudo tee $P/tau_cp_small_tx >/dev/null
# COMMITW: background commits at once, taken at the mount pg-torn does
[ -n "${COMMITW:-}" ] && echo "$COMMITW" | sudo tee $P/tau_commit_workers >/dev/null
echo "${AGE:-120}" | sudo tee $P/tau_max_transaction_age >/dev/null
echo "== cp-probe $FS ${SECS}s: small $(cat $P/tau_cp_small_tx)," \
     "age $(cat $P/tau_max_transaction_age), commit works $(cat $P/tau_commit_workers 2>/dev/null)," \
     "journal ${JGB:-32}GB =="
# pinned blocks over time; pg-torn zeroes the counter when its run starts
( while sleep 15; do cat $P/tau_probe_jh_live; done ) > /tmp/cp-jh.txt 2>/dev/null &
sampler=$!
# CONSOLE=1: every kernel message and a 5 s sample on the serial console,
# which the host keeps even if the guest stops answering
if [ "${CONSOLE:-0}" = 1 ]; then
	sudo dmesg -n 8
	cat > /tmp/cp-console.sh <<-EOF
	#!/bin/bash
	P=$P
	while sleep 5; do
		m=\$(grep -E '^(MemFree|Dirty|Writeback):' /proc/meminfo | tr -s ' ' | tr '\n' ' ')
		echo "CP \$(date +%T) jh=\$(cat \$P/tau_probe_jh_live) seg_free=\$(cat \$P/tau_probe_seg_free)/\$(cat \$P/tau_probe_seg_total) cp_runs=\$(cat \$P/tau_probe_cp_runs) shrink=\$(cat \$P/tau_probe_shrink_scan) space_wait=\$(cat \$P/tau_probe_space_wait) \$m"
	done > /dev/ttyS0
	EOF
	sudo bash /tmp/cp-console.sh &
fi
DUMP_ALL=1 TAU_JOURNAL_GB=${JGB:-32} LOAD_JOURNAL_GB=${JGB:-32} THREADS=32 \
	SHARED_BUFFERS=128MB FPW=off LOAD_ONLY=0 DATA_CHECKSUMS=on FS="$FS" \
	./pg-torn.sh "$SECS" 16 2600000 > /tmp/cp-$FS.log 2>&1
echo "rc=$?"
kill $sampler 2>/dev/null
sudo pkill -f cp-console.sh
cp /tmp/cp-$FS.log "/tmp/cp-$FS-s${SMALL:-512}-a${AGE:-120}.log"
grep -E "transactions:|journal peak [0-9]|RESULT" /tmp/cp-$FS.log
# run phase: pg-torn zeroed every counter and the ring at its start
sed -n '/^-- all counters, run --/,$p' /tmp/cp-$FS.log |
	grep -E "^  (cpw_[a-z]+|cpt_[a-z]+|cp_rewritten|jh_live_max|flush_submit|jwrite_blocks|jwrite_desc|revoke_taken|commits|space_wait|space_wait_ms|cpq_[a-z]+|cmq_[a-z]+|commit_busy|cp_runs|shrink_scan|shrink_asked|cpdrop_cpdone|cpdrop_infer|wr_slowpath|wr_fastpath|rejournal_gate|tx_dropped|seg_total) "
echo "journal heads alive (every 15 s, load and run):" $(cat /tmp/cp-jh.txt)
echo "journal used (MB, every 15 s):" \
	$(sudo dmesg | grep -a 'Used journal' | sed -n 's/.*Used journal \([0-9]*\)MB.*/\1/p')
# leave the defaults for whoever runs next in this boot
echo 512 | sudo tee $P/tau_cp_small_tx >/dev/null
echo 1 | sudo tee $P/tau_commit_workers >/dev/null
echo 120 | sudo tee $P/tau_max_transaction_age >/dev/null
