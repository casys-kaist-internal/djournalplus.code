#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Tests for `torner loginv` against synthetic dm-log-writes logs built by
# mklog.py.  Each case pins one behaviour that is easy to regress into a
# silently-passing checker.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

run() {  # run <kind> [config] [extra loginv args]; sets OUT and RC
	local kind="$1" cfg="${2:-tau-ext4}"
	shift; [ $# -gt 0 ] && shift
	python3 "$HERE/mklog.py" "$kind" "$WORK/$kind.log" || { bad "mklog $kind"; return 1; }
	OUT="$("$TORNER" loginv --log "$WORK/$kind.log" --config "$cfg" --check I1 "$@" 2>&1)"
	RC=$?
	return 0
}

want_rc()   { [ "$RC" = "$1" ] && ok "$2" || { bad "$2 (exit $RC, wanted $1)"; echo "        $OUT"; }; }
want_has()  { printf '%s' "$OUT" | grep -q -- "$1" && ok "$2" || { bad "$2 -- missing $1"; echo "        $OUT"; }; }
want_not()  { printf '%s' "$OUT" | grep -q -- "$1" && { bad "$2 -- unexpected $1"; echo "        $OUT"; } || ok "$2"; }

[ -x "$TORNER" ] || { echo "torner not built at $TORNER (run make)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
echo "torner loginv tests"

# The synthetic log carries a tau superblock and segment map, because without
# them no block in the stream can be attributed to tau and the checker refuses
# the log outright -- see the geometry case at the end.

# A correctly ordered transaction: data, flush, then the commit block.
run good
want_rc 0 "well-ordered log passes I1"
want_has '"i1_transactions_checked":1' "  ...and the transaction was actually examined"
want_has '"usable":true' "  ...log reported usable"

# The transaction's commit shares an epoch with its own data.  This is the
# failure I1 exists to catch, and it is the one probabilistic replay misses.
run no-barrier
want_rc 2 "commit sharing an epoch with its data trips I1"
want_has '"invariant":"I1"' "  ...reported as I1"
want_has '"commit_epoch":1' "  ...with the commit epoch"
want_has '"data_epoch":1' "  ...and the data epoch it failed to beat"
want_has '"blocks_in_transaction":3' "  ...over the whole transaction extent"

# The data is never flushed: an unrelated FUA write falls between it and a
# commit issued FUA without a preflush.  FUA makes only itself durable, so the
# commit can reach media while the data sits in the cache.  An epoch model that
# also splits on FUA -- CrashMonkey's -- puts the commit in a later epoch and
# calls this ordered.
run fua-not-flush
want_rc 2 "a FUA write between data and commit is not a barrier"
want_has '"invariant":"I1"' "  ...reported as I1"
want_has '"epoch_model":"flush"' "  ...judged on FLUSH epochs"
want_has '"commit_epoch":1' "  ...commit still in the data's flush epoch"

# A write-through backing device gets REQ_PREFLUSH/REQ_FUA stripped before
# dm-log-writes sees them.  The log then has one epoch and every ordering
# check is vacuous.  Reporting "clean" here would be the worst outcome.
run no-flags
want_rc 1 "flagless log is refused, not passed"
want_has '"usable":false' "  ...reported as unusable"
want_not '"I1":"run"' "  ...and no invariant claims to have run"

# Since kernel #376 a record usually goes without a flush of its own and names
# a host commit instead (h_epoch): recovery counts it only once that commit is
# on disk, and the host commit goes out behind a flush.  Gated I1 judges the
# record as recovery does.
run gated-ok
want_rc 0 "a flush-less record whose host commit flushes its data passes"
want_has '"i1_ordered_by_host_commit":1' "  ...ordered by jbd2's commit, not its own flush"
want_has '"i1_strict_unordered":1' "  ...though the record alone is not ordered"
want_has '"host_commits":1' "  ...jbd2's commit block was found outside tau's segments"

run gated-ok tau-ext4 --i1-strict
want_rc 2 "--i1-strict judges on the record's own flush only"
want_has '"gate":"strict"' "  ...and says so"

run gated-late
want_rc 2 "a block logged after the host commit's flush trips gated I1"
want_has '"gate":"host"' "  ...reported against the host commit"
want_has '"data_lba":1002' "  ...naming the late block"
want_has '"blocks_unordered":1' "  ...and only that one"

run gate-closed
want_rc 0 "a record whose host commit never reaches the log cannot count"
want_has '"i1_gate_never_open":1' "  ...counted, not passed silently"

run xfs-gated-ok tau-xfs
want_rc 0 "tau-xfs: a record gated on an XFS log record passes"
want_has '"i1_ordered_by_host_commit":1' "  ...found by LSN at a 512-byte boundary"

# The record_fua_only control: the record goes FUA without a preflush, so
# dm-log-writes logs it before the descriptor and data it vouches for.  The
# first version of I1 looked for them only before the commit, skipped such
# transactions, and passed the control whose crash states fail.
run fua-first
want_rc 2 "a FUA record logged ahead of its own data trips I1"
want_has '"gate":"none"' "  ...with nothing gating it"
want_has '"blocks_unordered":3' "  ...descriptor and both data blocks"
want_has '"i1_blocks_ambiguous":0' "  ...the previous owner's write, before the FREE, is not taken"

# Without the map log FREE the previous owner's write of 1001 is in the same
# ownership as this transaction's: it is counted as ambiguous, and the
# transaction is still caught by the other two blocks.
run fua-first-nofree
want_rc 2 "without the FREE the transaction is still caught"
want_has '"i1_blocks_ambiguous":1' "  ...and the doubled block is counted as ambiguous"

# A block tagged HOME is written straight home and takes no journal block; it
# has to be durable before the record like the journal copies.
run home-ok
want_rc 0 "a HOME block written before the record's flush passes"
want_has '"i1_home_blocks":1' "  ...and was examined"

run home-late
want_rc 2 "a HOME block logged after the record trips I1"
want_has '"data_home":1' "  ...reported as the HOME block"
want_has '"data_lba":7000' "  ...at its home address"

# A record that entered a new segment names its claims on the segment map log
# (h_maplog, by h_seq); they count only if the record does, so they must be
# durable before it can.
run claim-ok
want_rc 0 "a claim block flushed before the record passes"
want_has '"i1_claim_blocks":1' "  ...and was examined"
run claim-late
want_rc 2 "a claim block logged after the record trips I1"
want_has '"data_lba":9200' "  ...naming the claim block"

# I2: a record whose tail passes tx T ends T's replay, so every home block T
# journaled must then be durable at home, or held by a later transaction the
# tail has not passed (the handoff).
run i2-ok tau-ext4 --check I1,I2
want_rc 0 "I2: the tail passes a tx whose home block was flushed first"
want_has '"i2_covered_home":1' "  ...covered by its home write"
run i2-uncovered tau-ext4 --check I1,I2
want_rc 2 "I2: the tail passes a tx whose home block is not durable"
want_has '"invariant":"I2"' "  ...reported as I2"
want_has '"pblk":5000' "  ...naming the block"
run i2-handoff tau-ext4 --check I1,I2
want_rc 0 "I2: a later tx inside the tail holds the block (handoff)"
want_has '"i2_covered_handoff":1' "  ...counted as a handoff"
run tailblk-bad tau-ext4 --check I1,I2
want_rc 2 "h_tail_blk must name the first block of the tail transaction"
want_has '"invariant":"tail_blk"' "  ...reported as tail_blk"

# I3: a scoped revoke tag stands in for in-place data: that home write first,
# then the record carrying the tag.
run i3-ok tau-ext4 --check I1,I3
want_rc 0 "I3: the in-place write is durable before the tag's record"
want_has '"i3_covered_home":1' "  ...and was checked"
run i3-late tau-ext4 --check I1,I3
want_rc 2 "I3: the in-place write lands after the tag's record"
want_has '"invariant":"I3"' "  ...reported as I3"

# I4: the map log.  A snapshot's map blocks before the superblock moves the
# base; a claimed segment reused only after a FREE naming it.
run i4-base-ok tau-ext4 --check I1,I4
want_rc 0 "I4: map blocks, then the base"
want_has '"i4_base_moves":1' "  ...one base move checked"
run i4-base-early tau-ext4 --check I1,I4
want_rc 2 "I4: the base moved before the map blocks"
want_has '"invariant":"I4"' "  ...reported as I4"
run i4-reuse-ok tau-ext4 --check I1,I4
want_rc 0 "I4: a claimed segment reused after its FREE"
want_has '"i4_segment_reuses":3' "  ...its descriptor, data and commit blocks reused"
run i4-reuse-nofree tau-ext4 --check I1,I4
want_rc 2 "I4: a claimed segment reused with no FREE on the log"
want_has '"claim_seq":1' "  ...naming the claim"

# I5: an application write contained in one durable unit.  ext4 data=journal
# journals page by page, so a commit can close a jbd2 transaction with half
# of a 16 KiB write in it; the tags of jbd2's descriptors say which blocks a
# transaction holds.  The features come from the mount's superblock write, not
# mke2fs's (which has none, and would size every tag wrong).
run i5-jbd2-ok ext4-data --check I5
want_rc 0 "ext4-data: a write inside one jbd2 transaction passes I5"
want_has '"i5_writes_checked":1' "  ...and was checked"
run i5-jbd2-split ext4-data --check I5
want_rc 2 "ext4-data: a write split across two jbd2 transactions trips I5"
want_has '"kind":"split"' "  ...as a split"
want_has '"tid_first":1,"tid_last":2' "  ...naming both transactions"

run i5-tau-ok tau-ext4 --check I1,I5
want_rc 0 "tau: a write inside one tau transaction passes I5"
run i5-tau-split tau-ext4 --check I1,I5
want_rc 2 "tau: a write split across two tau transactions trips I5"
want_has '"invariant":"I5"' "  ...reported as I5"
want_has '"sequence_first":42,"sequence_last":43' "  ...naming both transactions"
want_has '"i1_violations":0' "  ...while both transactions pass I1"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
