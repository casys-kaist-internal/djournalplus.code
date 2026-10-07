#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Explore phase (CRASH_TODO §4.5): rebuild crash states from a capture, let the
# file system recover each one, and judge it.
#
#     for state in strategy.enumerate(log):
#         image = copy(base)
#         torner replay --state-spec state -> image
#         mount            # recovery runs here
#         torner check     # P1, P2 -- and, for atom-*, each targeted write
#         umount; fsck -n  # P3
#         emit JSONL
#
# States are independent, so this runs --jobs of them at a time.
#
# RUN THIS IN THE GUEST.  Every state is a deliberately damaged file system and
# mounting one can take the kernel down; that is the whole reason CRASH_TODO
# puts a VM in the loop.  Prefix states are ordinary crash states and are
# comparatively tame, but single-drop and random-subset are not.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
TOOL="$HERE/state_tool.py"
. "$HERE/fsmap.sh"

CAPTURE=""
STRATEGY="single-drop"
LIMIT=100
JOBS=4
SAMPLES=4
SEED=1
ATOM=4096
FIRST_COPY_ONLY=""
PREFER_SPLIT=""
SIGNATURES=""
OUT=""
TIER="T2b"

usage() {
	cat >&2 <<EOF
usage: explore.sh --capture DIR [options]

  --capture DIR     directory produced by capture.sh
  --strategy S      epoch-based:  prefix | single-drop | reverse |
                                  random-subset | torn-entry     [single-drop]
                    write-based:  atom-order | atom-reorder | atom-tear
                    (states aimed at individual application writes; each
                    record says which targeted writes tore -- see README)
  --limit N         examine at most N states                         [100]
                    epoch-based: spread evenly over the run
                    atom-*: the planner's budget; it samples whole
                    writes, so it may overrun by one write's states
  --jobs K          states in flight at once                         [4]
  --samples N       random-subset samples per epoch                  [4]
  --seed U64        random-subset / atom-* sampling seed             [1]
  --atom BYTES      device atomic unit for torn-entry / atom-tear    [4096]
  --first-copy-only atom-tear: tear only where a write first lands
  --prefer-split    atom-*: spend --limit on split writes first -- for
                    finding a witness; read the result per shape
  --signatures FILE atom-*: only writes of these shapes (one signature per
                    line, as in atoms.json) -- the fuzzer's new coverage
  --out FILE        JSONL output            [CAPTURE/states-STRATEGY.jsonl]
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--capture)  CAPTURE="$2"; shift 2 ;;
	--strategy) STRATEGY="$2"; shift 2 ;;
	--limit)    LIMIT="$2"; shift 2 ;;
	--jobs)     JOBS="$2"; shift 2 ;;
	--samples)  SAMPLES="$2"; shift 2 ;;
	--seed)     SEED="$2"; shift 2 ;;
	--atom)     ATOM="$2"; shift 2 ;;
	--first-copy-only) FIRST_COPY_ONLY="--first-copy-only"; shift ;;
	--prefer-split) PREFER_SPLIT="--prefer-split"; shift ;;
	--signatures) SIGNATURES="$2"; shift 2 ;;
	--out)      OUT="$2"; shift 2 ;;
	-h|--help)  usage ;;
	*) echo "explore.sh: unknown option $1" >&2; usage ;;
	esac
done

[ -n "$CAPTURE" ] || usage
[ -x "$TORNER" ] || { echo "explore.sh: torner not built at $TORNER" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "explore.sh: must run as root (losetup/mount)" >&2; exit 1; }
[ -f "$CAPTURE/capture.json" ] || { echo "explore.sh: no capture.json in $CAPTURE" >&2; exit 1; }
command -v python3 >/dev/null || { echo "explore.sh: python3 required" >&2; exit 1; }

case "$STRATEGY" in
atom-*) IS_ATOM=1 ;;
*)      IS_ATOM=0 ;;
esac

jget() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" "$CAPTURE/capture.json" | head -1; }
jnum() { sed -n "s/.*\"$1\":\\([0-9]*\\).*/\\1/p" "$CAPTURE/capture.json" | head -1; }

