#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
torner-fuzz -- coverage-guided search over the workload's input surface.

Crash states can only break the application writes a workload actually
produced, and which ones get split depends on the input: thread count, unit
size, mode, fsync policy, O_DIRECT, and the interference that makes commits
happen in the middle of a write -- another file's fsync(), a sync(), writeback
catching a unit halfway through its copy.  This explores that surface.

Each iteration mutates a workload configuration, captures it (capture.sh), and
reads how every application write reached the device (atoms.json, which
capture.sh writes).  The coverage signal is the set of write shape
signatures -- class, pieces, log entries, FLUSHes spanned, flags -- with
AFL-style count buckets.  Nothing in it knows one file system from another.
A configuration that produces a shape not seen before joins the corpus, and
its writes are explored (explore.sh --prefer-split) for a witness: a
state_spec that replays, through the file system's own recovery, to a torn
write.

  baseline file systems   --stop-on-witness: one reproducible tear settles it
  tauJournal              run to the budget: the result is every shape the
                          campaign reached, and the witnesses found

Run in the guest, as root, like capture.sh and explore.sh.

  fuzz.py --fs ext4-data --workdir /mnt/scratch/fuzz-ext4data \\
          --iterations 30 --stop-on-witness

Outputs, in --workdir:
  fuzz.jsonl        one record per iteration: configuration, new coverage,
                    shapes, what exploring it found
  witnesses.jsonl   every torn application write found, with the capture
                    and state_spec that reproduce it
  corpus.json       the configurations kept, and the coverage reached
