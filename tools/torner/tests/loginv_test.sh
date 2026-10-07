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

run() {  # run <kind>; sets OUT and RC
	python3 "$HERE/mklog.py" "$1" "$WORK/$1.log" || { bad "mklog $1"; return 1; }
	OUT="$("$TORNER" loginv --log "$WORK/$1.log" --config tau-ext4 --check I1 2>&1)"
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

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
