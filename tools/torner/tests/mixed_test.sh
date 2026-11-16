#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Self-test for the mixed-mode oracle (`torner check --mixed`) and the several-
# writer append rule (`--append-writers`).  As in selftest.sh, every case damages
# a clean file in one specific way and asserts check reports *that* violation --
# and the cases that are legal under "every write whole" must stay clean: a
# write lost as a whole is a durability matter (P2), not a tear.
#
# Runs on a normal file system; no devices, no VM, no root.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
WORK="${WORK:-$(mktemp -d)}"
KEEP="${KEEP:-0}"
RUN_ID=515151
UNIT=16384
SEC=4096

pass=0; fail=0
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# chk <want rc> <desc> <check args...>: runs check, keeps the output in OUT
chk() {
	local want="$1" desc="$2" rc; shift 2
	OUT="$("$TORNER" check --run-id "$RUN_ID" "$@" 2>&1)"; rc=$?
	if [ "$rc" = "$want" ]; then ok "$desc"; else bad "$desc (exit $rc, wanted $want)"; printf '        %s\n' "$OUT"; fi
}
# has <json fragment> <desc>: OUT contains it
has() {
	if printf '%s' "$OUT" | grep -qF -- "$1"; then ok "  ...$2"; else bad "  ...$2 -- no $1"; printf '        %s\n' "$OUT"; fi
}
# hasnt <json fragment> <desc>
hasnt() {
	if printf '%s' "$OUT" | grep -qF -- "$1"; then bad "  ...$2 -- found $1"; printf '        %s\n' "$OUT"; else ok "  ...$2"; fi
}
tear() { "$TORNER" tear "$@" >/dev/null || bad "tear $*"; }

[ -x "$TORNER" ] || { echo "torner not built at $TORNER (run make)"; exit 1; }
echo "torner mixed/append-writers test  (work=$WORK)"

# ------------------------------------------------------------------ chain
# 50 writes of 16 KiB, 8 KiB apart, 3 writers sharing the chain: the file ends
# at end(49) = 49 * 8 KiB + 16 KiB.
C="$WORK/chain.dat"; CP="$WORK/chain.prog"
"$TORNER" gen --file "$C" --progress-log "$CP" --run-id "$RUN_ID" --mode mixed \
	--threads 3 --pages 50 --duration 0 --fsync-every 1 --quiet || bad "gen chain"
[ "$(stat -c %s "$C")" = $((49 * 8192 + UNIT)) ] && ok "chain: 50 writes end at end(49)" ||
	bad "chain: size $(stat -c %s "$C")"
cp "$C" "$WORK/chain.pristine"
M=(--mixed chain --file "$C")

chk 0 "chain: a clean run passes P1, size, P2" "${M[@]}" --progress-log "$CP"
has '"eof_write":49,"eof_exact":true' "EOF names write 49"
has '"new":50,' "every write new"
has '"after_eof":1' "write 50, never written, counted past EOF"

# a sub-half tear: the first sector of write 20 is what write 19 left there
cp "$WORK/chain.pristine" "$C"
tear --file "$C" --mixed chain --write 20 --sectors 1 --kind older
chk 2 "chain: one sector of write 20 rolled back is torn" "${M[@]}"
has '"kind":"p1_mixed_torn_older","page_id":20' "p1_mixed_torn_older at write 20"
has '"size":"pass"' "not a size violation"

# write 20 lost whole: its first half is write 19's, its second half write 21's.
# Every write whole explains it (write 20 not applied) -- no tear; P2 sees the loss.
cp "$WORK/chain.pristine" "$C"
tear --file "$C" --mixed chain --write 20 --sectors 2 --kind older
chk 2 "chain: write 20 lost whole is not a tear, but P2 fails" "${M[@]}" --progress-log "$CP"
has '"p1":"pass"' "P1 passes"
has '"detail":"rolled_back"' "P2: write 20 rolled back"
has '"order_gaps":1' "counted as an order gap"
chk 0 "  ...and without the progress log the state is legal" "${M[@]}"

# the EOF write's data is missing where it moved EOF: the size reached the disk
cp "$WORK/chain.pristine" "$C"
tear --file "$C" --mixed chain --write 49 --sectors 2 --from-end --kind blank
chk 2 "chain: EOF write's extension blank is a size violation" "${M[@]}"
has '"kind":"p1_size_blank_unit","page_id":49' "p1_size_blank_unit at write 49"
has '"size":"fail"' "size fails"