"""
import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# The input surface.  Every knob is plain POSIX behaviour, so the same
# configuration means the same thing on every file system.
SPACE = {
    "threads":        [1, 2, 4, 8, 16, 32],
    "unit":           [8192, 16384, 32768, 65536],
    "mode":           ["overwrite", "append", "alloc", "delalloc", "mixed"],
    "fsync_every":    [1, 2, 4, 0],
    "pages":          [64, 256, 1024, 4096],
    "direct":         [0, 1],
    "fdatasync":      [0, 1],
    "sync_ms":        [0, 1, 5, 20],
    "other_fsync_ms": [0, 1, 5, 20],
    "writeback_ms":   [0, 1, 5, 20],
}

SEED_CONFIG = {
    "threads": 4, "unit": 16384, "mode": "overwrite", "fsync_every": 1,
    "pages": 1024, "direct": 0, "fdatasync": 0,
    "sync_ms": 0, "other_fsync_ms": 0, "writeback_ms": 0,
}

BIG_FILES = ("log.img", "base.img", "progress.img", "backing.img")


def mutate(cfg, rng, max_knobs=3):
    """Change 1..max_knobs knobs to a different value from their domain
    (knobs with a single value are fixed, e.g. direct on tau)."""
    child = dict(cfg)
    knobs = rng.sample([k for k in sorted(SPACE) if len(SPACE[k]) > 1],
                       rng.randint(1, max_knobs))
    for k in knobs:
        choices = [v for v in SPACE[k] if v != cfg.get(k)]
        child[k] = rng.choice(choices)
    return child


def cfg_key(cfg):
    return json.dumps(cfg, sort_keys=True)


def bucket(n):
    """AFL-style count buckets: 1, 2, 3, 4-7, 8-15, 16-31, ..."""
    if n <= 3:
        return str(n)
    b = 4
    while b * 2 <= n:
        b *= 2
    return "%d+" % b


def features(atoms):
    """Coverage features of one capture: each shape signature, and each
    (signature, count bucket) -- so producing a rare shape more often is
    progress too, not only producing a new one."""
    f = set()
    for sig, n in atoms.get("signatures", {}).items():
        f.add(sig)
        f.add("%s#%s" % (sig, bucket(n)))
    return f


def gen_args(cfg):
    a = []
    if cfg.get("direct"):
        a.append("--direct")
    if cfg.get("fdatasync"):
        a.append("--fdatasync")
    for k, opt in (("sync_ms", "--sync-ms"),
                   ("other_fsync_ms", "--other-fsync-ms"),
                   ("writeback_ms", "--writeback-ms")):
        if cfg.get(k):
            a += [opt, str(cfg[k])]
    return " ".join(a)


def capture_cmd(args, cfg, capdir, run_id):
    return [os.path.join(HERE, "capture.sh"), "--workdir", capdir,
            "--fs", args.fs, "--mode", cfg["mode"],
            "--threads", str(cfg["threads"]), "--pages", str(cfg["pages"]),
            "--unit", str(cfg["unit"]), "--duration", str(args.duration),
            "--fsync-every", str(cfg["fsync_every"]),
            "--dev-size", args.dev_size, "--log-size", args.log_size,
            "--gen-args", gen_args(cfg), "--run-id", str(run_id)]


def explore_cmd(args, capdir, strategy, sigfile=None):
    cmd = [os.path.join(HERE, "explore.sh"), "--capture", capdir,
           "--strategy", strategy, "--limit", str(args.explore_limit),
           "--jobs", str(args.jobs), "--prefer-split", "--seed",
           str(args.seed), "--out",
           os.path.join(capdir, "states-%s.jsonl" % strategy)]
    if sigfile:
        cmd += ["--signatures", sigfile]
    return cmd


def new_signatures(new_features):
    """The shapes behind new coverage -- a new signature, or one seen before
    that this input produced more often -- which are the writes to aim at."""
    return sorted({f.split("#", 1)[0] for f in new_features})


def witnesses_in(path):
    """Records whose targeted writes tore, reduced to what reproduces them."""
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not r.get("targets_torn"):
                continue
            shapes = dict(zip(map(tuple, r.get("targets", [])),
                              r.get("shapes", [])))
            out.append({
                "strategy": r.get("strategy"), "model": r.get("model"),
                "state_spec": r.get("state_spec"),
                "state_id": r.get("state_id"),
                "targets_torn": r["targets_torn"],
                "shapes": [shapes.get(tuple(t), "?") for t in r["targets_torn"]],
                "p3": r.get("oracle", {}).get("p3"),
            })
    return out


def run(cmd, log, dry_run):
    if dry_run:
        print("  $ " + " ".join(cmd), file=sys.stderr)
        return 0
    with open(log, "a") as f:
        return subprocess.call(cmd, stdout=f, stderr=subprocess.STDOUT)


def append_jsonl(path, obj):
    with open(path, "a") as f:
        f.write(json.dumps(obj, separators=(",", ":")) + "\n")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fs", required=True, help="configuration, as capture.sh --fs")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--iterations", type=int, default=20)
    ap.add_argument("--time-budget", type=int, default=0,
                    help="seconds; stop starting new iterations after this [0 = none]")
    ap.add_argument("--duration", type=int, default=3, help="workload seconds [3]")
    ap.add_argument("--strategies", default="atom-order,atom-reorder",
                    help="explored for every new-coverage capture "
                         "[atom-order,atom-reorder]")
    ap.add_argument("--explore-limit", type=int, default=200,
                    help="state budget per strategy per capture [200]")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--explore-all", action="store_true",
                    help="aim states at every write of a new-coverage capture, "
                         "not only at the writes whose shapes were new")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--seed-config", default="",
                    help='JSON merged into the starting configuration, '
                         'e.g. \'{"threads": 1}\'')
    ap.add_argument("--dev-size", default="2G")
    ap.add_argument("--log-size", default="8G",
                    help="sparse; large, because a full log silently stops logging")
    ap.add_argument("--stop-on-witness", action="store_true",
                    help="stop at the first torn write (baseline file systems)")
    ap.add_argument("--keep-all", action="store_true",
                    help="keep every capture's images, not only the useful ones")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the commands of the first iteration and stop")
    args = ap.parse_args()
    # capture.sh opens the target with O_TAU_UNTORN on the tau configurations,
    # which the kernel refuses together with O_DIRECT (EINVAL at open)
    tau = args.fs.startswith("tau-")
    if tau:
        SPACE["direct"] = [0]

    rng = random.Random(args.seed)
    start = dict(SEED_CONFIG)
    if args.seed_config:
        start.update(json.loads(args.seed_config))
        bad = [k for k, v in start.items() if k not in SPACE or v not in SPACE[k]]
        if bad:
            ap.error("--seed-config: %s outside the input space" % ", ".join(bad))
    os.makedirs(args.workdir, exist_ok=True)
    fuzz_log = os.path.join(args.workdir, "fuzz.jsonl")
    wit_log = os.path.join(args.workdir, "witnesses.jsonl")
    corpus_path = os.path.join(args.workdir, "corpus.json")

    corpus, seen, tried = [dict(start)], set(), set()
    if os.path.exists(corpus_path):
        with open(corpus_path) as f:
            saved = json.load(f)
        corpus = saved.get("corpus", corpus) or corpus
        if tau:     # a corpus saved before direct was fixed may hold direct=1
            corpus = [dict(c, direct=0) for c in corpus]
        seen = set(saved.get("features", []))
        tried = set(saved.get("tried", []))

    t0 = time.time()
    nwit = 0
    strategies = [s for s in args.strategies.split(",") if s]
    for it in range(args.iterations):
        if args.time_budget and time.time() - t0 > args.time_budget:
            break
        # the seed configuration first; then mutants of the corpus, never
        # the same configuration twice
        cfg = dict(start) if it == 0 and not tried else None
        for _ in range(100):
            if cfg is not None and cfg_key(cfg) not in tried:
                break
            cfg = mutate(rng.choice(corpus), rng)
        tried.add(cfg_key(cfg))

        capdir = os.path.join(args.workdir, "c%04d" % len(tried))
        run_id = (args.seed << 20) + len(tried)
        log = os.path.join(args.workdir, "c%04d.log" % len(tried))
        shutil.rmtree(capdir, ignore_errors=True)
        started = time.time()
        rc = run(capture_cmd(args, cfg, capdir, run_id), log, args.dry_run)
        rec = {"iter": it, "capture": capdir, "config": cfg, "rc": rc}

        atoms = {}
        ap_path = os.path.join(capdir, "atoms.json")
        if rc == 0 and os.path.exists(ap_path):
            with open(ap_path) as f:
                atoms = json.load(f)
        feats = features(atoms)
        new = sorted(feats - seen)
        seen |= feats
        rec["new_coverage"] = new
        rec["writes"] = atoms.get("writes", {}).get("workload", 0)
        rec["shape"] = {k: atoms.get("shape", {}).get(k, 0)
                        for k in ("one_bio", "split_window", "split_flush",
                                  "partial", "reorderable")}

        found = []
        sigfile = None
        if new and not args.explore_all:
            sigfile = os.path.join(capdir, "new-signatures.txt")
            if not args.dry_run:
                with open(sigfile, "w") as f:
                    f.write("".join(sg + "\n" for sg in new_signatures(new)))
        if new and not args.dry_run:
            corpus.append(cfg)
            for strat in strategies:
                run(explore_cmd(args, capdir, strat, sigfile), log, args.dry_run)
                w = witnesses_in(os.path.join(capdir, "states-%s.jsonl" % strat))
                for x in w:
                    x.update({"capture": capdir, "config": cfg, "fs": args.fs})
                    append_jsonl(wit_log, x)
                found += w
                if found and args.stop_on_witness:
                    break
        elif args.dry_run:
            for strat in strategies:
                run(explore_cmd(args, capdir, strat,
                                None if args.explore_all else
                                os.path.join(capdir, "new-signatures.txt")),
                    log, True)
        rec["witnesses"] = len(found)
        rec["torn_writes"] = sorted({tuple(t) for x in found
                                     for t in x["targets_torn"]})
        rec["seconds"] = round(time.time() - started, 1)
        nwit += len(found)

        # a capture that taught nothing is not worth 2 GiB of scratch
        if not args.keep_all and not found and not args.dry_run:
            for name in BIG_FILES:
                try:
                    os.unlink(os.path.join(capdir, name))
                except OSError:
                    pass
            shutil.rmtree(os.path.join(capdir, "explore"), ignore_errors=True)

        append_jsonl(fuzz_log, rec)
        with open(corpus_path, "w") as f:
            json.dump({"fs": args.fs, "corpus": corpus,
                       "features": sorted(seen), "tried": sorted(tried)}, f)
        print("[fuzz] #%d rc=%d writes=%d split=%d/%d new=%d witnesses=%d  %s"
              % (it, rc, rec["writes"], rec["shape"]["split_window"],
                 rec["shape"]["split_flush"], len(new), len(found),
                 cfg_key(cfg)), file=sys.stderr)
        if args.dry_run or (found and args.stop_on_witness):
            break

    print("[fuzz] %d configurations, corpus %d, %d coverage features, %d witness "
          "states -> %s" % (len(tried), len(corpus), len(seen), nwit, args.workdir),
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
