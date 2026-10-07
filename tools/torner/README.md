# Torner

Crash-atomicity test suite for tauJournal. Implements the T2/T3 plan in
[`CRASH_TODO.md`](../../CRASH_TODO.md); the names there (`atomicw`, `atomchk`,
`tau-loginv`, `tau-replay`, `report.py`) map onto Torner subcommands.

| CRASH_TODO | Torner | status |
|---|---|---|
| §2.1 `atomicw` | `torner gen` | done |
| §2.2 `atomchk` | `torner check` | done |
| — | `torner tear` | done (self-test for `check`) |
| §3 `tau-loginv` | `torner loginv` | parser + epochs + **I1** (on FLUSH epochs); I2–I5 not implemented |
| — | `torner atoms` | done: follows every application write through the log, FS-agnostic |
| §4 `tau-replay` | `torner replay` | 4 of 5 epoch strategies + `torn-entry`; write-aimed `atom-order`/`atom-reorder`/`atom-tear`; `targeted` not implemented |
| §6 `report.py` | `scripts/report.py` | Table 1, per-write table, write shapes, state coverage; T1/T3 tables have no input |
| §2.5 VM loop | `scripts/capture.sh`, `scripts/explore.sh` | done |
| — | `scripts/fuzz.py` | input-surface fuzzing (① below), coverage = write shapes |

```sh
make && make test
```

No configure step and no dependencies beyond libc and pthreads — Torner is
built inside the guest as often as on the host.  The harness scripts need
`python3` (standard library only).

The first validation run on real captures — what tore, under which crash
model, with reproducible witnesses and all the raw records — is in
[`results/2026-09-23/ANALYSIS.md`](results/2026-09-23/ANALYSIS.md) (Korean).
It is a snapshot for validating the tool, not paper numbers.

## What Torner verifies, and how

**The property.**  An application issues `pwrite(fd, buf, S, off)` — 16 KiB by
default, 64 KiB just as well — followed by `fsync(fd)`.  After *any* crash the
device can legally produce, and after the file system's recovery, those S bytes
must read back entirely old or entirely new.  That has to hold under every
combination the application can reach: N threads, overwrite, append,
fallocate, delalloc, and whatever else the file system happens to be doing at
the time.

**The burden is asymmetric.**  Showing that a file system does *not* provide
this needs one witness: a log plus a state spec that rebuilds a torn write,
which anyone can replay.  Finding one needs no knowledge of the file system's
internals — generate workloads, look at what reaches the device, crash where it
matters.  Showing that tauJournal *does* provide it is a universal claim, and
no amount of black-box testing makes it one.  So the two get different
treatment:

| | baseline file systems | tauJournal |
|---|---|---|
| goal | one reproducible tear | argue that no tear exists |
| evidence | a `state_spec` that replays to a torn unit | the design argument, plus every layer below |
| I1 over every transaction in the log | — | exhaustive (`loginv`) |
| how every write reached the device | exhaustive (`atoms`) | exhaustive (`atoms`) |
| crash states at every split point | targeted (`atom-*`) | targeted (`atom-*`), no budget |
| input surface | fuzzing, until the first witness | fuzzing, to the budget |

**The general core never looks inside the file system.**  Every sector `gen`
writes says which application write it belongs to (below).  So each write
W = (page, version) can be followed through the `dm-log-writes` stream by
content alone: the in-place write, a journal copy, a checkpoint, a
copy-on-write relocation, even a copy embedded unaligned inside a log record
(the ZFS ZIL does this) is found, CRC-verified, and pinned to the log entry
that carried it.  What matters is where W's sectors *first* reach the device:

- **one entry** — W travelled as one bio.  Only a device that tears a bio can
  split it (model T below).
- **several entries** — W travelled in pieces.  A crash between the pieces
  leaves part of W on disk, and only the file system's recovery stands between
  that and a torn unit.  Whether the pieces fall in one flush window or across
  a `FLUSH` decides which crash models can separate them.

