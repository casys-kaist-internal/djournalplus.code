#!/usr/bin/env python3
"""zlog.py <cap dir> [--epoch N[-M]] [--entries A-B] [--page P[,Q]]

Reads a Torner capture's dm-log-writes log (log.img) and prints, one line per
entry: index, legacy epoch (+1 after FLUSH or FUA), fepoch (+1 after FLUSH),
flags, device byte offset and length, and what the payload holds:
  - Torner data sectors, as page:version:sectors
  - a ZIL block: its records; TX_WRITE as foid/offset/length and the DVA
    offset (+4 MiB label area = vdev byte offset) its block pointer names,
    "copied" when the data rides in the record
  - an uberblock (txg)
  - other (metadata we do not decode)
--page lists only entries carrying the given pages.
"""
import struct
import sys
from collections import defaultdict

SECTOR_MAGIC = 0x3143455344524f54
ZEC_MAGIC = 0x210da7ab10c7a11
UB_MAGIC = 0x00bab10c
LOG_MAGIC = 0x6a736677736872
F_FLUSH, F_FUA, F_DISCARD, F_MARK = 1, 2, 4, 8
LABEL_START = 4 << 20
TXN = {0: "COMMIT", 1: "CREATE", 5: "REMOVE", 9: "WRITE", 10: "TRUNCATE", 11: "SETATTR", 20: "WRITE2"}


def index(path):
    f = open(path, "rb")
    magic, ver, n, ss = struct.unpack("<QQQI", f.read(28))
    assert magic == LOG_MAGIC, hex(magic)
    ents, pos, ep, fep = [], ss, 1, 1
    for i in range(n):
        f.seek(pos)
        hdr = f.read(ss)
        if len(hdr) < 32:
            break
        sec, nr, fl, dl = struct.unpack_from("<QQQQ", hdr)
        pos += ss
        mark = hdr[32:32 + dl].split(b"\0")[0].decode("ascii", "replace") if fl & F_MARK else None
        pay = None
        if nr and not fl & F_DISCARD:
            pay = pos
            pos += nr * ss
        ents.append(dict(i=i, off=sec * 512, len=nr * ss, fl=fl, ep=ep, fep=fep, pay=pay, mark=mark))
        if fl & (F_FLUSH | F_FUA):
            ep += 1
        if fl & F_FLUSH:
            fep += 1
    return f, ents


def torner_secs(buf):
    out = defaultdict(list)
    for o in range(0, len(buf) - 63, 512):
        if struct.unpack_from("<Q", buf, o)[0] == SECTOR_MAGIC:
            page, ver, seq, tid, sidx = struct.unpack_from("<QQQII", buf, o + 8)
            out[(page, ver)].append(sidx)
    return out


def zil_records(buf):
    if len(buf) >= 184 and struct.unpack_from("<Q", buf, 144)[0] == ZEC_MAGIC:
        nused = struct.unpack_from("<Q", buf, 136)[0]
        start, end, fmt = 184, min(nused, len(buf)), "zilog2"
    elif len(buf) >= 184 and struct.unpack_from("<Q", buf, len(buf) - 40)[0] == ZEC_MAGIC:
        t = len(buf) - 184
        nused = struct.unpack_from("<Q", buf, t + 136)[0]
        start, end, fmt = 0, min(nused, t), "zilog"
    else:
        return None
    recs, off = [], start
    while off + 32 <= end:
        txtype, reclen, txg, seq = struct.unpack_from("<QQQQ", buf, off)
        if reclen < 32 or off + reclen > end:
            break
        t = txtype & ~(1 << 63)
        r = "%s txg=%d seq=%d" % (TXN.get(t, "tx%d" % t), txg, seq)
        if t == 20 and reclen >= 192:
            # TX_WRITE2: the same lr_write_t, no block of its own (dmu_sync EALREADY)
            foid, lo, ll = struct.unpack_from("<QQQ", buf, off + 32)
            r = "WRITE2 foid=%d off=%#x len=%#x txg=%d seq=%d" % (foid, lo, ll, txg, seq)
        if t == 9 and reclen >= 192:
            foid, lo, ll = struct.unpack_from("<QQQ", buf, off + 32)
            w0, w1 = struct.unpack_from("<QQ", buf, off + 64)
            birth = struct.unpack_from("<Q", buf, off + 64 + 80)[0]
            if reclen > 192:
                where = "copied"
            elif w0 == 0 and w1 == 0:
                where = "hole"
            else:
                where = "bp->vdev %#x birth %d" % (((w1 & ~(1 << 63)) << 9) + LABEL_START, birth)
            r = "WRITE foid=%d off=%#x len=%#x %s txg=%d seq=%d" % (foid, lo, ll, where, txg, seq)
        recs.append(r)
        off += reclen
    return fmt, recs


def describe(f, e):
    fl = "".join(c for b, c in ((F_FLUSH, "F"), (F_FUA, "U"), (F_DISCARD, "D"), (F_MARK, "M")) if e["fl"] & b) or "-"
    head = "%5d ep%-4d fep%-4d %-2s %#11x %6d" % (e["i"], e["ep"], e["fep"], fl, e["off"], e["len"])
    if e["mark"] is not None:
        return head + "  mark %r" % e["mark"], {}
    if e["pay"] is None:
        return head, {}
    f.seek(e["pay"])
    buf = f.read(e["len"])
    ts = torner_secs(buf)
    if ts:
        return head + "  data " + " ".join("p%dv%d:%s" % (p, v, "".join(map(str, sorted(s))))
                                         for (p, v), s in sorted(ts.items())), ts
    z = zil_records(buf)
    if z:
        return head + "  ZIL(%s) %d recs" % (z[0], len(z[1])) + "".join("\n" + " " * 44 + r for r in z[1]), {}
    ubs = [struct.unpack_from("<Q", buf, o + 16)[0] for o in range(0, len(buf), 4096)
           if struct.unpack_from("<Q", buf, o)[0] == UB_MAGIC]
    if ubs:
        return head + "  uberblock txg " + ",".join(map(str, ubs)), {}
    return head + "  other", {}


def rng(s):
    a, _, b = s.partition("-")
    return int(a), int(b or a)


def main():
    cap = sys.argv[1]
    args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
    f, ents = index(cap + "/log.img")
    pages = set(int(x) for x in args["--page"].split(",")) if "--page" in args else None
    if "--epoch" in args:
        a, b = rng(args["--epoch"])
        sel = [e for e in ents if a <= e["ep"] <= b]
    elif "--entries" in args:
        a, b = rng(args["--entries"])
        sel = ents[a:b + 1]
    else:
        sel = ents
    print("entries %d, epochs %d, fepochs %d" % (len(ents), ents[-1]["ep"], ents[-1]["fep"]))
    for e in sel:
        line, ts = describe(f, e)
        if pages is not None and not any(p in pages for p, _ in ts):
            continue
        print(line)


main()
