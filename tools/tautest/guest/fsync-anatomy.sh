#!/bin/bash
# What one fsync costs in device round trips: every block request issued and
# completed between sys_enter_fsync and sys_exit_fsync, from ftrace.  A
# "phase" starts when a request is issued with none outstanding -- the fsync
# waited for the previous ones before it could send this one.
#
#   usage: fsync-anatomy.sh <ext4|xfs> <vanilla|tau> <overwrite|append> [fsyncs] [pages-per-fsync]
#
# overwrite: a 64 MiB file of 8 KiB pages, fsync'd, then rewritten at random
#            (a warm-up of the same length first, so tau is in its steady
#            redo/undo cycle); append: 8 KiB pages added at EOF.
# WARNING: runs mkfs on $TAU_DEV.

cd "$(dirname "$0")" || exit 1
. ./common.sh

FS=${1:-}; MODE=${2:-}; PAT=${3:-}; N=${4:-200}; K=${5:-1}
case "$FS/$MODE/$PAT" in
ext4/vanilla/*|ext4/tau/*|xfs/vanilla/*|xfs/tau/*) ;;
*) die "usage: $0 <ext4|xfs> <vanilla|tau> <overwrite|append> [fsyncs] [pages]" ;;
esac
case "$PAT" in overwrite|append) ;; *) die "pattern: overwrite or append" ;; esac
T=/sys/kernel/tracing
F=$TAU_MNT/anatomy.dat
OUT=${OUT:-/tmp/anatomy-$FS-$MODE-$PAT}

sudo umount "$TAU_MNT" 2>/dev/null || true
sudo mkdir -p "$TAU_MNT"
case "$FS/$MODE" in
ext4/vanilla) sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1 &&
	      sudo mount -t ext4 "$TAU_DEV" "$TAU_MNT" ;;
ext4/tau)     sudo "$MKE2FS" -t ext4 -F -E lazy_itable_init=0 "$TAU_DEV" >/dev/null 2>&1 &&
	      sudo mount -t ext4 -o tjournal,tjournal_size=32 "$TAU_DEV" "$TAU_MNT" ;;
xfs/vanilla)  sudo "$MKFS_XFS" -f "$TAU_DEV" >/dev/null 2>&1 &&
	      sudo mount -t xfs "$TAU_DEV" "$TAU_MNT" ;;
xfs/tau)      sudo "$MKFS_XFS" -f -l tjmaxsize=1G "$TAU_DEV" >/dev/null 2>&1 &&
	      sudo mount -t xfs -o tjournal "$TAU_DEV" "$TAU_MNT" ;;
esac || die "mkfs/mount failed"

# the request's dev is the disk's, which need not be the node's minor: take the major
MAJ=$(( 0x$(stat -c %t "$TAU_DEV") ))
DEVF="dev >= $((MAJ << 20)) && dev < $(((MAJ + 1) << 20))"
FLAG=0; [ "$MODE" = tau ] && FLAG=0o40000000

# the workload: setup and warm-up untraced, then $N traced fsyncs
cat > /tmp/anatomy.py <<'EOF'
import os, random, sys, time
path, pat, n, k, flag = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5], 0)
PG, SIZE = 8192, 64 << 20
page = os.urandom(PG)
fd = os.open(path, os.O_RDWR | os.O_CREAT | flag, 0o644)
if pat == "overwrite":
    for off in range(0, SIZE, 1 << 20):
        os.pwrite(fd, os.urandom(1 << 20), off)
    os.fsync(fd)
    def one():
        for _ in range(k):
            os.pwrite(fd, page, random.randrange(SIZE // PG) * PG)
        os.fsync(fd)
    for _ in range(n):
        one()
else:
    def one():
        for _ in range(k):
            os.write(fd, page)
        os.fsync(fd)
time.sleep(2)
open("/tmp/anatomy.go", "w").close()
while os.path.exists("/tmp/anatomy.go"):
    time.sleep(0.05)
for _ in range(n):
    one()
os.close(fd)
EOF

sudo sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo 65536 > $T/buffer_size_kb;
	echo '$DEVF' > $T/events/block/block_rq_issue/filter;
	echo '$DEVF' > $T/events/block/block_rq_complete/filter;
	echo 1 > $T/events/block/block_rq_issue/enable;
	echo 1 > $T/events/block/block_rq_complete/enable;
	echo 1 > $T/events/syscalls/sys_enter_fsync/enable;
	echo 1 > $T/events/syscalls/sys_exit_fsync/enable"
rm -f /tmp/anatomy.go
sudo python3 /tmp/anatomy.py "$F" "$PAT" "$N" "$K" "$FLAG" &
py=$!
while [ ! -e /tmp/anatomy.go ]; do sleep 0.2; kill -0 $py 2>/dev/null || die "workload died"; done
sudo sh -c "echo 1 > $T/tracing_on"
sudo rm -f /tmp/anatomy.go
wait $py || die "workload failed"
sudo sh -c "echo 0 > $T/tracing_on; cat $T/trace > $OUT.trace;
	echo 0 > $T/events/enable; echo 0 > $T/events/block/block_rq_issue/filter;
	echo 0 > $T/events/block/block_rq_complete/filter"

DUMP=${DUMP:-0} python3 - "$OUT.trace" "$FS $MODE $PAT, $K page(s) per fsync" <<'EOF'
import re, statistics, sys
head = re.compile(r'^\s*(.+)-(\d+)\s+\[\d+\]\s+\S+\s+(\d+\.\d+): (.*)$')
rq = re.compile(r'^(block_rq_issue|block_rq_complete): \d+,\d+ (\S+) (?:\d+ )?\(.*?\) (\d+) \+ (\d+)')
wins, cur = [], None
for line in open(sys.argv[1]):
    m = head.match(line)
    if not m:
        continue
    comm, pid, ts, rest = m.group(1).strip(), int(m.group(2)), float(m.group(3)), m.group(4)
    if rest.startswith('sys_fsync('):
        cur = {'t0': ts, 'pid': pid, 'order': []}
    elif rest.startswith('sys_fsync ->'):
        if cur and pid == cur['pid']:
            cur['t1'] = ts
            wins.append(cur)
        cur = None
    elif cur:
        r = rq.match(rest)
        if r:
            cur['order'].append((r.group(1) == 'block_rq_issue', r.group(2), int(r.group(4)), int(r.group(3)), ts))
def is_flush(rwbs):	# blk-flush's own request: REQ_OP_FLUSH | REQ_PREFLUSH
    return rwbs in ('F', 'FF') or rwbs.startswith('FF')
def is_fua(rwbs):
    w = rwbs.find('W')
    return w >= 0 and rwbs[w + 1:w + 2] == 'F'
lat, ios, phases, kb, kinds, fl, fua = [], [], [], [], {}, [], []
for w in wins:
    out, n, ph, sect, nf, nu = 0, 0, 0, 0, 0, 0
    for issue, rwbs, nr, sector, ts in w['order']:
        if issue:
            if out == 0:
                ph += 1
            out += 1
            n += 1
            sect += nr
            nf += is_flush(rwbs)
            nu += is_fua(rwbs)
            kinds[rwbs] = kinds.get(rwbs, 0) + 1
        else:
            out = max(0, out - 1)
    lat.append((w['t1'] - w['t0']) * 1e6)
    ios.append(n); phases.append(ph); kb.append(sect / 2); fl.append(nf); fua.append(nu)
if not wins:
    print("no fsync windows traced"); sys.exit(1)
import os
for w in wins[:int(os.environ.get('DUMP', '0'))]:
    print("  -- fsync at %.6f, %.0f us" % (w['t0'], (w['t1'] - w['t0']) * 1e6))
    for issue, rwbs, nr, sector, ts in w['order']:
        print("     %+7.1f us %-8s %-5s sector %d + %d" % ((ts - w['t0']) * 1e6, 'issue' if issue else 'done', rwbs, sector, nr))
q = sorted(lat)
print("%s: %d fsyncs" % (sys.argv[2], len(wins)))
print("  latency us    mean %.0f  p50 %.0f  p99 %.0f" % (statistics.mean(lat), q[len(q)//2], q[int(len(q)*.99)-1]))
print("  per fsync     %.2f requests, %.2f serial phases, %.1f KiB written" %
      (statistics.mean(ios), statistics.mean(phases), statistics.mean(kb)))
print("  per fsync     %.2f cache flushes, %.2f FUA writes" % (statistics.mean(fl), statistics.mean(fua)))
print("  phases seen   " + ", ".join("%d:%d" % (p, phases.count(p)) for p in sorted(set(phases))))
print("  request types " + ", ".join("%s %d" % kv for kv in sorted(kinds.items(), key=lambda x: -x[1])))
EOF
sudo umount "$TAU_MNT"