Crash states are then placed between *every* two log entries that carry a copy
of W, not only its first: a journal copy and its checkpoint, or a log record
and the in-place write it is replayed into, are exactly where recovery has to
put things right.

This is how `ext4 data=journal` loses atomicity without anyone breaking a
rule: its data goes through the journal page by page, so a *commit-induced
split* — a commit not caused by W's own `fsync` (another thread's `fsync`, the
JBD2 commit timer, journal pressure, `sync`, writeback) — can close a
transaction with half of W in it.  The core sees only the consequence, W in two
pieces with a `FLUSH` between them, and that is enough to aim a crash there.
File-system-specific knowledge (journal layout, commit blocks) is an optional
accelerator — `loginv` uses it for I1 — never a prerequisite.

**What the log does and does not order.**  The crash models are only as good as
this, so it was read out of `drivers/md/dm-log-writes.c` rather than assumed:

- A plain write is logged when a `FLUSH` that was *submitted after it
  completed* completes: completed writes wait on a list, a `FLUSH` takes the
  list when it is submitted and logs it, then itself, when it completes.  So a
  plain write logged before a `FLUSH` entry is durable once that entry is.
- A `FUA` write is logged at its own completion, and a mark at the moment it is
  sent.  So each window reads `[FUA writes and marks][plain-write batch][FLUSH]`.
- **`FUA` is not a barrier.**  It makes only its own data durable.  Treating it
  as one — as CrashMonkey's permuter does, and as an earlier version of `loginv`
  did — lets a commit issued without a preflush look correctly ordered whenever
  an unrelated `FUA` write happens to fall between it and its data.  Torner
  therefore keeps two epoch counters: `fepoch` splits on `FLUSH` alone and
  decides durability; the legacy `epoch` also splits on `FUA` and survives only
  in the epoch-based strategies.

**Crash models.**  Every state the `atom-*` strategies emit is legal under the
log order above, and each says which model it needs (`"model"` in the JSON):

| model | state | legal because | strategy |
|---|---|---|---|
| **O** in-order prefix | `entry<=c` | a crash can happen after any completed entry | `atom-order` |
| **R** reordered cache | `entry<=c,drop=[…]` | a plain write after the last `FLUSH` before `c` is still in the volatile cache | `atom-reorder` |
| **T** torn bio | `entry<=j,partial=[j:k]` | a device commits in atomic units (4 KiB), not bios, so the bio in flight lands up to a unit boundary | `atom-tear` |

O assumes nothing about the device; R assumes a volatile write cache that
honours `FLUSH`; T also assumes a device that honours `FLUSH` but may tear a
multi-unit bio.  None of them breaks a `FLUSH`: a mechanism that needs a device
to lie about one cannot be reproduced here (see the last sections).  Two legal
states are not expressed: one where a batch write is durable but a `FUA` write
logged earlier in the same window is not, and — for I1 — a `FUA` commit
submitted concurrently with, rather than after, a `FLUSH`.  Commits issued
`PREFLUSH|FUA` are sequenced by the block layer and are not affected.

**Exhaustive versus sampled.**  `atoms` classifies every application write in
the log, and reports how many states each strategy needs to cover all of them.
`atom-order` places a crash between every two log entries carrying a copy of
each write, plus the barriers up to the one after its last copy (capped per
write); `atom-reorder` drops every earlier such entry still volatile at every
later one; `atom-tear` cuts every copy of every write at every device-unit
boundary inside it.  Only replaying the states
is budgeted, and the budget samples *writes*, never a subset of one write's
cuts — so the result reads "writes torn / writes tried" with a Wilson interval,
and a clean run of n writes bounds the tear rate at about 3/n (rule of three),
not at zero.  Hunting a witness is a different goal from estimating a rate:
`--prefer-split` spends the budget on the shapes most likely to tear first
(split across a `FLUSH`, then partial, then split within a window, then one
bio), at random within each.  Every target carries its shape, and the report
then reads rates per shape — the overall rate of a skewed sample means
nothing.

