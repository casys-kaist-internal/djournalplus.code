> **In git since 11-10, for runs on other hosts.** The scripts were copied here from libra09's
> `bench/workspace/results/libra09/correctness/t1_seq2/`, with repo-relative paths. Results stay outside git.
> - The k60 sample travels as `k60.tar.xz` (cpp/, sample.tsv, invalid.tsv).
> - `unpack_k60.sh <dir>` unpacks it and builds so/, about 2.5 min with 32 jobs. On libra09 the rebuilt .so are
>   byte-identical to the originals.
> - Then run `run_seq2.sh <dir>`. `sample.py` needs Ace's `work/`, so only a new sample needs it.
> - `k60_could_not_run.tsv` lists the 114 k60 workloads that cannot run, with the reasons from libra09's #1980 run
   (ext4-tau, classify.py). These IDs are invalid as Ace generated them, so they are the same on every kernel; #398
   on libra08 gave the identical 114. Use it where Ace's j-lang files are missing.

# T1 — CrashMonkey ACE seq-2 sample on τ (libra09, 2026-11-06)

EVAL_PLAN §6.2 T1, seq-2 sample. Seq-1 (328 workloads) passed on all four configs:
`tools/crashmonkey/results-libra09-1980`, paper copy `paper/evaluation/t1_crashmonkey_seq1`.

Ace's full seq-2 set is 466,382 workloads. Running all of it on both τ variants would take about 9 VM-days, so
this runs a stratified random sample.

## Method

**Sample.** 60 random workloads from each of the 169 op pairs, which is 10,100 workloads. `mkdir,mkdir` has only
20, and all 20 are in. Seed 20261106.
- The pairs vary a lot in size: 20 workloads (`mkdir,mkdir`) up to 34,200 (`falloc,falloc`). A uniform sample would
  leave the small pairs out.

**Generation** (`work/`). `work/ace` is a copy of `tools/crashmonkey/ace` (Ace v0.1). Its `ace.py` is patched in
three ways:
- `ACE_JLANG_ONLY=1` writes only the j-lang files; the adapter runs later, on the sample only.
- The final move of the files uses `find`, since 466k files are too many for a glob.
- A stub `progress/` stands in for the missing pip package.

`ace.py -l 2 -n False -d False` gives 466,382 workloads in 63 s. `work/workload_skeleton.tsv` maps each workload to
its op pair, taken from Ace's log.

**Build** (`sample.py`).
- Each pair's workloads are shuffled once, and the first 60 that compile are taken.
- 607 workloads do not compile, because Ace or its adapter generated them wrong. The next workload of the same pair
  replaced each one. They are listed in `k60/invalid.tsv`:
  - 565: `fd_ACfoo` undeclared, an fsync of A/C/foo, which the workload never opened;
  - 42: `to_write_*` declared twice, two mmapwrites on one file.
- Compile command: the same as `code/Makefile`'s seq1 rule (g++-9, `-DNEW_XATTR_INC`, the same objects).

**Run** (`run_seq2.sh`). One CrashMonkey VM per variant, running side by side. Each variant follows
`run_tau_suite.sh` + `run_tau_vm.sh`, so it matches the seq-1 τ rows:
- guest: an overlay on `cm-guest-ubuntu.qcow2`;
- kernel: the tree's bzImage, #1980 = new_main a6d55fe7, with `initrd.img-6.8.0tjournal+-1980`;
- CrashMonkey types `ext4-tau` / `xfs-tau`, which put O_TAU_UNTORN on every buffered open;
- `CM_MKFS` with the forks and 4 MiB segments (ext4 `-b 4096`), and `CM_MNT_OPTS=tjournal`;
- cow_brd devices of 200 MB (ext4) and 400 MB (xfs).

As in seq-1:
- The 1,500 workloads of the 25 mmapwrite pairs map a file writable and shared. τ refuses such a mapping, so they
  run on plain files (`CM_TAU_PLAIN`).
- xfs-τ formats with the fork's mkfs.xfs defaults (nrext64=1), as the seq-1 τ rows did.

**Classification** (`classify.py`). It sorts the workloads that could not run and computes the counts from
`xfsMonkey.log`. See the correction below.