FS="$(jget fs)"
RUN_ID="$(jnum run_id)"
MODE="$(jget mode)"
THREADS="$(jnum threads)"
UNIT="$(jnum unit)"
[ -n "$UNIT" ] || UNIT=16384		# captures from before --unit existed
WORKLOAD="torner:$MODE:t$THREADS"
BASE_ZERO="$(sed -n 's/.*"base_is_zero":\(true\|false\).*/\1/p' "$CAPTURE/capture.json" | head -1)"
[ -n "$BASE_ZERO" ] || BASE_ZERO=false
BASE="$CAPTURE/base.img"
LOG="$CAPTURE/log.img"
PROG="$CAPTURE/progress.img"
BASEFSCK="$CAPTURE/fsck-baseline.txt"
[ -f "$BASEFSCK" ] || : > "$BASEFSCK"
DATAFILE="torner.dat"
export TORNER_ZPOOL="${TORNER_ZPOOL:-torner_pool}"

[ -f "$BASE" ] && [ -f "$LOG" ] || { echo "explore.sh: base.img/log.img missing" >&2; exit 1; }
fs_mount_opts "$FS" || exit 1

JOBS_WANT="$JOBS"
JOBS="$(fs_max_jobs "$FS" "$JOBS")"
[ "$JOBS" = "$JOBS_WANT" ] || echo "[explore] $FS: forcing --jobs $JOBS (clones of one file system -- same fsid or pool GUID -- cannot be mounted side by side)" >&2

[ -n "$OUT" ] || OUT="$CAPTURE/states-$STRATEGY.jsonl"
WORK="$CAPTURE/explore"
rm -rf "$WORK"; mkdir -p "$WORK"
: > "$OUT"

say() { echo "[explore] $*" >&2; }

# ---- enumerate ---------------------------------------------------------
ENUM="$WORK/states.all"
if [ "$IS_ATOM" = 1 ]; then
	# The planner samples and budgets by itself -- whole application
	# writes -- so its output is examined as is.  Thinning it again here
	# would try some states of a write and not others, and the result could
	# no longer say "writes torn out of writes tried".
	#
	# Nor is anything filtered on progress_limit: every state is aimed at a
	# workload write, so the file exists; a state before the first progress
	# mark simply has no durable write for P2 to hold it to (see below).
	"$TORNER" replay --log "$LOG" --enumerate --strategy "$STRATEGY" \
		--max-states "$LIMIT" --seed "$SEED" --run-id "$RUN_ID" \
		--atom "$ATOM" $FIRST_COPY_ONLY $PREFER_SPLIT \
		${SIGNATURES:+--signatures "$SIGNATURES"} > "$ENUM" 2>"$WORK/enum.err" \
		|| { cat "$WORK/enum.err" >&2; exit 1; }
	cat "$WORK/enum.err" >&2
	cp "$ENUM" "$WORK/states.pick"
	ENUM_ALL=$(wc -l < "$ENUM")
	TOTAL=$ENUM_ALL
	[ "$TOTAL" -gt 0 ] || { say "no application write is split or tearable under $STRATEGY -- nothing to examine"; exit 0; }
else
	"$TORNER" replay --log "$LOG" --enumerate --strategy "$STRATEGY" \
		--samples "$SAMPLES" --seed "$SEED" --atom "$ATOM" \
		> "$ENUM" 2>"$WORK/enum.err" \
		|| { cat "$WORK/enum.err" >&2; exit 1; }
	ENUM_ALL=$(wc -l < "$ENUM")

	# Drop everything before the workload started.  progress_limit comes
	# from the progress marks `torner gen` stamps into the stream, so it is
	# zero for exactly the states that predate the first mark -- mkfs and
	# file prefill.  Those do not even carry a formatted file system yet,
	# so they only produce mount failures and would dilute the torn-exposure
	# rate with noise.
	grep -v '"progress_limit":0}' "$ENUM" > "$WORK/states.live" || true
	TOTAL=$(wc -l < "$WORK/states.live")
	[ "$TOTAL" -gt 0 ] || { echo "explore.sh: no states after the first progress mark" >&2; exit 1; }

	if [ "$TOTAL" -gt "$LIMIT" ]; then
		# Evenly spaced rather than the first N, so the sample covers the
		# run rather than its opening seconds.
		awk -v t="$TOTAL" -v l="$LIMIT" 'NR % int((t+l-1)/l) == 1' "$WORK/states.live" \
			| head -n "$LIMIT" > "$WORK/states.pick"
	else
		cp "$WORK/states.live" "$WORK/states.pick"
	fi