**① Input-surface fuzzing.**  The states above only explore the writes a
workload happened to produce.  Which splits occur at all depends on the input:
thread count, unit size, mode, `fsync` policy, `O_DIRECT`, and the interference
that causes foreign commits — another file's `fsync`, a `sync`, writeback
catching a unit halfway through its copy.  `torner gen` runs that interference
on the side with plain POSIX calls (`--other-fsync-ms`, `--sync-ms`,
`--writeback-ms`), and `scripts/fuzz.py` is a coverage-guided loop over all of
these knobs.  The coverage signal is the set of write-shape signatures `atoms`
reports — class, pieces, log entries, `FLUSH`es spanned, flags — with
AFL-style count buckets.  A configuration that produces a shape not seen
before joins the corpus, and states are aimed at exactly the writes whose
shapes gave the new coverage (`replay --signatures`), split writes first.
File-system-specific knobs (the ext4 commit interval, journal size, ZFS
`logbias`) belong in it only as optional accelerators, and none is needed.

**For tauJournal, in-progress numbers are snapshots.**  Its recovery path is
still being patched; results from it describe a kernel build, not the design.

## The oracle

`check` judges a recovered file on its own, with no golden image to diff
against. That is the one design decision everything else follows from, and it
is what separates Torner from the CrashMonkey layer (T1): a diff oracle needs a
deterministic single-threaded workload to compare against, so it cannot run 32
concurrent writers, and it cannot see data atomicity at all — only that two
disks differ.

Every 4 KiB sector carries `{magic, page_id, version, sector_idx, crc32, run_id}`
followed by a deterministic body derived from `(page_id, version, sector_idx,
run_id)`. So:

- **P1 (atomicity)** — the sectors of one 16 KiB unit must agree on a version.
  Disagreement is a tear. The body is checked against the version its own
  header claims, which catches the sub-sector case where a header picked up the
  new version while its payload stayed old; version comparison alone would call
  that unit clean.
- **P2 (durability)** — `gen` appends `{page_id, version}` to the progress log
  only *after* `fsync()` returns, so the log is a lower bound on what must
  survive. A file version older than a logged one is a violation. A record lost
  because the crash landed between `fsync()` returning and the append is not.

`check` classifies each unit as intact / absent / torn, and reports violations
with `page_id` and the versions actually observed — enough to go straight to
the block in question.

## Devices

Three roles. They need not be separate physical disks, but they must be
separate block devices:

| role | what it is | constraint |
|---|---|---|
| backing | the FS under test, under `dm-log-writes` | **must advertise a write-back cache** |
| log | `dm-log-writes` log device | sized for the run (see CRASH_TODO §4.6) |
| progress | `--progress-log` target | **never under the stack being tested** |

The progress-log rule is not stylistic. If the log lives on the file system
under test, the same crash that loses a write can lose the record of it, and
"the write vanished" becomes indistinguishable from "the evidence vanished" —
the oracle would be judging tearing with a possibly-torn log. It also pollutes
the `dm-log-writes` stream that `loginv` parses.

The write-back requirement is the sharper trap. `dm-log-writes` tags entries
`LOG_FLUSH_FLAG`/`LOG_FUA_FLAG` from the incoming bio
(`drivers/md/dm-log-writes.c`), but if the underlying device advertises no
write cache, 6.8's `submit_bio_noacct()` strips `REQ_PREFLUSH`/`REQ_FUA` before
the target ever sees them. Every entry then reads `flags == 0`, the whole log
collapses to a single epoch, and the invariant checks become vacuous — while
still reporting success. This already happened once in this tree with
CrashMonkey's `cow_brd`; see `tools/crashmonkey/docs/tau.md` §7.2, which also
measured `/dev/nvme0n1` (the passthrough NVMe) reporting `write through`. Use a
file-backed virtio disk with `cache=writeback`, not a ramdisk and not the raw
NVMe, and verify in the guest:

