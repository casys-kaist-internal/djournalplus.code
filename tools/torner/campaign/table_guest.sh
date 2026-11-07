#!/bin/bash
# In the Torner VM (campaign/table.sh starts it): the cells of the atomicity
# table, paper §6.2.  For each CELL "config:row" and each PROFILE: capture
# `torner gen` under dm-log-writes, explore the capture with the row's
# strategies, and add one line to table.csv (cell_csv.py).
#
#   CELLS     "ext4:ow16k tau-xfs:ap2k ..."      rows: see row_args below
#   PROFILES  "quiet busy"    busy = commits and writeback from outside the write
#   LIMIT_ATOM, LIMIT_EPOCH   states per strategy (atom-*, prefix/single-drop)
#   PREFER_SPLIT=1   atom-* spend the budget on split writes first (witnesses)
#   CAP_PARAM        "name=value[,name=value]": tau module parameters for each
#                    capture only, back to 0 after -- a control that must still fail
#   EXPLORE_PARAM    the same while the capture's states are explored: a switch
#                    on the recovery side, which runs when a state is mounted
#   TAU_SEG          tau journal segment size [2m], small so segments get reused
#                    (as torner ran from #349); MKFS_OPTS overrides the option
#   GEN_EXTRA        more `torner gen` arguments for every capture: --fdatasync
#                    (an overwrite's record then takes its own flush, no host commit)
#   TAG              suffix of the capture names
#   CAPTURE_NOSYNC   [1] unmount with no sync before it; 0 syncs first (before 11-08)
#   TORNER_EXT4_LAZYINIT  [0] every ext4 made with lazy init off; 1 on (before 11-08)
#   CAP_RESERVE_MB   guest memory held back as 2 MiB hugepages during each capture
#                    only (given back before explore): the capture then runs short
#                    of memory, so reclaim runs and asks the tau shrinker
# A tau capture also leaves tau-probe.txt: its run's probe counters, i.e. how often
# a reuse found its segment's free not yet on the map log, and how often a writer
# waited for journal space.  They show whether the cell reached those paths at all.
# tau-probe-samples.txt has them every 0.2 s, with whether torner gen was running:
# gen fills the file before its timed run, and explore crashes only inside that
# run, so cell_csv.py counts the run's own reuses from the samples.
# capture.json says how often reclaim asked the tau shrinker while gen ran: calls
# of its count and scan callbacks (shrink_count, shrink_scan), from the function
# profiler. Reclaim scans a shrinker in proportion to 1/seeks (tau_shrink_seeks),
# and every scan kicks a checkpoint.
# Ends with "===== done".
set -u
T=~/torner; S=$T/scripts; C=$T/campaign; W=/mnt/scratch; P=/sys/module/tau_journal/parameters
CELLS=${CELLS:?}; PROFILES=${PROFILES:-"quiet busy"}
LIMIT_ATOM=${LIMIT_ATOM:-1000}; LIMIT_EPOCH=${LIMIT_EPOCH:-1000}
PREFER_SPLIT=${PREFER_SPLIT:-0}; CAP_PARAM=${CAP_PARAM:-}; EXPLORE_PARAM=${EXPLORE_PARAM:-}
STRATS=${STRATS:-row}
TAU_SEG=${TAU_SEG:-2m}; GEN_EXTRA=${GEN_EXTRA:-}; TAG=${TAG:-}
CAPTURE_NOSYNC=${CAPTURE_NOSYNC:-1}; TORNER_EXT4_LAZYINIT=${TORNER_EXT4_LAZYINIT:-0}
CAP_RESERVE_MB=${CAP_RESERVE_MB:-0}
SYS=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MK=/mnt/scratch/stock/etc/mke2fs.conf
CSV=$W/table.csv

