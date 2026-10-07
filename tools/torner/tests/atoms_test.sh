#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Tests for `torner atoms` and the atom-* replay strategies.
#
# mklog.py atomslog builds a log in which every shape of application write is
# present once, with its entry indices written down in the generator's
# docstring.  Its device image doubles as the file (page p = blocks 4p..4p+3),
# so each planned state can be replayed and handed straight to `torner check`:
# the assertions are on what the image actually holds, not on the tools'
# accounting.  There is no file system here, hence no recovery -- a state that
# leaves part of a write on disk is expected to read back torn.  That is the
# point: it shows each plan aims at the right write, at the right cut.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
TOOL="$HERE/../scripts/state_tool.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/atoms.log"
RUN=777
PAGES=5
UNIT=16384

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
want_eq() { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got '$1', wanted '$2')"; }

jq_() { python3 -c "import json,sys; o=json.load(sys.stdin); print($1)"; }

[ -x "$TORNER" ] || { echo "torner not built at $TORNER (run make)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
echo "torner atoms tests"

# ---- the Python sector builder must match the C one ----------------------
python3 "$HERE/mklog.py" unit "$WORK/u.img"
"$TORNER" check --file "$WORK/u.img" --run-id $RUN >/dev/null 2>&1 \
	&& ok "a unit built by mklog.py passes the C oracle" \
	|| bad "mklog.py and src/common.c disagree on the sector format"

python3 "$HERE/mklog.py" atomslog "$LOG"

# ---- classification ------------------------------------------------------
A="$("$TORNER" atoms --log "$LOG" --run-id $RUN)"
want_eq "$(echo "$A" | jq_ 'o["writes"]["workload"]')" 4 "version-0 prefill is setup, not workload"
want_eq "$(echo "$A" | jq_ 'o["shape"]["one_bio"]')" 2 "one-bio writes found (in place, and via an embedded copy)"
want_eq "$(echo "$A" | jq_ 'o["shape"]["split_window"]')" 1 "write split within one flush window"
want_eq "$(echo "$A" | jq_ 'o["shape"]["split_flush"]')" 1 "write split across a FLUSH"
want_eq "$(echo "$A" | jq_ 'o["shape"]["reorderable"]')" 1 "  ...only the in-window split can be reordered"
want_eq "$(echo "$A" | jq_ 'o["shape"]["embedded_first_copy"]')" 1 "unaligned copy inside a record is found"
want_eq "$(echo "$A" | jq_ 'o["scan"]["rejected"]')" 1 "a copy with a flipped byte is rejected, not counted"
want_eq "$(echo "$A" | jq_ 'o["log"]["begin_mark"]')" 2 "torner:begin mark located"
want_eq "$(echo "$A" | jq_ 'o["shape"]["single_entry"]')" 1 \
	"one write is carried by a single entry, reachable only by tearing it"
want_eq "$(echo "$A" | jq_ '" ".join(sorted(o["signatures"]))')" \
	"one_bio/k1/n1/f0 one_bio/k1/n2/f0/emb split_flush/k2/n2/f1 split_window/k2/n2/f0/R" \
	"shape signatures, the fuzzer's coverage: class/pieces/entries/flushes/flags"

# ---- plans ----------------------------------------------------------------
plan() { "$TORNER" replay --log "$LOG" --enumerate --strategy "$1" --run-id $RUN 2>/dev/null; }

ORDER="$(plan atom-order)"
SPECS="$(echo "$ORDER" | python3 -c 'import json,sys; print(" ".join(json.loads(l)["state_spec"] for l in sys.stdin))')"
want_eq "$SPECS" "entry<=5 entry<=7 entry<=10 entry<=12 entry<=14 entry<=16" \
	"atom-order: between every two entries carrying a write, and the barriers after"

RE="$(plan atom-reorder)"
SPECS="$(echo "$RE" | python3 -c 'import json,sys; print(" ".join(json.loads(l)["state_spec"] for l in sys.stdin))')"
want_eq "$SPECS" "entry<=6,drop=[5]" \
	"atom-reorder: drop the earlier piece only where the cache could lose it"

TEAR="$(plan atom-tear)"
want_eq "$(echo "$TEAR" | wc -l)" 14 "atom-tear: every cut inside every write, every copy"
echo "$TEAR" | grep -q '"state_spec":"entry<=13,partial=\[13:8\]"' \
	&& ok "  ...including cuts through the unaligned embedded copy" \
	|| bad "  ...no cut through the embedded copy"
want_eq "$("$TORNER" replay --log "$LOG" --enumerate --strategy atom-tear --run-id $RUN \
	--first-copy-only 2>/dev/null | wc -l)" 11 \
	"  ...--first-copy-only drops p4's second (in-place) copy"

# The plan sizes `atoms` reports come from the planners themselves.
for strat in atom-order atom-reorder atom-tear; do
	want_eq "$(echo "$A" | jq_ "o['plans']['$strat']['states']")" "$(plan "$strat" | wc -l)" \
		"atoms plans.$strat.states is what replay enumerates"
done

# A budget samples whole writes, never a subset of one write's states: the
# denominator is then "writes torn / writes tried".
for strat in atom-order atom-tear; do
	plan "$strat" > "$WORK/full"
	"$TORNER" replay --log "$LOG" --enumerate --strategy "$strat" --run-id $RUN \
		--max-states 1 > "$WORK/one" 2>/dev/null
	R="$(python3 - "$WORK/full" "$WORK/one" <<'EOF'
import json, sys
full = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
one = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
chosen = {tuple(t) for s in one for t in s["targets"]}
want = {s["state_spec"] for s in full if chosen & {tuple(t) for t in s["targets"]}}
got = {s["state_spec"] for s in one}
print("ok %d states of %s" % (len(got), sorted(chosen)) if len(chosen) == 1 and got == want
      else "bad: chose %s, got %s, want %s" % (sorted(chosen), sorted(got), sorted(want)))
EOF
)"
	case "$R" in
	ok*) ok "  ...$strat --max-states 1 tries one write at all its states ($R)" ;;
	*)   bad "  ...$strat --max-states 1 split a write: $R" ;;
	esac