```sh
cat /sys/block/vdb/queue/write_cache     # must read "write back"
```

## `torner gen`

```
torner gen --file <path> --progress-log <path> [options]

  --unit 16384          application atomic unit; one unit == one pwrite()
  --sector 4096         sector within a unit
  --threads 4           writer threads
  --mode overwrite      overwrite|append|alloc|delalloc|mixed
  --duration 60         seconds (0 = until pages exhausted)
  --pages 65536         atomic units in the file
  --fsync-every 1       fsync every k writes (0 = never)
  --run-id <u64>        stamped into every sector [time-derived]
  --seed <u64>          access order
  --progress-direct     open the progress log O_DIRECT (raw device)
  --direct              open the target O_DIRECT
  --fdatasync           fdatasync() instead of fsync()

  interference on the side while the writers work (0 = off):
  --other-fsync-ms <n>  write + fsync() a sibling file every n ms
  --sync-ms <n>         sync() every n ms
  --writeback-ms <n>    sync_file_range(WRITE) the target every n ms
```

Modes map onto the tauJournal operation classes:

| mode | file is | the write does |
|---|---|---|
| `overwrite` | prefilled, allocated | pure in-place rewrite, no allocation |
| `append` | empty | grows `i_size` (Data-Inode) |
| `alloc` | `fallocate`d | unwritten → written extent conversion |
| `delalloc` | sparse (`ftruncate`) | delayed allocation at writeback |
| `mixed` | prefilled | rewrite and allocation interleaved |

Page ownership is partitioned across threads (`page_id % threads == tid`) so a
page's version is only ever advanced by one writer. Without that, two writers
racing on one page would make "the sectors disagree" ambiguous between a tear
and a legal interleaving, and P1 would be unusable.

`append` is the exception: pages come from one monotonic counter so the file
genuinely grows, and each page is written once at version 1. With `--threads`
> 1 this is a *concurrent extend* rather than a strict serial append — writes
can complete out of order and leave transient holes past `i_size`. That is the
harder case and the intended one, but it is not the same workload as a
single-threaded `write()`-at-EOF loop.

## `torner check`

```
torner check --file <path> [--progress-log <path> [--progress-limit N]]
             [--run-id <u64>] [--focus-file <path>]
             [--tier T2b] [--config tau-ext4] [--workload ...]
             [--run-tag ...] [--state-id ...] [--strategy ...] [--epoch N]
```

Emits one CRASH_TODO §2.4 JSONL record on stdout. `p3`/`p4` are reported `n/a`
— fsck and application recovery are the harness's job, and it fills those in.

`--progress-limit` bounds P2 for a replayed state: only progress records below
that slot were durable at the crash point (`replay` reports the bound as
`progress_limit`).  Without it the progress log, which lives outside the stack
and survives whole, would make every write past the cut look lost.

`--focus-file` takes `page version` lines — the targets of an `atom-*` state —
and judges each write on its own, under `"focus"`: `new` (whole at this version
or later), `old` (whole at an earlier one: the write rolled back, which is
atomic), `absent`, or listed under `torn` with the kind and the versions seen.
The global P1 flag cannot answer this: other writes in flight at the same crash
point may tear too.

Exit: `0` pass, `2` violation, `1` error.

Note the two different run identifiers. `--run-id` is the u64 stamped into the
data, and must match the value `gen` used; it is what rejects a stale previous
run's bytes. `--run-tag` is the harness's label for the JSONL `run_id` field,
and defaults to the numeric `--run-id`.

## `torner loginv`

```
torner loginv --log <logdev> [--config tau-ext4|tau-xfs|ext4-data]
              [--check I1] [--fsblock 4096] [--stat-only]
```

Parses a `dm-log-writes` log and decides ordering invariants without crashing
anything. That is the point: probabilistic replay can miss a missing barrier,
because most replays of a barrier-less stream still land in a legal order by
accident. Reading the log settles it.