# EOF inside the EOF write's extension: part of its size
cp "$WORK/chain.pristine" "$C"
tear --file "$C" --mixed chain --write 49 --sectors 1 --from-end --kind cut
chk 2 "chain: EOF cutting write 49's extension is a size violation" "${M[@]}"
has '"kind":"p1_size_cut_unit","page_id":49' "p1_size_cut_unit at write 49"

# write 49's extension gone entirely: EOF = end(48), and write 49's overwrite
# half shows 49 -- the in-place half landed, the append half did not
cp "$WORK/chain.pristine" "$C"
tear --file "$C" --mixed chain --write 49 --sectors 2 --from-end --kind cut
chk 2 "chain: write 49 over write 48 but its size lost is torn" "${M[@]}"
has '"kind":"p1_mixed_torn_eof","page_id":49' "p1_mixed_torn_eof at write 49"
has '"eof_write":48,"eof_exact":true' "EOF names write 48"
hasnt '"page_id":48' "write 48 is not blamed"

# the same with write 49's overwrite half rolled back too: write 49 lost whole,
# the file is write 48's end -- legal
tear --file "$C" --mixed chain --write 49 --sectors 2 --kind older
chk 0 "chain: write 49 lost whole (data and size) is legal" "${M[@]}"

# a damaged sector is charged once, to the newest write over it
cp "$WORK/chain.pristine" "$C"
tear --file "$C" --mixed chain --write 30 --sectors 1 --kind bitflip
chk 2 "chain: a bit flip is caught" "${M[@]}"
has '"kind":"p1_sector_corrupt","page_id":30' "p1_sector_corrupt at write 30"
hasnt '"page_id":29' "write 29 (also over that sector) is not blamed"

# a focus file judges the targeted writes one by one
cp "$WORK/chain.pristine" "$C"
tear --file "$C" --mixed chain --write 20 --sectors 1 --kind older
printf '20 1\n21 1\n60 1\n' > "$WORK/focus"
chk 2 "chain: focus targets" "${M[@]}" --focus-file "$WORK/focus"
has '"torn":[{"page":20,"version":1,"kind":"mixed_torn_older"}],"new":1,"old":0,"absent":1' \
	"write 20 torn, 21 new, 60 absent"

# P2 past EOF: the file cut back to end(40)
cp "$WORK/chain.pristine" "$C"
truncate -s $((40 * 8192 + UNIT)) "$C"
chk 2 "chain: durable writes past EOF fail P2" "${M[@]}" --progress-log "$CP"
has '"detail":"beyond_eof"' "p2 beyond_eof"

# --mixed-step: 4 KiB apart, each sector under four writes
S="$WORK/step.dat"
"$TORNER" gen --file "$S" --run-id "$RUN_ID" --mode mixed --mixed-step 4096 \
	--threads 2 --pages 40 --duration 0 --fsync-every 0 --quiet 2>/dev/null || bad "gen step"
cp "$S" "$WORK/step.pristine"
chk 0 "chain 4 KiB step: a clean run passes" --mixed chain --mixed-step 4096 --file "$S"
# write 10 shows itself in one sector only (11, 12, 13 are over the rest), so that
# sector rolled back is write 10 lost whole -- legal.  The last write shows all four.
tear --file "$S" --mixed chain --mixed-step 4096 --write 10 --sectors 1 --kind older
chk 0 "chain 4 KiB step: write 10's one visible sector rolled back is write 10 lost" \
	--mixed chain --mixed-step 4096 --file "$S"
tear --file "$S" --mixed chain --mixed-step 4096 --write 39 --sectors 1 --kind older
chk 2 "chain 4 KiB step: the last write with one sector rolled back is torn" \
	--mixed chain --mixed-step 4096 --file "$S"
has '"kind":"p1_mixed_torn_older","page_id":39' "p1_mixed_torn_older at write 39"
chk 2 "the wrong step finds no write the sectors belong to (the layout matters)" \
	--mixed chain --file "$WORK/step.pristine"
has '"detail":"bad_index"' "sectors reported as not their writes'"

# ---------------------------------------------------------------- aligned
# 21 writes: A0 M0 A1 M1 ... A10 (A: 8 KiB append at 16 KiB j; M: 16 KiB at 16 KiB j)
A="$WORK/al.dat"; AP="$WORK/al.prog"
"$TORNER" gen --file "$A" --progress-log "$AP" --run-id "$RUN_ID" --mode mixed \
	--mixed aligned --threads 2 --pages 21 --duration 0 --fsync-every 1 --quiet || bad "gen aligned"