done

# --signatures keeps only the writes of the listed shapes; an empty list
# selects nothing rather than everything.
printf 'split_flush/k2/n2/f1\n' > "$WORK/sig"
want_eq "$("$TORNER" replay --log "$LOG" --enumerate --strategy atom-tear --run-id $RUN \
	--signatures "$WORK/sig" 2>/dev/null | grep -c '"targets":\[\[3,1\]\]')" 2 \
	"--signatures aims only at writes of the listed shapes"
: > "$WORK/nosig"
want_eq "$("$TORNER" replay --log "$LOG" --enumerate --strategy atom-tear --run-id $RUN \
	--signatures "$WORK/nosig" 2>/dev/null | wc -l)" 0 "  ...and an empty list selects nothing"

# --prefer-split spends the budget on the shape most likely to tear first.
want_eq "$("$TORNER" replay --log "$LOG" --enumerate --strategy atom-order --run-id $RUN \
	--max-states 1 --prefer-split 2>/dev/null | python3 -c '
import json, sys
print(" ".join(sorted({"%s:%s" % (t, s) for l in sys.stdin
      for t, s in zip(map(tuple, json.loads(l)["targets"]), json.loads(l)["shapes"])})))')" \
	"(3, 1):split_flush" "--prefer-split takes the write split across a FLUSH first"

# ---- progress bound follows the crash point, not the legacy epoch ----------
# Regression: an entry<=N state used to report the watermark of the whole log,
# which makes every write past the cut read as a lost durable write.
truncate -s 0 "$WORK/p.img"; truncate -s 524288 "$WORK/p.img"
PL5="$("$TORNER" replay --log "$LOG" --target "$WORK/p.img" --state-spec 'entry<=5' | jq_ 'o["progress_limit"]')"
PL9="$("$TORNER" replay --log "$LOG" --target "$WORK/p.img" --state-spec 'entry<=9' | jq_ 'o["progress_limit"]')"
want_eq "$PL5" 0 "entry<=5 lies before the progress mark: bound 0"
want_eq "$PL9" 7 "entry<=9 lies after it: bound 7"