## Result: 0 failures on both τ variants (final: 9,986 passed on each)

| variant | workloads | passed | failed | could not run | invalid as generated | harness assert | kernel fault lines |
|---|---:|---:|---:|---:|---:|---:|---:|
| τ-EXT4 | 10,100 | 9,986 | 0 | 114 | 114 | 0 | 0 |
| τ-XFS | 10,100 | 9,977 | 0 | 123 | 114 | 9 | 0 |

This is the K=60 run as it came out. The 10 τ-XFS workloads that could not run hit a CrashMonkey harness bug. With
the fixed harness (crashmonkey ce30c4d, see below) all 10 pass, so the final count is the same on both variants:
**9,986 passed, 0 failed, 114 invalid as generated.**

- Wall time: ext4 2.0 h (0.72 s per workload), xfs 2.7 h (0.97 s).
- Kernel fault lines: none in the guest dmesg or the console of either VM.
- Upper bound: no runnable workload failed. With 9,986 runnable workloads per variant (after the rerun below),
  the rule of three gives a 95% upper bound of about 0.03% on the per-workload failure rate, and about 5% (3/60) per op pair. This holds for the stratified
  sample, not for a uniform draw from the 466k.

**Invalid as generated** (the same 114 workloads on both variants). In each, one of the workload's own calls must
fail on any file system:

| reason | count | the call that fails |
|---|---:|---|
| rename-into-subdir | 105 | `rename A AC`: a directory into its own subtree (A/C). The VFS returns EINVAL. |
| rename-onto-nonempty-dir | 4 | rename onto a directory that has entries: ENOTEMPTY on ext4, EEXIST on xfs |
| falloc-negative-offset | 3 | fallocate at offset −2000, after a truncate to 0: EINVAL |
| moved-away-path | 1 | an opendir of A/C after `rename A B`, then an fsync of the bad fd: EBADF |
| msync-unaligned | 1 | an mmapwrite at offset 35768: the adapter msyncs from that unaligned address, EINVAL |

**xfs-τ only: 9 harness asserts.**
- What happens: c_harness aborts on `Tester.cpp:790`, `assert(last_checkpoint < mods_.size() && last_checkpoint >
  0)`.
  - The abort comes in the check phase ("Writing data out to each Checkpoint"), after "Passed sanity checks". No
    content check had failed.
  - It is a harness bug in upstream CrashMonkey, not a τ-XFS consistency failure. See the follow-up below.
- Which: j-lang440208, 440212, 440306, 440307 (fsetxattr,truncate), 448840, 448842, 448844 (removexattr,truncate),
  175217 (dwrite,dwrite) and 361324 (rename,falloc).
  - Seven of them end with a write, `truncate foo 2500` and an fsync or sync, after an xattr op and a checkpoint.
- The retry pattern: the 1st and 3rd tries abort, and the 2nd and 4th fail on the socket the abort left bound
  ("Error starting socket to listen on 98"). So xfsMonkey gives up.
- One more, j-lang185881, aborted once and passed on its third try.
- ext4-τ has no assert at all.

**Correction to copy_diff.sh's count.** `run-xfs.out` says 9,986 passed, because `copy_diff.sh` prints "Passed"
whenever `build/` holds diff files. The aborted runs left empty diff files behind, so the 9 aborts count as passed
there. The table above uses `xfsMonkey.log`, where xfsMonkey gave up on them ("Could not run test").

## Follow-up: the 124 that could not run, on stock and on τ again (11-07 04:55–05:10 KST)

`followup/` holds 124 workloads: every one that could not run on either variant, plus j-lang185881. They ran
twice after the τ killtest:
- `STOCK=1 run_seq2.sh followup followup/run-1980-stock`: CrashMonkey's stock ext4 / xfs types on the same VM
  and kernel, with the guest's Ubuntu tools (mke2fs 1.47.0, mkfs.xfs 6.6.0), as
  `results-libra09-1980/run_stock.sh` does;
- `run_seq2.sh followup followup/run-1980-tau`: τ again.

| variant | passed | could not run | invalid as generated | harness assert |
|---|---:|---:|---:|---:|
| stock ext4 | 10 | 114 | 114 | 0 |
| stock xfs | 10 | 114 | 114 | 0 |
| τ-EXT4 (again) | 10 | 114 | 114 | 0 |
| τ-XFS (again) | 0 | 124 | 114 | 10 |