[ "$(stat -c %s "$A")" = $((10 * UNIT + 8192)) ] && ok "aligned: 21 writes end at A10" ||
	bad "aligned: size $(stat -c %s "$A")"
cp "$A" "$WORK/al.pristine"
MA=(--mixed aligned --file "$A")
chk 0 "aligned: a clean run passes P1, size, P2" "${MA[@]}" --progress-log "$AP"
has '"eof_write":20,"eof_exact":true' "EOF names write 20 (A10)"

# M5 (write 11): its append half blank, its overwrite half new
tear --file "$A" --mixed aligned --write 11 --sectors 2 --from-end --kind blank
chk 2 "aligned: M5 with its append half blank is torn" "${MA[@]}"
has '"kind":"p1_mixed_torn_blank","page_id":11' "p1_mixed_torn_blank at write 11"

# M5's overwrite half is what A5 wrote: torn the other way
cp "$WORK/al.pristine" "$A"
tear --file "$A" --mixed aligned --write 11 --sectors 2 --kind older
chk 2 "aligned: M5 with its overwrite half old is torn" "${MA[@]}"
has '"kind":"p1_mixed_torn_older","page_id":11' "p1_mixed_torn_older at write 11"
hasnt '"page_id":10' "A5 (write 10) is fine"

# EOF at end(M9): A10 never reached, fine; with its record, P2 fails
cp "$WORK/al.pristine" "$A"
truncate -s $((10 * UNIT)) "$A"
chk 0 "aligned: EOF at end(M9) is legal" "${MA[@]}"
has '"eof_write":19,"eof_exact":true' "EOF names write 19 (M9)"
chk 2 "  ...but A10's record says it was durable" "${MA[@]}" --progress-log "$AP"

# EOF inside A10's 8 KiB
cp "$WORK/al.pristine" "$A"
truncate -s $((10 * UNIT + 4096)) "$A"
chk 2 "aligned: EOF inside A10 is a size violation" "${MA[@]}"
has '"kind":"p1_size_cut_unit","page_id":20' "p1_size_cut_unit at write 20"

# ------------------------------------------------------- append, N writers
P="$WORK/ap.dat"; PP="$WORK/ap.prog"
"$TORNER" gen --file "$P" --progress-log "$PP" --run-id "$RUN_ID" --mode append \
	--threads 4 --pages 64 --duration 0 --fsync-every 1 --quiet || bad "gen append"
cp "$P" "$WORK/ap.pristine"
chk 0 "append x4: a clean run passes" --append --append-writers 4 --file "$P" --progress-log "$PP"

# a blank unit below EOF: one writer -> torn; four -> a hole, unless it is the last unit
tear --file "$P" --page 10 --sectors 4 --kind blank
chk 2 "append x1: a blank unit below EOF is a size violation" --append --file "$P"
has '"kind":"p1_size_blank_unit","page_id":10' "p1_size_blank_unit at 10"
chk 0 "append x4: a blank unit below EOF is a legal hole" --append --append-writers 4 --file "$P"
has '"holes_below_eof":1' "counted as a hole"
chk 2 "  ...and P2 still catches it, its write was fsync()ed" \
	--append --append-writers 4 --file "$P" --progress-log "$PP"
cp "$WORK/ap.pristine" "$P"
tear --file "$P" --page 63 --sectors 4 --kind blank
chk 2 "append x4: the last unit blank is a size violation" --append --append-writers 4 --file "$P"
has '"kind":"p1_size_blank_unit","page_id":63' "p1_size_blank_unit at 63"
printf '63 1\n10 1\n' > "$WORK/focus"
chk 2 "append x4: focus on the last unit" --append --append-writers 4 --file "$P" --focus-file "$WORK/focus"
has '"kind":"size_blank_unit"' "focus: size_blank_unit"
cp "$WORK/ap.pristine" "$P"
tear --file "$P" --page 63 --sectors 2 --kind cut
chk 2 "append x4: EOF inside the last unit is a size violation" --append --append-writers 4 --file "$P"
has '"kind":"p1_size_cut_unit"' "p1_size_cut_unit"

echo
echo "mixed test: $pass ok, $fail failed"
[ "$fail" = 0 ]