# ---- end to end: replay each planned state, judge its targets ---------------
# verdicts <plan output>  ->  one "spec verdict" line per targeted write
verdicts() {
	local line spec
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		spec="$(echo "$line" | jq_ 'o["state_spec"]')"
		rm -f "$WORK/s.img"; truncate -s 524288 "$WORK/s.img"
		"$TORNER" replay --log "$LOG" --target "$WORK/s.img" --state-spec "$spec" >/dev/null || { echo "$spec replay-failed"; continue; }
		truncate -s $((PAGES * UNIT)) "$WORK/s.img"	# keep only the file's pages
		echo "$line" | python3 "$TOOL" focus > "$WORK/focus"
		echo "$line" > "$WORK/state"
		"$TORNER" check --file "$WORK/s.img" --run-id $RUN --focus-file "$WORK/focus" \
			--config synth --workload torner:overwrite:t1 > "$WORK/check"
		python3 "$TOOL" merge --state-file "$WORK/state" --check-file "$WORK/check" \
			--p3 n/a --out "$WORK/states.jsonl"
		python3 -c '
import json,sys
o=json.loads(sys.stdin.read()); f=o["focus"]; spec=sys.argv[1]
for t in f["torn"]: print(spec, "torn")
for k in ("new","old","absent"):
    for _ in range(f[k]): print(spec, k)' "$spec" < "$WORK/check"
	done <<< "$1"
}
: > "$WORK/states.jsonl"

V="$(verdicts "$ORDER")"
want_eq "$(echo "$V" | tr '\n' ';')" \
	"entry<=5 torn;entry<=7 new;entry<=10 torn;entry<=12 new;entry<=14 absent;entry<=16 new;" \
	"atom-order: torn exactly at the cuts between pieces, whole once all have landed"
# entry<=14 is p4 in its log record only, not yet in place: absent here, where
# nothing replays the record -- on a file system, recovery's job.

V="$(verdicts "$RE")"
want_eq "$V" "entry<=6,drop=[5] torn" "atom-reorder: later piece without the earlier one is torn"

V="$(verdicts "$TEAR")"
want_eq "$(echo "$V" | grep -c ' torn$')" 10 "atom-tear: every in-place tear reads back torn"
want_eq "$(echo "$V" | grep -c ' absent$')" 4 \
	"  ...and tearing the embedded copy leaves the page absent: no recovery here to replay it"

# ---- the records explore.sh writes, and the table torner-report makes -------
# Per-write, not per-state: atom-tear has 14 states but aims at 4 writes, and a
# write counts as torn once, however many of its cuts tear it.
PW="$(python3 - "$HERE/../scripts" "$WORK/states.jsonl" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import report
w = report.per_write(report.load_states([sys.argv[2]]))
for (cfg, thr, strat), s in sorted(w.items()):
    print("%s:%d/%d" % (strat, len(s["torn"]), len(s["targeted"])), end=" ")
EOF
)"
want_eq "$PW" "atom-order:2/3 atom-reorder:1/1 atom-tear:4/4 " \
	"report: writes torn / writes targeted, per crash model"
grep -q '"targets_torn":\[\[3,1\]\]' "$WORK/states.jsonl" \
	&& ok "  ...merged records name the torn target" \
	|| bad "  ...no merged record carries targets_torn"

# ---- legality: nothing a FLUSH has made durable is ever dropped -------------
# p3's pieces are separated by a FLUSH, so no reorder state may drop its first
# piece (entry 9) -- that write is durable before its second piece is issued.
echo "$RE" | grep -q 'drop=\[9\]' && bad "a flushed write was dropped" \
	|| ok "no state drops a write that a FLUSH already made durable"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