**I1** — every block a transaction commits must be durable before its commit
block can be.  "Durable before" is decided by `FLUSH` alone: a block is
guaranteed on media ahead of its commit iff a `FLUSH` lies between them (the
commit is in a later *flush epoch*), or the block itself was written `FUA`.
Violations report the sequence, both LBAs, both flush epochs, the log entry
indices, how many blocks the transaction spans, and `"epoch_model":"flush"`.

An earlier version split epochs on `FUA` as well, as CrashMonkey's permuter
does.  That is wrong — `FUA` makes only its own data durable — and it is not a
harmless simplification: any unrelated `FUA` write that happens to land between
a transaction's data and a commit issued without a preflush (a journal
superblock update, say) then makes the commit look ordered.  `make test`
includes exactly that log (`fua-not-flush`) and requires I1 to fire.  What the
log cannot show is submission order: a `FUA` commit issued concurrently with a
`FLUSH`, rather than after it completed, is logged the same way.

Two things about identifying tau's blocks are not obvious, and both were learned
from a real capture rather than from the headers:

- **jbd2 uses the same magic** (`0xc03b3998`, which tau inherited) and the same
  block types 1 and 2; its commit header even agrees with tau's out to
  `h_commit_sec`. On a tau-ext4 stack both journals are in the stream and no
  amount of header shape tells them apart. They are separated by LBA instead:
  pass 1 finds the tau superblock — identified by `s_segment_size`, the one
  field jbd2 leaves zero — and reads the segment map that follows it to learn
  where the journal's segments physically live. Blocks carrying the magic
  outside those extents are counted as `foreign_magic_blocks` and never
  asserted on.
- **A transaction is a chain of descriptors, not one descriptor plus tags.**
  Each descriptor is followed by the data blocks its tags name, all sharing one
  sequence, closed by a single commit. So the extent is `[first descriptor of
  that sequence, commit)`. Sizing it from one descriptor's tag count instead
  reports the whole log as broken: a descriptor whose tag list is exhausted
  reads as 406 tags — the maximum a 4 KiB block can hold — and the range then
  swallows unrelated transactions.

The tau on-disk constants come from `include/tau_ondisk.h`, which transcribes
them from the kernel with a file:line citation per value — CRASH_TODO §9 forbids
copying them from prose.

Two honesty properties matter more than coverage here:

- A log with **no FLUSH/FUA entries at all** is reported `"usable": false` and
  exits 1 rather than passing. Every ordering check would be vacuous on a
  single-epoch log, and a clean verdict there is worse than an error. Use
  `--stat-only` as a preflight after the first real capture.
- A log with **no tau journal in it** is likewise refused. This is not
  hypothetical: `-o tjournal` enables tau but files opt in individually, so a
  workload that does not pass `O_TAU_UNTORN` (or mount `tjournal_all`) produces
  a log where tau journalled nothing — dmesg ends with "[tau_commit_all] But no
  transaction to commit" — while every tau invariant "passes". `torner gen
  --untorn` is what makes tau engage.
- Invariants that are not implemented report `"not_implemented"`, never
  `"pass"`. Transactions that could not be reconstructed (multi-segment ones,
  where `h_next_segment` is non-zero and the linear layout no longer holds) are
  counted in `coverage.i1_transactions_skipped` rather than dropped silently,
  and `coverage.i1_blocks_examined` says how much was actually looked at. On the
  first real tau capture these read 0 checked / 425 skipped: a clean exit code
  that had inspected nothing. Without those counters it would have read as a
  pass.

`make test` checks these cases against synthetic logs built by
`tests/mklog.py`: a well-ordered log passes, a log whose commit shares a flush
epoch with its own data trips I1 — with or without an unrelated `FUA` write in
between — and a flagless log is refused. CRASH_TODO §3.7 asks
for a barrier-stripped kernel build to prove I1 fires — that proves the kernel.
To prove the *checker*, a log constructed to violate I1 is better evidence,
because we know exactly what is wrong with it.

## `torner atoms`

```
torner atoms --log <logdev> [--run-id <u64>] [--examples 8] [--atom 4096]
             [--config ext4] [--workload torner:overwrite:t4]
