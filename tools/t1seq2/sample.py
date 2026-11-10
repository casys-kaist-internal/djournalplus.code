#!/usr/bin/env python3
"""T1 seq-2 sample (libra09, 2026-11-06): K random ACE seq-2 workloads from each of the 169 op
pairs (all of a pair with fewer), adapted to CrashMonkey .cpp and built into .so like seq1.

  sample.py <K> <out dir>   [env SEED=20261106]

Needs work/ from the generation. work/ace is a copy of tools/crashmonkey/ace whose ace.py writes
only the j-lang files under ACE_JLANG_ONLY=1 (the adapter runs here, on the sample only):
  cd work/ace && ACE_JLANG_ONLY=1 python3 ace.py -l 2 -n False -d False   (466,382 workloads, ~1 min)
work/workload_skeleton.tsv maps each workload (j-lang<N>) to its op pair, from Ace's log.

Each pair's workloads are shuffled once (seed), and the first K that build are taken: a workload
that does not compile is invalid as generated (Ace fsyncs a file it never opened, fd_ACfoo), so
the next one of its pair replaces it. Invalid ones go to invalid.tsv. The same seed gives nested
samples (K=1 is the first workload of each pair in K=30, unless invalid).
Out: sample.tsv (N, op pair), invalid.tsv (N, op pair, error), cpp/, so/.
"""
import os, random, subprocess, sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

H = os.path.dirname(os.path.abspath(__file__))
C = os.path.join(os.path.dirname(os.path.abspath(__file__)), '../crashmonkey')
K, OUT = int(sys.argv[1]), os.path.abspath(sys.argv[2])
SEED = int(os.environ.get('SEED', '20261106'))
J = f'{H}/work/code/tests/seq2/j-lang-files'
os.makedirs(f'{OUT}/cpp', exist_ok=True)
os.makedirs(f'{OUT}/so', exist_ok=True)
subprocess.run(['cp', f'{H}/work/code/tests/seq2/base.cpp', f'{OUT}/cpp/'], check=True)  # the adapter's base

pairs = defaultdict(list)
for line in open(f'{H}/work/workload_skeleton.tsv'):
    n, sk = line.split()
    pairs[sk].append(int(n))
rng = random.Random(SEED)
order = {}
for sk in sorted(pairs):
    ids = sorted(pairs[sk])
    rng.shuffle(ids)
    order[sk] = ids

# as the seq1 rule of code/Makefile (GPP=g++-9; NEW_XATTR_INC for kernels >= 4.15); -I makes the
# tests' "../BaseTestCase.h" and "../../user_tools/..." resolve from a seq1 test's place
B = f'{C}/build'
OBJ = [f'{B}/{o}' for o in ('tests/BaseTestCase.o', 'user_tools/src/actions.o', 'user_tools/src/wrapper.o',
       'user_tools/src/workload.o', 'utils/DiskMod.o', 'utils/communication/BaseSocket.o',
       'utils/communication/ClientSocket.o', 'utils/communication/ClientCommandSender.o',
       'results/DataTestResult.o')]

def build(n):
    """'' when j-lang<n> adapts and builds, else the first error line"""
    so, cpp = f'{OUT}/so/j-lang{n}.so', f'{OUT}/cpp/j-lang{n}.cpp'
    if os.path.exists(so):
        return ''
    a = subprocess.run(['python3', f'{H}/work/ace/cmAdapter.py', '-b', 'base.cpp', '-t', f'j-lang{n}',
                        '-p', f'{OUT}/cpp/', '-o', str(n)], cwd=J, capture_output=True, text=True)
    if a.returncode or not os.path.exists(cpp):
        return 'adapt: ' + (a.stderr.strip().splitlines() or ['?'])[-1]
    b = subprocess.run(['g++-9', '-std=c++11', '-shared', '-fPIC', '-DNEW_XATTR_INC', '-I', f'{C}/code/tests/seq1',
                        f'-Wl,-soname,j-lang{n}.so', '-o', so, cpp] + OBJ, capture_output=True, text=True)
    if b.returncode:
        err = [l for l in b.stderr.splitlines() if 'error:' in l]
        return (err[0].split('error:', 1)[1].strip() if err else 'build failed').replace('\t', ' ')
    return ''

taken = {sk: 0 for sk in order}  # how far down each pair's order the sample reaches
good, bad = {}, {}
with ThreadPoolExecutor(32) as ex:
    while True:
        todo = []
        for sk, ids in order.items():
            ok = sum(1 for n in ids[:taken[sk]] if n in good)
            need = K - ok
            while need > 0 and taken[sk] < len(ids):
                todo.append((ids[taken[sk]], sk))
                taken[sk] += 1
                need -= 1
        if not todo:
            break
        for (n, sk), err in zip(todo, ex.map(lambda t: build(t[0]), todo)):
            (bad if err else good)[n] = (sk, err)
with open(f'{OUT}/sample.tsv', 'w') as f:
    for n in sorted(good):
        f.write(f'{n}\t{good[n][0]}\n')
with open(f'{OUT}/invalid.tsv', 'w') as f:
    for n in sorted(bad):
        f.write(f'{n}\t{bad[n][0]}\t{bad[n][1]}\n')
        for p in (f'{OUT}/cpp/j-lang{n}.cpp', f'{OUT}/so/j-lang{n}.so'):
            if os.path.exists(p):
                os.remove(p)
short = [sk for sk in order if sum(1 for n in good if good[n][0] == sk) < min(K, len(order[sk]))]
print(f'sample: {len(good)} workloads over {len({good[n][0] for n in good})} op pairs, K={K}, seed {SEED}; '
      f'{len(bad)} invalid replaced; pairs short of K: {len(short)} {short[:5]}')