fi
PICKED=$(wc -l < "$WORK/states.pick")
say "fs=$FS strategy=$STRATEGY enumerated=$ENUM_ALL live=$TOTAL examined=$PICKED jobs=$JOBS"

# ---- one state ---------------------------------------------------------
do_state() {
	local slot="$1" line="$2"
	local spec sid epoch img mnt loop pl rc p3 mountrc detail
	local st="$WORK/st$slot" chk="$WORK/c$slot" cerr="$WORK/ce$slot"
	local -a p2args focusargs

	printf '%s\n' "$line" > "$st"
	spec=$(printf '%s' "$line" | sed 's/.*"state_spec":"\([^"]*\)".*/\1/')
	sid=$(printf '%s' "$line" | sed 's/.*"state_id":"\([^"]*\)".*/\1/')
	epoch=$(printf '%s' "$line" | sed 's/.*"epoch":\([0-9]*\).*/\1/')

	img="$WORK/s$slot.img"
	mnt="$WORK/m$slot"
	mkdir -p "$mnt"
	rm -f "$chk" "$cerr"

	# Make the state image.  base.img is the device before logging started,
	# which capture.sh creates with truncate -- so it is all zeros and a
	# same-sized empty file IS a copy of it, made in constant time.
	#
	# This matters more than it looks: `cp --sparse=always` did not preserve
	# the holes here, so every state cost a dense 2 GiB write.  Eight of
	# those in flight filled the scratch disk, and the symptom was not a
	# disk-full error but every replay stalling in uninterruptible I/O.
	rm -f "$img"
	if [ "$BASE_ZERO" = true ]; then
		truncate -r "$BASE" "$img" || return 1
	else
		cp --sparse=always "$BASE" "$img" || return 1
	fi
	pl=$("$TORNER" replay --log "$LOG" --target "$img" --state-spec "$spec" \
		| sed 's/.*"progress_limit":\([0-9]*\).*/\1/')

	loop=$(losetup --show -f "$img") || { rm -f "$img"; return 1; }

	# mount -- or, for ZFS, pool import -- is where recovery runs.  A state
	# that will not come up is a result, not an error: record it and move on.
	if fs_is_zfs "$FS"; then
		# -d wants the loop device, not the backing file: handed a regular
		# file, zpool fails with "Block device required".
		fs_zfs_import "$loop" "$mnt" > "$WORK/e$slot" 2>&1
		mountrc=$?
	else
		# shellcheck disable=SC2086
		mount $FS_MOUNT_OPTS $FS_REPLAY_OPTS "$loop" "$mnt" 2>"$WORK/e$slot"
		mountrc=$?
	fi
	if [ "$mountrc" != 0 ]; then
		detail=$(head -1 "$WORK/e$slot")
		python3 "$TOOL" merge --state-file "$st" --mount-failed "$detail" \
			--tier "$TIER" --config "$FS" --workload "$WORKLOAD" \
			--run-id "$RUN_ID" --out "$OUT"
		losetup -d "$loop"; rm -f "$img"
		return 0
	fi

	# P2 is bounded by the last progress mark the state contains.  A state
	# with none (pl 0) has no fsync that had returned to hold it to, and
	# `check --progress-limit 0` would mean "no bound" -- every record in
	# the log binding -- so P2 is left out rather than faked.
	p2args=()
	[ "${pl:-0}" -gt 0 ] 2>/dev/null && \
		p2args=(--progress-log "$PROG" --progress-limit "$pl")
	focusargs=()
	if [ "$IS_ATOM" = 1 ]; then
		python3 "$TOOL" focus < "$st" > "$WORK/t$slot"
		focusargs=(--focus-file "$WORK/t$slot")
	fi

	"$TORNER" check --file "$(fs_data_dir "$FS" "$mnt")/$DATAFILE" \
		"${p2args[@]}" "${focusargs[@]}" \
		--run-id "$RUN_ID" --unit "$UNIT" \
		--tier "$TIER" --config "$FS" --workload "$WORKLOAD" \
		--state-id "$sid" --strategy "$STRATEGY" --epoch "${epoch:-0}" \
		--max-violations 8 > "$chk" 2>"$cerr"
	rc=$?

	# P3 first for ZFS: scrub needs the pool imported.  For the others fsck
	# needs it unmounted, so the order is reversed.
	if fs_is_zfs "$FS"; then
		fs_fsck_report "$FS" "$loop" > "$WORK/f$slot"
		fs_zfs_export
	else
		umount "$mnt" 2>/dev/null
	fi

	# P3 is only meaningful after recovery has run, i.e. after the mount
	# above -- a raw crash state legitimately has a dirty journal.  And it is
	# judged against the pristine filesystem, not against a zero exit code:
	# see fs_fsck_report() for why a fresh mkfs is already "dirty" here.
	fs_is_zfs "$FS" || fs_fsck_report "$FS" "$loop" > "$WORK/f$slot"
	if [ -s "$BASEFSCK" ] || [ -s "$WORK/f$slot" ]; then
		if diff -q "$BASEFSCK" "$WORK/f$slot" >/dev/null 2>&1; then
			p3=pass
		else
			p3=fail
		fi
	else
		p3=pass
	fi
	losetup -d "$loop"
	rm -f "$img"

	# check cannot know P3 (it runs before umount), so it is merged in here,
	# together with the state the verdict belongs to.
	python3 "$TOOL" merge --state-file "$st" --check-file "$chk" --p3 "$p3" \
		--check-error "$(head -1 "$cerr" 2>/dev/null)" \
		--tier "$TIER" --config "$FS" --workload "$WORKLOAD" \
		--run-id "$RUN_ID" --out "$OUT"
	: "$rc"
	return 0
}