- **The 114 invalid ones are invalid on stock too.** Each fails the same way, with the same status, on stock
  ext4 and xfs as on τ.
- **The harness asserts show up only on τ-XFS, and the harness causes them.**
  - The 10 (the 9 plus j-lang185881) pass on stock xfs and on τ-EXT4, and all 10 abort on τ-XFS again.
  - They reproduce on τ-XFS: every one aborted in both runs. Within a run, every try that got past the socket
    aborted.
  - The one exception is a single try: j-lang185881's third try in the K=60 run passed.
- **Cause: an upstream CrashMonkey harness bug, not a τ-XFS consistency failure.** libra08:tau triaged it on 11-07
  by reading port-linux-6.8 f8c9542.
  - The replay loop ("Writing data out to each Checkpoint") ends its inner loop at a checkpoint or at
    `log_data.end()`. It then calls `log_iter->is_checkpoint()` twice, at Tester.cpp:994 and :1038, without
    checking for end().
  - When the block log has writes after its last checkpoint, both calls read the slot past the vector's last
    element. When that garbage reads as checkpoint 0, the check is called with `last_checkpoint` 0, and the assert
    fails on `last_checkpoint > 0`.
  - A 3 would have stopped earlier, at the snapshot lookup, with "ERROR: no saved snapshot at checkpoint 3".
  - Whether the garbage reads as a checkpoint depends on the log's length and the heap's history. That fits a
    repeatable abort per workload that still passed once.
  - libra08:tau found the same bug in its earlier seq-1 τ-xfs runs: #358-plain, #362 and #365, on j-lang15 and
    j-lang75. copy_diff.sh had counted those as passes.
    - libra09's seq-1 runs (#1979, #1980, all four configs) have 0 retries, 0 asserts and 0 could-not-run in
      xfsMonkey.log, so their 328/0/0 stands.
  - libra08:tau's fix, crashmonkey ce30c4d: both reads check for end() first. libra09 has it since 11-07 as a git
    bundle, since nothing could be pushed.
