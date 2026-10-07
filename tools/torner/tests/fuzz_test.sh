#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Tests for scripts/fuzz.py that need no root and no devices: the mutation
# stays inside the input space and is reproducible, coverage is read off
# `torner atoms` the way the loop reads it, and witnesses are picked out of
# explore's records with what it takes to reproduce them.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TORNER="${TORNER:-$HERE/../torner}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$TORNER" ] || { echo "torner not built at $TORNER (run make)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
echo "torner fuzz tests"

python3 "$HERE/mklog.py" atomslog "$WORK/a.log"
"$TORNER" atoms --log "$WORK/a.log" --run-id 777 > "$WORK/atoms.json"

cat > "$WORK/states.jsonl" <<'EOF'
{"strategy":"atom-order","model":"O","state_spec":"entry<=5","state_id":"x1","targets":[[2,1]],"shapes":["split_window"],"targets_torn":[[2,1]],"oracle":{"p3":"pass"}}
{"strategy":"atom-order","model":"O","state_spec":"entry<=7","state_id":"x2","targets":[[2,1]],"shapes":["split_window"],"targets_torn":[],"oracle":{"p3":"pass"}}
not json
EOF

python3 - "$HERE/../scripts" "$WORK" <<'EOF'
import json, os, random, subprocess, sys
sys.path.insert(0, sys.argv[1])
import fuzz
work = sys.argv[2]
passed = failed = 0

def check(cond, what):
    global passed, failed
    if cond:
        print("  \033[32mok\033[0m    " + what); passed += 1
    else:
        print("  \033[31mFAIL\033[0m  " + what); failed += 1

# mutation: inside the space, 1..3 knobs, reproducible
rng = random.Random(7)
kids = [fuzz.mutate(fuzz.SEED_CONFIG, rng) for _ in range(200)]
check(all(all(v in fuzz.SPACE[k] for k, v in c.items()) for c in kids),
      "mutants stay inside the input space")
diffs = [sum(c[k] != fuzz.SEED_CONFIG[k] for k in c) for c in kids]
check(min(diffs) >= 1 and max(diffs) <= 3, "each mutant changes 1 to 3 knobs")
rng2 = random.Random(7)
check(kids == [fuzz.mutate(fuzz.SEED_CONFIG, rng2) for _ in range(200)],
      "same seed, same mutants")

# coverage: signatures plus count buckets
atoms = json.load(open(os.path.join(work, "atoms.json")))
f = fuzz.features(atoms)
check("split_flush/k2/n2/f1" in f and "split_flush/k2/n2/f1#1" in f,
      "coverage is each shape signature and its count bucket")
check([fuzz.bucket(n) for n in (1, 2, 3, 4, 7, 8, 100)] ==
      ["1", "2", "3", "4+", "4+", "8+", "64+"], "count buckets are AFL-style")
check(fuzz.features({}) == set(), "a failed capture contributes no coverage")

# exploration is aimed at the shapes behind the new coverage
check(fuzz.new_signatures(["a/k1#1", "a/k1", "b/k2#4+"]) == ["a/k1", "b/k2"],
      "new coverage names the shapes to aim states at")

# the knobs reach gen as plain options
g = fuzz.gen_args(dict(fuzz.SEED_CONFIG, direct=1, other_fsync_ms=5, writeback_ms=1))
check(g == "--direct --other-fsync-ms 5 --writeback-ms 1",
      "interference knobs map onto torner gen options")
check(fuzz.gen_args(fuzz.SEED_CONFIG) == "", "the seed configuration adds none")

# witnesses: only torn targets, with what reproduces them
w = fuzz.witnesses_in(os.path.join(work, "states.jsonl"))
check(len(w) == 1 and w[0]["state_spec"] == "entry<=5"
      and w[0]["targets_torn"] == [[2, 1]] and w[0]["shapes"] == ["split_window"],
      "a witness is a torn target with its state_spec and shape")

# dry run: prints what it would run, runs nothing
p = subprocess.run([sys.executable, os.path.join(sys.argv[1], "fuzz.py"),
                    "--fs", "ext4", "--workdir", os.path.join(work, "fz"),
                    "--dry-run"], capture_output=True, text=True)
check(p.returncode == 0 and "capture.sh" in p.stderr and "explore.sh" in p.stderr
      and "--prefer-split" in p.stderr and "--signatures" in p.stderr,
      "--dry-run shows the capture and explore commands")

print("\npassed %d, failed %d" % (passed, failed))
sys.exit(1 if failed else 0)
EOF