# ---- run ---------------------------------------------------------------
slot=0
n=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	do_state "$slot" "$line" &
	slot=$(( (slot + 1) % JOBS ))
	n=$((n + 1))
	if [ $((n % JOBS)) = 0 ]; then
		wait
		printf '\r[explore] %d/%d' "$n" "$PICKED" >&2
	fi
done < "$WORK/states.pick"
wait
printf '\r' >&2

# ---- summary -----------------------------------------------------------
say "results -> $OUT"
python3 - "$OUT" <<'EOF' >&2
import json, sys

n = p1 = p2 = p3 = mf = nochk = 0
targeted, torn, states_tearing = set(), set(), 0
for line in open(sys.argv[1]):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    n += 1
    o = r.get("oracle", {})
    p1 += o.get("p1") == "fail"
    p2 += o.get("p2") == "fail"
    p3 += o.get("p3") == "fail"
    mf += r.get("mount") == "failed"
    if r.get("mount") == "ok" and "focus" not in r and "stats" not in r:
        nochk += 1
    if "targets" in r and "focus" in r:
        targeted.update(map(tuple, r["targets"]))
        tt = r.get("targets_torn", [])
        torn.update(map(tuple, tt))
        states_tearing += bool(tt)

print("[explore] states=%d  P1 torn=%d (%.1f%%)  P2 lost=%d  P3 dirty=%d"
      "  unmountable=%d  unjudged=%d"
      % (n, p1, 100.0 * p1 / n if n else 0, p2, p3, mf, nochk))
if targeted:
    print("[explore] application writes targeted=%d  torn=%d (%.1f%%)"
          "  states tearing a target=%d"
          % (len(targeted), len(torn), 100.0 * len(torn) / len(targeted),
             states_tearing))
EOF
