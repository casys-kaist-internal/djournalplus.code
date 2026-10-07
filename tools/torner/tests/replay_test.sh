#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Tests for `torner replay` against the synthetic data log from mklog.py.
#
# The log writes fs blocks 100..105 with bytes 0xA1..0xA6, two per epoch.  That
# makes every selection question answerable by reading one byte out of the
# replayed image, so these assertions check the actual bytes on the target
# rather than the tool's own accounting of what it did.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOG="$WORK/data.log"
FSBLK=4096
BASE_BYTE=00

pass=0; fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }

# first byte of fs block $2 in image $1
byte_at() {
	dd if="$1" bs=$FSBLK skip="$2" count=1 2>/dev/null | od -An -tx1 -N1 | tr -d ' \n'
}

fresh_target() {
	dd if=/dev/zero of="$1" bs=$FSBLK count=128 2>/dev/null
}

# replay_to <target> <spec>
replay_to() {
	"$TORNER" replay --log "$LOG" --target "$1" --state-spec "$2" >/dev/null
}

# want_block <image> <block> <hexbyte> <desc>
want_block() {
	local got; got="$(byte_at "$1" "$2")"
	if [ "$got" = "$3" ]; then ok "$4"; else bad "$4 (block $2 = 0x$got, wanted 0x$3)"; fi
}

[ -x "$TORNER" ] || { echo "torner not built at $TORNER (run make)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
python3 "$HERE/mklog.py" datalog "$LOG" || exit 1
echo "torner replay tests"

# ---- prefix selection --------------------------------------------------
T="$WORK/t1.img"; fresh_target "$T"
replay_to "$T" "epoch<=1"
want_block "$T" 100 a1 "epoch<=1 applies epoch 1"
want_block "$T" 101 a2 "  ...both of its entries"
want_block "$T" 102 $BASE_BYTE "  ...and stops there"
want_block "$T" 105 $BASE_BYTE "  ...leaving later epochs untouched"

T="$WORK/t2.img"; fresh_target "$T"
replay_to "$T" "epoch<=2"
want_block "$T" 103 a4 "epoch<=2 reaches epoch 2"
want_block "$T" 104 $BASE_BYTE "  ...and not epoch 3"

# ---- single-drop -------------------------------------------------------
# The state that matters for atomicity: everything durable except one write.
# Entry indices count marks too, so block 104's write is entry 6:
#   0 w100 | 1 mark 2 w101+F | 3 w102 | 4 mark 5 w103+F | 6 w104 | 7 mark 8 w105+F
T="$WORK/t3.img"; fresh_target "$T"
replay_to "$T" "epoch<=3,drop=[6]"
want_block "$T" 103 a4 "drop=[6] keeps earlier entries"
want_block "$T" 104 $BASE_BYTE "  ...drops exactly entry 6"
want_block "$T" 105 a6 "  ...and keeps the one after it"

# ---- the target is not wiped -------------------------------------------
# Replay lays entries on a copy of the base image; anything the log never
# touched has to survive, or every oracle would see a blank disk.
T="$WORK/t4.img"; fresh_target "$T"
printf '\xEE' | dd of="$T" bs=$FSBLK seek=120 conv=notrunc 2>/dev/null
replay_to "$T" "epoch<=3"
want_block "$T" 120 ee "untouched blocks keep their base content"
want_block "$T" 100 a1 "  ...while logged blocks are applied"

# ---- reproducibility (CRASH_TODO 4.7) ----------------------------------
A="$WORK/r1.img"; B="$WORK/r2.img"
fresh_target "$A"; fresh_target "$B"
replay_to "$A" "epoch<=3,drop=[1,4]"
replay_to "$B" "epoch<=3,drop=[1,4]"
if cmp -s "$A" "$B"; then ok "same spec replays byte-identically"; else bad "same spec produced different images"; fi

# A different spec must not land on the same state id.
ID1="$("$TORNER" replay --log "$LOG" --target "$A" --state-spec "epoch<=2" | sed 's/.*"state_id":"\([^"]*\)".*/\1/')"
ID2="$("$TORNER" replay --log "$LOG" --target "$B" --state-spec "epoch<=3" | sed 's/.*"state_id":"\([^"]*\)".*/\1/')"
[ -n "$ID1" ] && [ "$ID1" != "$ID2" ] && ok "distinct specs get distinct state ids" \
	|| bad "state id collision ($ID1 vs $ID2)"

# ---- enumeration counts ------------------------------------------------
N="$("$TORNER" replay --log "$LOG" --enumerate --strategy prefix 2>/dev/null | wc -l)"
[ "$N" = 3 ] && ok "prefix enumerates one state per epoch" || bad "prefix enumerated $N, wanted 3"

# Barriers and marks are skipped: dropping one changes no byte on disk, so it
# would just duplicate the plain prefix state.  6 writes -> 6 states.
N="$("$TORNER" replay --log "$LOG" --enumerate --strategy single-drop 2>/dev/null | wc -l)"
[ "$N" = 6 ] && ok "single-drop enumerates one state per data entry" || bad "single-drop enumerated $N, wanted 6"

# Reproducible enumeration: random-subset must depend only on the seed.
S1="$("$TORNER" replay --log "$LOG" --enumerate --strategy random-subset --samples 3 --seed 7 2>/dev/null)"
S2="$("$TORNER" replay --log "$LOG" --enumerate --strategy random-subset --samples 3 --seed 7 2>/dev/null)"
[ "$S1" = "$S2" ] && ok "random-subset enumeration is seed-deterministic" || bad "random-subset varied between runs"

# ---- progress marks ----------------------------------------------------
# The bound that lets a replayed state know which progress-log records it is
# answerable for.  A MARK stores its string inside its own entry sector, not as
# a trailing payload; reading it the wrong way yields a silent progress_limit
# of 0, which makes every write past the cut look like a lost durable write.
PL() { "$TORNER" replay --log "$LOG" --enumerate --strategy prefix 2>/dev/null \
	| sed -n "s/.*\"epoch\":$1,.*\"progress_limit\":\([0-9]*\).*/\1/p"; }
[ "$(PL 1)" = 10 ] && ok "mark in epoch 1 bounds progress at 10" || bad "epoch 1 progress_limit = $(PL 1), wanted 10"
[ "$(PL 2)" = 20 ] && ok "  ...and epoch 2 at 20" || bad "epoch 2 progress_limit = $(PL 2), wanted 20"

OUT="$("$TORNER" replay --log "$LOG" --target "$WORK/t1.img" --state-spec 'epoch<=2')"
printf '%s' "$OUT" | grep -q '"progress_limit":20' && ok "  ...and apply reports the same bound" \
	|| { bad "apply reported a different bound"; echo "        $OUT"; }

# ---- refusals ----------------------------------------------------------
# `targeted` needs journal block identification.  Enumerating something weaker
# under that name would quietly weaken the strongest claim in the plan.
if "$TORNER" replay --log "$LOG" --enumerate --strategy targeted >/dev/null 2>&1; then
	bad "targeted strategy should refuse, not run"
else
	ok "unimplemented targeted strategy refuses"
fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" = 0 ]