```

Follows every application write through the log and reports how it reached the
device, with no knowledge of the file system (see *What Torner verifies*
above).  `capture.sh` runs it after every capture and keeps the result as
`atoms.json`.

- `writes` — application writes found, split into `setup` (version 0, the
  prefill) and `workload`.
- `shape` — for the workload writes: `one_bio`; `split_window` (pieces in one
  flush window); `split_flush` (a `FLUSH` between pieces: part of the write is
  durable before the rest is issued); `partial` (some sectors never reached
  the device, e.g. the capture ended first); `reorderable` (an earlier piece is
  still volatile when a later one is logged); `embedded_first_copy`; and
  `single_entry` (one log entry carries W in total, so only tearing it can
  break it); and histograms of pieces and of all log entries touched, later
  copies included.
- `plans` — for each `atom-*` strategy, the writes it has states for and how
  many distinct states covering all of them takes.  Computed by running the
  planners, so they are exactly what `replay --enumerate` would produce with no
  budget.  Structural facts, not verdicts: whether recovery leaves a write
  torn is for `explore`.
- `scan` — bytes scanned, sector copies found, magic matches rejected by the
  CRC/fill check.  A clean result is only meaningful next to these: zero split
  writes out of zero found is a blind scan, not a pass.
- `examples` — a few split writes, piece by piece, with each piece's entry,
  flush epoch, sector mask and `FUA` flag.

## `torner replay`

```
# enumerate the states a strategy produces
torner replay --log <logdev> --enumerate --strategy prefix|single-drop|reverse|random-subset|torn-entry
              [--samples 4] [--seed 1] [--atom 4096]
torner replay --log <logdev> --enumerate --strategy atom-order|atom-reorder|atom-tear
              [--run-id <u64>] [--max-states N] [--seed 1] [--atom 4096]
              [--per-atom-barriers 32] [--first-copy-only] [--prefer-split]

# build one of them
torner replay --log <logdev> --target <image> --state-spec 'epoch<=1421,drop=[93820]'
```

xfstests' `replay-log` only does prefixes; exploring the crash-state space
needs arbitrary subsets of an epoch. The spec grammar is
`epoch<=N`, `entry<=N`, `drop=[i,j,…]`, `reverse=N`, `partial=[i:k]` (entry `i`
lands only in part, its first `k` log sectors), comma-separated.

The epoch-based strategies walk the log epoch by epoch.  The `atom-*`
strategies instead start from the application writes `atoms` found and place
states where each one can break — the crash models O, R and T described above.
Each state they emit carries `"model"`, the entry it crashes after
(`crash_entry`), its flush epoch, and `"targets"`: the writes it is aimed at, so
the harness can ask `check --focus-file` about exactly those.

- `atom-order` — for each write carried by more than one log entry, the crash
  right before each later entry (the most that can be durable without it),
  plus every barrier from its first copy to the one after its last, at most
  `--per-atom-barriers` of them: recovery decides visibility at commit points,
  and a write fully on the device can still come back torn if recovery replays
  one of its transactions and not the other.
- `atom-reorder` — at each later entry carrying the write, drop each earlier
  one that is still volatile, then all of them together.
- `atom-tear` — cut every copy of every write (journal copies and checkpoints
  included) at each device-unit boundary strictly inside it.
  `--first-copy-only` restricts this to where the write first lands.

`--max-states` samples whole writes in a seeded order until their states reach
the budget; a write is tried at all of its states or at none.  `--prefer-split`
orders them by shape first (see above).  Each state lists its targets' shapes
under `"shapes"`.  Coverage goes to stderr — how many states, how many writes
were eligible, how many targeted.

The spec is both the name of a state and the recipe for rebuilding it: the same
spec against the same log produces a byte-identical target (CRASH_TODO §4.7).
That is what lets a violation in the JSONL be handed to a reviewer as something
they can reconstruct rather than a number. `state_id` digests the spec together
with the log's identity, so the same spec against a different log does not
silently collide.

`--target` is written **in place and never truncated**. The harness gives
replay a copy of the base image — the device as it was before the workload
began — and replay lays the selected entries on top. Blocks the log never
touched keep their base content; zeroing the target instead would hand every
oracle a blank disk.

`targeted` — the strategy CRASH_TODO §4.4 calls the important one, which forces
a state where a commit block is durable but its data is not — **refuses to
run**. It needs commit blocks and their data blocks identified in the log,
which is `loginv`'s job and is not wired up yet. Enumerating something weaker
under that name would quietly hollow out the strongest claim in the plan.

## The harness

```sh
# once per configuration: build the stack, run the workload, keep the artifacts
# (and atoms.json: how each application write reached the device)
scripts/capture.sh --workdir DIR --fs ext4|ext4-data|xfs|tau-ext4|tau-xfs|zfs \
                   [--threads 4 --unit 16384 --gen-args "--other-fsync-ms 5"]

