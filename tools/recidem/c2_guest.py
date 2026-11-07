#!/usr/bin/env python3
"""Guest side of tools/recidem/c2.sh: does τ keep a file's writes in order across a background
commit? (EVAL_PLAN oracle C2: the recovered state is a prefix of the file's write sequence.)

The file /mnt/c2/f is opened with O_TAU_UNTORN. Y is page 0 and X is page 2048 (8 MiB). W0 rewrites
pages 0-1023 (4 MiB) at once: a tx of 1,024 blocks. Below tau_cp_small_tx (512 blocks) a tx is
checkpointed at once and leaves the replay range before W2's background commit (libra08:develop,
11-08; the first runs, with a one-block W0, saw no inversion for that reason). A larger tx waits for
the 120-s age rule, or for memory or journal pressure. Every version fills its whole page with one
letter, so a read names it.

  init        pages 0-1023 = A, X = P, fsync, close. The host then umounts and mounts, so that all of
              them are home and carry no τ state.
  scenario <variant>
              On one open fd:
                W0  pages 0-1023 = B (Y among them), fsync: one tx of 1,024 blocks, so Y's newest
                    copy is in the journal only (τRedo)
                W1  Y = C, no fsync: overwriting a τRedo block takes τ's in-place path, which
                    leaves a revoke for the next user commit
                W2  X = Q, no fsync: X is clean, so it joins the running τTX
              variant fsync:  then fsync (the control: a user commit takes the revoke)
              variant bg / nowait: no fsync
              Then it writes ~/c2/ready and sleeps with the fd open, until the host kills the VM.
  read        prints "Y=<letter> X=<letter>" ("?" for a mixed page)
"""
import os, sys, time

O_TAU_UNTORN = 0o40000000
PAGE = 4096
Y, X = 0, 2048 * PAGE
W0_PAGES = 1024
PATH = '/mnt/c2/f'
HOME = os.path.expanduser('~/c2')


def put(fd, off, ch):
    assert os.pwrite(fd, ch.encode() * PAGE, off) == PAGE


def ver(fd, off):
    b = os.pread(fd, PAGE, off)
    return chr(b[0]) if len(b) == PAGE and b == b[:1] * PAGE else '?'


cmd = sys.argv[1]
os.makedirs(HOME, exist_ok=True)
if cmd == 'init':
    fd = os.open(PATH, os.O_RDWR | os.O_CREAT | O_TAU_UNTORN, 0o644)
    assert os.pwrite(fd, b'A' * PAGE * W0_PAGES, 0) == PAGE * W0_PAGES
    put(fd, X, 'P'); os.fsync(fd); os.close(fd)
    print('init done')
elif cmd == 'scenario':
    variant = sys.argv[2]
    fd = os.open(PATH, os.O_RDWR | O_TAU_UNTORN)
    t = {}
    assert os.pwrite(fd, b'B' * PAGE * W0_PAGES, 0) == PAGE * W0_PAGES
    os.fsync(fd); t['W0'] = time.time()
    put(fd, Y, 'C'); t['W1'] = time.time()
    put(fd, X, 'Q'); t['W2'] = time.time()
    if variant == 'fsync':
        os.fsync(fd); t['fsync'] = time.time()
    with open(os.path.join(HOME, 'ready'), 'w') as f:
        f.write(' '.join('%s=%.3f' % kv for kv in t.items()) + '\n')
        f.flush(); os.fsync(f.fileno())
    while True:
        time.sleep(60)
elif cmd == 'read':
    fd = os.open(PATH, os.O_RDONLY)
    print('Y=%s X=%s W0last=%s' % (ver(fd, Y), ver(fd, X), ver(fd, (W0_PAGES - 1) * PAGE)))
else:
    sys.exit('unknown command ' + cmd)