# One writer, an fsync after every write (one write = one table entry), 5 s;
# a row's own --threads/--fsync-every come later and win.
row_args() {
	case "$1" in
	ow4k)     echo "--mode overwrite --unit 4096" ;;	# a block rewritten in place
	ow16k)    echo "--mode overwrite --unit 16384" ;;
	ap2k)     echo "--mode append --unit 2048" ;;	# alternately starts a block / lands in one
	ap4k)     echo "--mode append --unit 4096" ;;
	ap16k)    echo "--mode append --unit 16384" ;;
	prealloc) echo "--mode alloc --unit 16384" ;;	# into fallocate()d space, once each
	hole)     echo "--mode delalloc --unit 16384" ;;	# into an ftruncate()d hole, once each
	# Journal pressure (kernel e6f2cdb2, 11-06): a 375 MiB file on a 512 MiB FS, so the
	# journal cannot grow past its first 8 segments of 2 MiB. A freed segment is then
	# often wanted again before journald logs its free, and tau_flush_freed writes the
	# free on the spot. The 11-06 pilot (tau-xfs, inside the 5 s run): ~16% of reuses
	# did so in every row, ow16k included (its journal stayed at 8 segments too), so
	# what -t4 adds is volume: ~160 reuses, ~26 frees on the spot (ow16k ~45, ~7).
	# A state also replays the 375 MiB prefill: ~3x the time of an ow16k state.
	# Variants: -f16 fsyncs every 16 writes, -t4 runs 4 writers on the file.
	owfull)     echo "--mode overwrite --unit 16384 --dev-size 512M --log-size 3G --pages 24000" ;;
	owfull-f16) echo "--mode overwrite --unit 16384 --dev-size 512M --log-size 3G --pages 24000 --fsync-every 16" ;;
	owfull-t4)  echo "--mode overwrite --unit 16384 --dev-size 512M --log-size 3G --pages 24000 --threads 4 --fsync-every 16" ;;
	*) return 1 ;;
	esac
}
row_gen() { case "$1" in ap2k) echo "--sector 512" ;; esac; }
# busy: another file's fsync commits the shared journal, sync() and writeback of
# the target land in the middle of a write -- what tears data=journal (2026-09-23)
profile_gen() {
	case "$1" in
	quiet) ;;
	busy)  echo "--other-fsync-ms 5 --sync-ms 50 --writeback-ms 5" ;;
	*) return 1 ;;
	esac
}
# the epoch strategies reach crash points before a write's data, where an append's
# size can already be on disk; the atom-* ones start at the data
# STRATS: "row" (the row's own, below), "none" (capture only: loginv judges the
# log, nothing is crashed), or a list of strategies
strats_of() {
	case "$STRATS" in
	row)	row_strats "$1" ;;
	none)	;;
	*)	echo "$STRATS" ;;
	esac
}
row_strats() {
	case "$1" in
	ap*) echo "atom-order atom-reorder atom-tear prefix single-drop" ;;
	*)   echo "atom-order atom-reorder atom-tear prefix" ;;
	esac
}
# "a=1,b=8": each tau module parameter to its value, none if one is missing;
# prints "a=<old>,b=<old>", which puts them back (tau_maplog_len is not 0 by default)
setps() {
	local kv k old=
	for kv in ${1//,/ }; do
		k=${kv%%=*}; [ -e "$P/$k" ] || { echo "no tau parameter $k" >&2; return 1; }
		old="$old${old:+,}$k=$(cat "$P/$k")"
	done
	for kv in ${1//,/ }; do echo "${kv#*=}" | sudo tee "$P/${kv%%=*}" >/dev/null; done
	echo "$old"
}
# One capture's tau probe counters. They exist with CONFIG_TAU_PROBE_TORN and are
# absent elsewhere.
PROBES="seg_reused seg_reuse_flush space_wait space_wait_ms space_granted seg_idle_released seg_shrunk"
probes_zero() {
	local c
	for c in $PROBES; do [ -e $P/tau_probe_$c ] && echo 0 | sudo tee $P/tau_probe_$c >/dev/null; done
	return 0
}
probes_read() {
	local c
	for c in $PROBES; do [ -e $P/tau_probe_$c ] && printf '%s=%s ' $c "$(cat $P/tau_probe_$c)"; done
	return 0
}
# <file>: a line every 0.2 s until killed -- time, gen=1 while torner gen runs, the
# counters and the segment gauges
probes_sample() {
	local c l g
	while :; do
		g=0; pgrep -f '[t]orner gen' >/dev/null && g=1
		l="$(date +%s.%N | cut -c1-14) gen=$g"
		for c in $PROBES seg_total seg_free seg_owned; do
			[ -e $P/tau_probe_$c ] && l="$l $c=$(cat $P/tau_probe_$c)"
		done
		echo "$l"
		sleep 0.2
	done > "$1"
}

echo "===== start $(uname -r) $(uname -v)  $(date +%T)"
echo "cmdline: $(cat /proc/cmdline)  tau_shrink_seeks: $(cat $P/tau_shrink_seeks 2>/dev/null || echo -)"
echo "captures: unmount $([ "$CAPTURE_NOSYNC" = 1 ] && echo "with no sync" || echo "after a sync")," \
	"ext4 lazy init $([ "$TORNER_EXT4_LAZYINIT" = 1 ] && echo on || echo off)$([ "$CAP_RESERVE_MB" -gt 0 ] &&
	echo ", $CAP_RESERVE_MB MiB held back while gen runs")"
[ -s $CSV ] || python3 $C/cell_csv.py --header > $CSV
for cell in $CELLS; do
	fs=${cell%%:*} row=${cell#*:}
	args=$(row_args $row) || { echo "unknown row $row"; continue; }
	# tau configs need the forks; the others get the stock e2fsprogs/xfsprogs
# (table.sh copies them from bench/workspace/stock, what the performance
# baselines are formatted with)
	case $fs in
	tau-ext4) path=/mnt/scratch/bin:$SYS; mkfs=${MKFS_OPTS:--E tau_segsize=$TAU_SEG} ;;
	tau-xfs)  path=/mnt/scratch/bin:$SYS; mkfs=${MKFS_OPTS:--l tjsegsize=$TAU_SEG} ;;
	*)        path=/mnt/scratch/stock/bin:$SYS; mkfs="" ;;
	esac
	for prof in $PROFILES; do
		gen="$(row_gen $row) $(profile_gen $prof)${GEN_EXTRA:+ $GEN_EXTRA}" ||
			{ echo "unknown profile $prof"; continue; }
		name=$fs-$row-$prof${TAG:+-$TAG}; D=$W/cap-$name
		sudo rm -rf $D
		echo "===== $name capture $(date +%T)${CAP_PARAM:+  $CAP_PARAM}${EXPLORE_PARAM:+  explore $EXPLORE_PARAM}${GEN_EXTRA:+  gen $GEN_EXTRA}$([ "$CAP_RESERVE_MB" -gt 0 ] && echo "  reserve ${CAP_RESERVE_MB} MiB")"
		undo=
		if [ -n "$CAP_PARAM" ]; then
			undo=$(setps "$CAP_PARAM") || { echo "cell skipped"; continue; }
		fi
		spid=
		case $fs in tau-*) probes_zero; probes_sample $W/$name-probe-samples.txt & spid=$! ;; esac
		sudo env PATH=$path MKE2FS_CONFIG=$MK TORNER_TAU_MKFS_OPTS="$mkfs" \
			CAPTURE_NOSYNC=$CAPTURE_NOSYNC TORNER_EXT4_LAZYINIT=$TORNER_EXT4_LAZYINIT \
			TORNER_RESERVE_MB=$CAP_RESERVE_MB $S/capture.sh --workdir $D \
			--fs $fs --threads 1 --fsync-every 1 $args --gen-args "$gen" \
			> $W/$name-capture.log 2>&1
		rc=$?
		[ -z "$spid" ] || { kill $spid; wait $spid 2>/dev/null; }
		case $fs in
		tau-*)	pr=$(probes_read); echo "probe: $pr"
			if [ -d $D ]; then
				echo "$pr" | sudo tee $D/tau-probe.txt >/dev/null
				sudo mv $W/$name-probe-samples.txt $D/tau-probe-samples.txt
			fi ;;
		esac
		[ -z "$undo" ] || setps "$undo" >/dev/null
		echo "capture rc=$rc  $(grep -m1 -oE 'mkfs.ext4=[^ ]*|mkfs.xfs=[^ ]*' $D/capture.json 2>/dev/null)"
		grep -E "application writes|tau shrinker during gen|holding back" $W/$name-capture.log
		[ $rc = 0 ] || continue
		# what the cell is, for cell_csv.py run again later on the host
		printf '{"row":"%s","profile":"%s","tag":"%s","cap_param":"%s","explore_param":"%s","gen_extra":"%s"}\n' \
			"$row" "$prof" "$TAG" "$CAP_PARAM" "$EXPLORE_PARAM" "$GEN_EXTRA" | sudo tee $D/cell.json >/dev/null
		undo=
		if [ -n "$EXPLORE_PARAM" ]; then
			undo=$(setps "$EXPLORE_PARAM") || { echo "cell skipped"; continue; }
		fi
		for st in $(strats_of $row); do
			case $st in
			atom-*) lim=$LIMIT_ATOM; extra=""; [ "$PREFER_SPLIT" = 1 ] && extra=--prefer-split ;;
			*)      lim=$LIMIT_EPOCH; extra="" ;;
			esac
			echo "--- explore $st $(date +%T)"
			sudo dmesg -C
			sudo dmesg -w > $W/$name-$st.dmesg & dpid=$!
			sudo env PATH=$path $S/explore.sh --capture $D --strategy $st --limit $lim \
				--jobs 8 $extra > $W/$name-$st.log 2>&1
			echo "explore rc=$?"; tail -2 $W/$name-$st.log
			sleep 1; sudo kill $dpid
			echo "dmesg: faults=$(grep -c -E 'WARNING|BUG|Oops|Call Trace' $W/$name-$st.dmesg)"
		done
		[ -z "$undo" ] || setps "$undo" >/dev/null
		sudo python3 $C/cell_csv.py $D >> $CSV
		tail -1 $CSV | cut -c1-200
	done
done
echo "===== done $(date +%T)"