- **Checks here that agree** (libra08:tau's list):
  - No "no saved snapshot" line comes before any assert, in `followup/assert_440208.txt` or anywhere in the τ-XFS
    logs.
  - In the guest dmesg, each aborted run's wrapper session logged exactly the workload's own checkpoints: two
    "hwm: making checkpoint in log" lines for the nine, and one for j-lang361324, whose workload has one. It never
    logged one more.
  - The block log's entries are not in these logs, so whether it had writes after the last checkpoint is not
    checked.
  - An earlier reading in this README, "one checkpoint more in the block log", was wrong. The three snapshot
    mappings (snapshot1 to 0, 2 to 1, 3 to 2) are the normal count for two checkpoints.
## Rerun of the 10 with the fixed harness (11-07 08:41–08:43 KST)

- Setup: `tools/crashmonkey` was moved to ce30c4d, and only c_harness was rebuilt (GPP=g++-9). The test .so files
  don't link Tester.cpp.
- Runs: `run_seq2.sh assert10` (τ) and `STOCK=1 run_seq2.sh assert10`, with the same VM and kernel #1980.

| variant | passed | failed | could not run | retries | asserts | kernel fault lines |
|---|---:|---:|---:|---:|---:|---:|
| τ-EXT4 | 10 | 0 | 0 | 0 | 0 | 0 |
| τ-XFS | 10 | 0 | 0 | 0 | 0 | 0 |
| stock ext4 | 10 | 0 | 0 | 0 | 0 | 0 |
| stock xfs | 10 | 0 | 0 | 0 | 0 | 0 |

- **The K=60 run's other results stand without a rerun.** The fix changes only what happens at end(). There the old
  harness read a garbage entry:
  - When the garbage reads as no checkpoint, it skipped the check, which is what the fixed code does.
  - When it reads as checkpoint k ≥ 1, it repeated a check of a valid checkpoint.
  - Only checkpoint 0 aborts.
  - So no other workload's verdict can differ. libra08:tau's seq-1 regression check on #397 agrees: 328/0/0 with
    unchanged per-test results.
  - An entry flagged as a checkpoint that isn't in the snapshot map would print "no saved snapshot" and count as
    Failed. There are no Failed tests.
  - The invalid ones never hit the assert. In every run (pilot, K=60, both follow-ups; τ and stock):
    - each of the 114 shows the same try pattern: its own error status, the socket error, its own error again, then
      xfsMonkey gives up;
    - none has an assert line.
  - Assert lines appear only in the τ-XFS logs of the old harness: 19 in K=60 (9 × 2 + 1) and 20 in the follow-up
    (10 × 2). There are 0 elsewhere, including stock xfs.
- **Final counts for the paper's T1 row** (seq-2 sample, 10,100 workloads per τ variant):
  - τ-EXT4: 9,986 passed, 0 failed.
  - τ-XFS: 9,986 passed, 0 failed. That is 9,976 from the K=60 run plus the 10 here.
  - On both: 114 invalid as generated, which fail the same way on stock ext4 and xfs.
  - Rule of three: the 95% upper bound on the per-workload failure rate is ≈ 0.03% (3/9,986), and 5% per op pair.

## Stock rows (11-07 14:32–17:06 KST)

`STOCK=1 run_seq2.sh k60 k60/run-1980-stock` ran the same 10,100 workloads with CrashMonkey's stock ext4 / xfs types.
- Setup: the same VM and kernel #1980, with τ compiled in but inactive. The guest's Ubuntu tools did mkfs and fsck
  (mke2fs 1.47.0, mkfs.xfs 6.6.0), as for the seq-1 stock rows.
- Harness: ce30c4d, the fixed one.
- Wall time: ext4 1.8 h, xfs 2.6 h.

**T1 seq-2 sample, all four configs:**

| config | passed | failed | invalid as generated | kernel fault lines |
|---|---:|---:|---:|---:|
| τ-EXT4 | 9,986 | 0 | 114 | 0 |
| τ-XFS | 9,986 | 0 | 114 | 0 |
| stock ext4 | 9,985 | 0 | 115 | 0 |
| stock xfs | 9,985 | 0 | 115 | 0 |

- **No failures on any config**, so τ's violations equal stock's: none, as in seq-1.
- The stock runs have 0 asserts. Each of the 115 shows its own error twice, and xfsMonkey gives up after 3 retries.
- **The extra invalid workload on stock is j-lang60585** (falloc,dwrite).
  - Its `dwrite Afoo 35768 32768` is an O_DIRECT write at an offset that isn't block aligned, so stock ext4 and xfs
    return EINVAL (`dio-unaligned` in classify.py).
  - On τ, Afoo is already a τ file (its first open carried O_TAU_UNTORN). τ journals that file's data, so direct
    I/O goes through the page cache, as with data=journal: `ext4_dio_alignment()` returns 0 for a τ inode. The
    write is valid there, and the workload passes.
  - So that workload means something different on τ and on stock. It is not a missed check.

## Files

- `sample.py`, `classify.py`, `run_seq2.sh`: the tools. `STOCK=1` and `SUMMARY_ONLY=1` modes.
- `pilot_k1/`: K=1 (169 workloads): 165 / 0 / 4 on both variants. The 4 are invalid as generated.
- `k60/`: the sample.
  - `sample.tsv`, `invalid.tsv`;
  - `cpp/`, `so/` (3.9 GB; can be rebuilt with `sample.py 60 k60`);
  - `run-1980/`: `campaign.log`, and per variant `run-<fs>.out`, `*xfsMonkey.log`, `run-<fs>.dmesg`,
    `console.log`, `could_not_run.tsv`.
  - The copies of `run_seq2.sh` and `classify.py` in `run-1980/` are the post-processing versions. The run itself
    differed only in its summary.
- `followup/`: the 124 for the follow-up, `run-1980-stock/`, `run-1980-tau/`, `assert_440208.txt`.
- `assert10/`: the 10, rerun with the fixed harness: `run-1980-tau-ce30c4d/`, `run-1980-stock-ce30c4d/`.
- `k60/run-1980-stock/`: the stock rows.
- `work/`: the Ace copy, the 466,382 j-lang files (1.8 GB) and Ace's log (237 MB).
