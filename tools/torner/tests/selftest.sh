#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Self-test for `torner check`.
#
# CRASH_TODO 3.7 makes the point for the log invariant checker, and it applies
# just as hard here: an oracle that has never been observed to fire cannot be
# told apart from one that is incapable of firing.  So every case below damages
# the file in a specific way and asserts that check reports *that* violation --
# not merely that it reports something.
#
# Runs entirely on a normal file system; no devices, no VM, no root.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
WORK="${WORK:-$(mktemp -d)}"
KEEP="${KEEP:-0}"

RUN_ID=424242
UNIT=16384
PAGES=64
THREADS=4

pass=0; fail=0

cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# expect_exit <want> <desc> -- runs check, compares exit code, stashes output
expect_exit() {
	local want="$1" desc="$2"; shift 2
	local out rc
	out="$("$@" 2>&1)"; rc=$?
	LAST_OUT="$out"
	if [ "$rc" = "$want" ]; then
		ok "$desc"
	else
		bad "$desc (exit $rc, wanted $want)"
		printf '        %s\n' "$out"
	fi
}

# expect_kind <substring> <desc>
expect_kind() {
	if printf '%s' "$LAST_OUT" | grep -q "\"kind\":\"$1\""; then
		ok "$2"
	else
		bad "$2 -- no \"$1\" in output"
		printf '        %s\n' "$LAST_OUT"
	fi
}

[ -x "$TORNER" ] || { echo "torner not built at $TORNER (run make)"; exit 1; }
echo "torner selftest  (work=$WORK)"

# ---------------------------------------------------------------- clean runs
for mode in overwrite append alloc delalloc mixed; do
	f="$WORK/$mode.dat"; pl="$WORK/$mode.prog"
	dur=0
	[ "$mode" = overwrite ] && dur=2
	[ "$mode" = mixed ] && dur=2

	"$TORNER" gen --file "$f" --progress-log "$pl" --run-id "$RUN_ID" \
		--pages "$PAGES" --threads "$THREADS" --mode "$mode" \
		--duration "$dur" --fsync-every 1 --quiet || { bad "gen $mode"; continue; }

	expect_exit 0 "clean run passes P1+P2  [$mode]" \
		"$TORNER" check --file "$f" --progress-log "$pl" --run-id "$RUN_ID"
done

# Interference changes how the writes reach the device, never what a clean
# run reads back.
f="$WORK/interfere.dat"; pl="$WORK/interfere.prog"
if "$TORNER" gen --file "$f" --progress-log "$pl" --run-id "$RUN_ID" \
	--pages "$PAGES" --threads "$THREADS" --mode overwrite --duration 1 \
	--fsync-every 1 --sync-ms 20 --other-fsync-ms 10 --writeback-ms 5 \
	--fdatasync --quiet; then
	expect_exit 0 "clean run passes P1+P2  [with interference]" \
		"$TORNER" check --file "$f" --progress-log "$pl" --run-id "$RUN_ID"
else
	bad "gen with interference"
fi

# ------------------------------------------------------------ damage cases
F="$WORK/overwrite.dat"; PL="$WORK/overwrite.prog"
cp "$F" "$WORK/pristine.dat"

# 1. one sector carries a newer version than its siblings -> torn unit
cp "$WORK/pristine.dat" "$F"
"$TORNER" tear --file "$F" --page 7 --sectors 1 --kind version >/dev/null
expect_exit 2 "version-mismatch tear is caught" \
	"$TORNER" check --file "$F" --run-id "$RUN_ID"
expect_kind "p1_version_mismatch" "  ...reported as p1_version_mismatch"

# 2. half the unit is still blank -> partial unit
cp "$WORK/pristine.dat" "$F"
"$TORNER" tear --file "$F" --page 9 --sectors 2 --kind blank >/dev/null
expect_exit 2 "partial-unit tear is caught" \
	"$TORNER" check --file "$F" --run-id "$RUN_ID"
expect_kind "p1_partial_unit" "  ...reported as p1_partial_unit"

# 3. a single flipped bit inside an otherwise valid sector -> crc
cp "$WORK/pristine.dat" "$F"
"$TORNER" tear --file "$F" --page 11 --sectors 1 --kind bitflip >/dev/null
expect_exit 2 "sub-sector bitflip is caught" \
	"$TORNER" check --file "$F" --run-id "$RUN_ID"
expect_kind "p1_sector_corrupt" "  ...reported as p1_sector_corrupt"

# 4. data the progress log says is durable has gone missing -> P2
cp "$WORK/pristine.dat" "$F"
truncate -s $((UNIT * PAGES / 2)) "$F"
expect_exit 2 "lost durable write is caught" \
	"$TORNER" check --file "$F" --progress-log "$PL" --run-id "$RUN_ID"
expect_kind "p2_lost_durable_write" "  ...reported as p2_lost_durable_write"

# 5. P1 alone must still pass on that truncated file: the surviving pages are
#    intact, and only the durability claim is broken.  Guards against the
#    oracle collapsing every fault into one verdict.
expect_exit 0 "truncation alone does not trip P1" \
	"$TORNER" check --file "$F" --run-id "$RUN_ID"

# 6. data from a previous run must not be mistaken for this one
cp "$WORK/pristine.dat" "$F"
expect_exit 2 "stale run_id is rejected" \
	"$TORNER" check --file "$F" --run-id 999999

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
