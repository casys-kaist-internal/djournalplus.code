#!/usr/bin/env python3
"""The outcome of every workload of a run_seq2.sh variant, and why some could not run (libra09,
2026-11-06).

  classify.py <variant dir> <sample dir>   -> <variant dir>/could_not_run.tsv; the counts on stdout

Outcomes:
  - The verdict per test comes from run-<fs>.out, copy_diff.sh's "Passed" / "Failed" / "Could not run".
  - xfsMonkey.log overrides a "Passed" for a test the harness gave up on: after four failed runs it
    says "Could not run test", but copy_diff.sh still says "Passed" when an aborted run left empty
    diff files behind.

Reasons for a workload that could not run:
  invalid as generated, on any file system: one of its own calls must fail
    rename-into-subdir        rename of a directory into its own subtree (Ace's AC is A/C): EINVAL
                              (status 5632 = 22 << 8)
    rename-onto-nonempty-dir  rename onto a directory that has entries: ENOTEMPTY (ext4, 9984) or
                              EEXIST (xfs, 4352)
    moved-away-path           an op on a path under a directory an earlier rename moved: EBADF (2304)
    falloc-negative-offset    fallocate at a negative offset: EINVAL (5632)
    msync-unaligned           an mmapwrite at an offset that is not page aligned: the adapter msyncs
                              from that address, and msync returns EINVAL (the test returns -1, 65280)
    dio-unaligned             (stock only) a dwrite, an O_DIRECT write, at an offset that is not
                              block aligned: EINVAL (5632). A τ file takes it through the page cache,
                              as data=journal does (ext4_dio_alignment() is 0 for a τ inode), so on τ
                              the workload is valid and runs
  harness-assert              c_harness aborted on Tester.cpp:790's `last_checkpoint < mods_.size() &&
                              last_checkpoint > 0`, a CrashMonkey bug (libra08:tau, 11-07): the replay
                              loop reads is_checkpoint() past log_data.end() when the block log has
                              writes after its last checkpoint, and garbage reads as checkpoint 0
  unexplained                 anything else: needs a look
"""
import glob, re, sys

vd, sd = sys.argv[1], sys.argv[2]
pair = dict(l.split()[:2] for l in open(f'{sd}/sample.tsv'))
J = sd.rstrip('/') + '/../work/code/tests/seq2/j-lang-files'
ansi = lambda s: re.sub(r'\x1b\[[0-9;]*m', '', s)
log = ansi(open(glob.glob(f'{vd}/*xfsMonkey.log')[0]).read())
out = ansi(open(glob.glob(f'{vd}/run-*.out')[0]).read())
verdict = dict(re.findall(r'Running test #\d+ : j-lang(\d+) : (Passed|Failed|Could not run) test', out))

def under(p, d):
    return p != d and p.startswith(d)

def reason(n, st, block):
    if 'Assertion `last_checkpoint < mods_.size()' in block:
        return 'harness-assert'
    ops = [l.split() for l in open(f'{J}/j-lang{n}').read().split('# run', 1)[1].split('\n') if l.strip()]
    dirs = {w[1] for w in ops if w[0] == 'mkdir'}
    for k, w in enumerate(ops):
        if w[0] == 'rename' and w[1] in dirs and under(w[2], w[1]) and '5632' in st:
            return 'rename-into-subdir'
        if w[0] == 'rename' and w[2] in dirs and ('9984' in st or '4352' in st) and \
                any(under(t, w[2]) for v in ops[:k] for t in v[1:]):
            return 'rename-onto-nonempty-dir'
        if w[0] == 'rename' and '2304' in st and any(under(t, w[1]) for v in ops[k + 1:] for t in v[1:2]):
            return 'moved-away-path'
        if w[0] == 'falloc' and len(w) > 3 and w[3].lstrip('-').isdigit() and int(w[3]) < 0 and '5632' in st:
            return 'falloc-negative-offset'
        if w[0] == 'mmapwrite' and int(w[2]) % 4096 and '65280' in st:
            return 'msync-unaligned'
        if w[0] == 'dwrite' and int(w[2]) % 512 and '5632' in st:
            return 'dio-unaligned'
    return 'unexplained'

cnr, rows, counts = set(), [], {}
for b in re.split(r'-{20}Test #\d+-{20}', log):
    m = re.search(r'Running test : j-lang(\d+)', b)
    if not m or 'Could not run test' not in b:
        continue
    n = m.group(1)
    cnr.add(n)
    st = sorted(set(re.findall(r'exits with status: (\d+)', b)))
    r = reason(n, st, b)
    counts[r] = counts.get(r, 0) + 1
    rows.append(f'j-lang{n}\t{pair.get(n, "?")}\t{",".join(st) or "-"}\t{verdict.get(n, "?")}\t{r}')
with open(f'{vd}/could_not_run.tsv', 'w') as f:
    f.write('workload\top_pair\tstatus\tcopy_diff\treason\n' + ''.join(r + '\n' for r in sorted(rows)))
# a diff found before the harness gave up still counts as a failure
fl = sum(1 for v in verdict.values() if v == 'Failed')
cnr = {n for n in cnr if verdict.get(n) != 'Failed'}
p = sum(1 for n, v in verdict.items() if v == 'Passed' and n not in cnr)
print(f'pass {p} fail {fl} could-not-run {len(cnr)} of {len(verdict)}: '
      + ' '.join(f'{k} {v}' for k, v in sorted(counts.items())))