# then, offline and in parallel: rebuild crash states and judge each one
scripts/explore.sh --capture DIR --strategy torn-entry --limit 100 --jobs 8
scripts/explore.sh --capture DIR --strategy atom-order --limit 200 --jobs 8

# and finally
scripts/report.py DIR/states-*.jsonl --atoms DIR/atoms.json
```

The input surface is explored by `scripts/fuzz.py`, which drives the two
scripts above in a loop:

```sh
# a baseline file system: stop at the first reproducible tear
scripts/fuzz.py --fs ext4-data --workdir /mnt/scratch/fuzz-ed --iterations 30 --stop-on-witness

# tauJournal: run to the budget and report every shape reached
scripts/fuzz.py --fs tau-ext4 --workdir /mnt/scratch/fuzz-tau --time-budget 7200
```

It keeps `fuzz.jsonl` (per iteration: configuration, new coverage, shapes,
witnesses), `witnesses.jsonl` (each torn write with the capture directory and
`state_spec` that reproduce it) and `corpus.json` (configurations kept, coverage
reached; a rerun resumes from it).  Captures that taught nothing have their
images deleted; `--keep-all` keeps them.  `--dry-run` prints the first
iteration's commands.

For `atom-*` states `explore.sh` hands each state's targets to `check
--focus-file`, and the record keeps `targets` and `targets_torn` next to the
verdict.  `report.py` turns those into a per-write table — writes torn out of
writes tried, per crash model, with a Wilson interval; a write reached only by
states that did not mount is counted as unjudged, never as intact.  Records are
assembled by `scripts/state_tool.py`, not by `sed` on JSON.

`explore.sh` must run in the guest: every state is a deliberately damaged file
system, and mounting one can take the kernel down.

Two things the harness learned the hard way and now handles:

- **P3 is judged against a pristine baseline, not against a zero exit code.**
  The tau-aware `mke2fs` puts the tau journal at reserved inode 9, and `e2fsck`
  calls that "Reserved inode 9 has invalid mode" on an image that was just
  formatted and never mounted. Judged by exit code, *every* state reports as
  dirty — which reads like a catastrophic finding and is really a property of
  mkfs. `capture.sh` records what fsck says about the fresh filesystem and
  `explore.sh` fails P3 only on something new.
- **States before the first progress mark are skipped** by the epoch-based
  strategies.  Those predate the workload — they are mkfs and file prefill, do
  not carry a formed filesystem yet, and would fill the sample with mount
  failures.  `atom-*` states are aimed at workload writes and need no such
  filter; one that falls before the first mark is judged without P2, since no
  `fsync` had returned to hold it to.

## Epoch-based persistence models, and why there are two

`single-drop` and friends assume any subset of *bios* may persist. That is the
standard model, the one CrashMonkey's permuter uses. It is also, on its own,
unable to show an ext4 or XFS tear: measured on a real capture, 767 of 768
application 16 KiB writes reach the log as a **single 16384-byte entry**, so
dropping one removes all four blocks together. Whole write gone is not a tear.

`torn-entry` models the layer below: a bio larger than the device's atomic unit
(`--atom`, 4 KiB by default — an SSD commits logical blocks, not 16 KiB bios)
may persist in part. This is strictly the stronger assumption and it is stated
in the output rather than buried, because it is the obvious thing for a reviewer
to push on.

`ext4 data=journal` needs neither: its data reaches the log as **4 KiB entries**,
so the application's atomic unit is already spread across several entries, and
a crash between them tears it whenever a commit separates them — the
commit-induced split described at the top.  Epoch-based strategies find such
a state only by chance; the `atom-*` strategies aim at every one of them.

## What the persistence models do and do not cover

The epoch-based strategies treat a `FLUSH` or `FUA` entry as a barrier:
everything before it is durable.  For `FUA` that under-approximates — it never
drops a plain write that only a `FUA` separates from the crash — but every
state it does produce is legal.  The `atom-*` strategies treat only `FLUSH` as
a barrier (model R drops exactly what is still volatile).  `torn-entry` and
`atom-tear` tear exactly one bio, the last one in the state.  All of them take
a completed `FLUSH` at its word.  That bounds what can be reproduced, and the
bound matters when a run comes back clean.

Concretely, a **clean result is not proof of correctness** for any mechanism
that needs a device to break a barrier. If hardware completes a flush and still
leaves an earlier write half-written, no state this harness enumerates will
show it.

The ZFS measurements are the live example. Every ZFS capture uses `FLUSH`
exclusively and never `FUA` (369/0, 371/0, 411/0 across three captures), and
its commit protocol is data blocks → flush → uberblock → flush. Under an
honest flush, a block the uberblock points at is already whole; copy-on-write
puts a torn new block somewhere the old record does not depend on, and the
checksum catches it if the pointer did move. So:

| config | app write spans >1 bio | subset of bios | partial bio |
|---|---|---|---|
| zfs (128K default) | 0% (max 2 bios) | 0/49 | 0/50 |
| zfs-16k | **0% (max 1 bio)** | 0/50 | 0/50 |
| zfs-8k | 13% (max 2) | 0/39 | 0/40 |
| zfs-4k | 29% (max 4) | 0/40 | 0/40 |

At `recordsize=16k` the application's 16 KiB write and the ZFS record coincide
exactly — one record, one allocation, one bio — and tearing that bio in half
still does not produce a torn unit.

A tear has been reported for exactly this configuration, attributed to the ZIL
sitting on a txg boundary. This harness does not reproduce it. That outcome is
equally consistent with "fixed since" and with "still real but outside the
model", and **these numbers cannot tell those apart**. Two things would:

- whether `logbias` was `throughput` rather than the `latency` default. At
  `latency` with `zfs_immediate_write_sz=32768`, a 16 KiB write is below the
  threshold and its data is copied into the ZIL (`WR_NEED_COPY`); at
  `throughput` it becomes `WR_INDIRECT`, where the ZIL holds only a pointer and
  the data goes to its final location. Different code path, different exposure.
- whether the original observation came from a real power cut rather than a
  replay.

Do not cite the zeros above as "ZFS does not tear".

## `torner tear`

Deliberately damages one unit, so the oracle can be seen to fire:

```sh
torner tear --file <path> --page <id> [--sectors 1] [--kind version|blank|bitflip]
```

CRASH_TODO §3.7 makes this point about the invariant checker, and it applies
just as hard here — an oracle that has never been observed to fire cannot be
distinguished from one incapable of firing. `make test` uses `tear` to assert
that each damage shape produces its own specific verdict, and that truncation
trips P2 *without* tripping P1 (so the oracle is not collapsing every fault
into one answer).
