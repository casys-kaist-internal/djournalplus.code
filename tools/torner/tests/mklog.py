#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Build a synthetic dm-log-writes log holding one tau transaction.

This exists to validate `torner loginv` before a real log exists, and to give
it a known-bad input.  CRASH_TODO 3.7 asks for a barrier-stripped kernel build
to prove I1 detection fires -- but that proves the *kernel*.  To prove the
*checker*, a log we constructed to violate I1 is strictly better evidence: we
know exactly what is wrong with it.

Layout (drivers/md/dm-log-writes.c, xfstests src/log-writes/log-writes.h):

    byte 0          log_write_super, padded to sectorsize
    per entry       log_write_entry, padded to sectorsize
                    + nr_sectors * sectorsize of data (none for DISCARD)
"""
import struct
import sys
import zlib

WRITE_LOG_MAGIC = 0x6A736677736872
WRITE_LOG_VERSION = 1

LOG_FLUSH_FLAG = 1 << 0
LOG_FUA_FLAG = 1 << 1
LOG_MARK_FLAG = 1 << 3

TAU_MAGIC = 0xC03B3998
TAU_DESCRIPTOR_BLOCK = 1
TAU_COMMIT_BLOCK = 2
TAU_TAG_LAST = 8

# Journal geometry the checker has to discover before it can attribute any
# block to tau: the superblock names the segment size, the segment map names
# where segments physically live.  1 MiB segments keep the synthetic log small.
TAU_SB_LBA = 500
TAU_SEG_SIZE = 1 << 20
TAU_SEG_PBA = 1000

SECTORSIZE = 512
FSBLK = 4096
SPB = FSBLK // SECTORSIZE          # sectors per fs block


def tau_superblock():
    """s_blocksize@12 and s_segment_size@92; jbd2 leaves the latter zero, which
    is the only field that tells the two superblocks apart."""
    b = bytearray(FSBLK)
    struct.pack_into(">III", b, 0, TAU_MAGIC, 4, 0)
    struct.pack_into(">I", b, 12, FSBLK)          # s_blocksize
    struct.pack_into(">I", b, 16, 1 << 20)        # s_maxlen
    struct.pack_into(">I", b, 92, TAU_SEG_SIZE)   # s_segment_size
    return bytes(b)


def tau_segment_map(pbas, ino=14):
    """256 entries of {pba be64, ino be64}."""
    b = bytearray(FSBLK)
    for i, pba in enumerate(pbas):
        struct.pack_into(">QQ", b, i * 16, pba, ino)
    return bytes(b)


def tau_descriptor(seq, ino, tags, next_segment=0):
    b = bytearray(FSBLK)
    struct.pack_into(">IIII", b, 0, TAU_MAGIC, TAU_DESCRIPTOR_BLOCK, seq, 0)
    struct.pack_into(">Q", b, 16, ino)
    struct.pack_into(">Q", b, 24, next_segment)
    off = 32
    for i, blk in enumerate(tags):
        flags = TAU_TAG_LAST if i == len(tags) - 1 else 0
        struct.pack_into(">IIH", b, off, blk & 0xFFFFFFFF, blk >> 32, flags)
        off += 10
    return bytes(b)


def tau_commit(seq, ino, epoch, next_segment=0):
    b = bytearray(FSBLK)
    struct.pack_into(">IIII", b, 0, TAU_MAGIC, TAU_COMMIT_BLOCK, seq, 0)
    struct.pack_into(">Q", b, 16, ino)
    struct.pack_into(">Q", b, 24, next_segment)
    struct.pack_into(">Q", b, 32, epoch)
    return bytes(b)


# ---- torner sectors, byte-identical to src/common.c ------------------------
#
# The atoms tests need logs whose payloads carry real application sectors, so
# this reimplements torner_fill() and torner_build_sector() exactly.  If either
# side changes, test_sector_roundtrip in atoms_test.sh catches the drift: the
# C oracle has to accept a unit built here.

MASK64 = (1 << 64) - 1
TORNSEC1 = 0x3143455344524F54
RUN_ID = 777


def _splitmix(s):
    s = (s + 0x9E3779B97F4A7C15) & MASK64
    z = s
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
    return s, z ^ (z >> 31)


def torner_fill(page, version, sidx, run_id, n):
    s = ((page * 0x9E3779B97F4A7C15) ^ (version * 0xC2B2AE3D27D4EB4F)
         ^ (sidx * 0x165667B19E3779F9) ^ (run_id * 0xD6E8FEB86659FD93)) & MASK64
    out = bytearray()
    while len(out) < n:
        s, v = _splitmix(s)
        out += struct.pack("<Q", v)
    return bytes(out[:n])


def torner_sector(page, version, sidx, spu=4, ssz=4096, run_id=RUN_ID):
    hdr = struct.pack("<QQQQIIIIIIQ", TORNSEC1, page, version, 0, 0,
                      sidx, spu, ssz, 0, 0, run_id)
    sec = bytearray(hdr + torner_fill(page, version, sidx, run_id, ssz - len(hdr)))
    struct.pack_into("<I", sec, 48, zlib.crc32(bytes(sec)) & 0xFFFFFFFF)
    return bytes(sec)


def torner_unit(page, version, sidxs=(0, 1, 2, 3)):
    return b"".join(torner_sector(page, version, s) for s in sidxs)


class Log:
    def __init__(self):
        self.entries = []

    def write(self, fsblock, data, flags=0):
        assert len(data) % FSBLK == 0
        self.entries.append((fsblock * SPB, len(data) // SECTORSIZE, flags, 0, b"", data))

    def barrier(self, flags=LOG_FLUSH_FLAG):
        self.entries.append((0, 0, flags, 0, b"", b""))

    def mark(self, name):
        """
        A MARK keeps its string inside its own entry sector, right after the
        32-byte header, and leaves nr_sectors at 0 -- see log_mark() and
        log_one_block()'s metadatalen path in dm-log-writes.c.  Reading it as a
        trailing payload silently finds nothing.
        """
        raw = name.encode()
        assert len(raw) <= SECTORSIZE - 32 - 1
        self.entries.append((0, 0, LOG_MARK_FLAG, len(raw), raw, b""))

    def dump(self, path):
        out = bytearray()
        sup = struct.pack("<QQQI", WRITE_LOG_MAGIC, WRITE_LOG_VERSION,
                          len(self.entries), SECTORSIZE)
        out += sup + bytes(SECTORSIZE - len(sup))
        for sector, nr_sectors, flags, data_len, inline, data in self.entries:
            hdr = struct.pack("<QQQQ", sector, nr_sectors, flags, data_len)
            hdr += inline
            out += hdr + bytes(SECTORSIZE - len(hdr))
            out += data
        with open(path, "wb") as f:
            f.write(out)


def build_datalog(path):
    """
    Six writes with distinguishable payloads, two per epoch, so a replay can be
    checked byte for byte:

        epoch 1   fs block 100 = 0xA1, 101 = 0xA2, FLUSH
        epoch 2   fs block 102 = 0xA3, 103 = 0xA4, FLUSH
        epoch 3   fs block 104 = 0xA5, 105 = 0xA6, FLUSH

    Entry indices are 0..5, so `epoch<=2,drop=[2]` must leave block 102 at its
    base content while 100, 101 and 103 carry their payloads.
    """
    log = Log()
    for i in range(6):
        blk = 100 + i
        val = 0xA1 + i
        # progress mark inside the epoch, before its closing flush
        if i % 2 == 1:
            log.mark("torner:prog=%d" % (10 * (i // 2 + 1)))
        flags = LOG_FLUSH_FLAG if i % 2 == 1 else 0
        log.write(blk, bytes([val]) * FSBLK, flags=flags)
    log.dump(path)


def build_tau(kind, path):
    """
    One transaction: descriptor at fs block 1000, its two data blocks at
    1001-1002, commit at 1003.  Tags name the in-place blocks 5000/5001.
    """
    log = Log()
    desc = tau_descriptor(seq=42, ino=12, tags=[5000, 5001])
    payload = bytes(FSBLK) * 2
    commit = tau_commit(seq=42, ino=12, epoch=7)

    # Geometry first: without it nothing in the stream can be attributed to
    # tau, and the checker refuses the log rather than reporting it clean.
    log.write(TAU_SB_LBA, tau_superblock())
    log.write(TAU_SB_LBA + 1, tau_segment_map([TAU_SEG_PBA]))

    log.write(1000, desc)
    log.write(1001, payload)

    if kind == "good":
        # data is flushed before the commit block is issued -- I1 holds
        log.barrier(LOG_FLUSH_FLAG)
        log.write(1003, commit, flags=LOG_FUA_FLAG)
    elif kind == "no-barrier":
        # commit shares an epoch with its own data -- I1 must fire
        log.write(1003, commit, flags=LOG_FUA_FLAG)
    elif kind == "no-flags":
        # what a write-through backing device produces: every flag stripped,
        # one epoch for the whole log, every ordering check vacuous
        log.write(1003, commit)
    elif kind == "fua-not-flush":
        # The data is never flushed: the commit goes out FUA with no preflush.
        # An unrelated FUA write falls in between -- a journal superblock
        # update, say.  FUA makes only itself durable, so the commit can
        # land while the data sits in the cache.  A model that splits
        # epochs on FUA puts the commit in a later epoch and calls it fine.
        log.write(9000, bytes(FSBLK), flags=LOG_FUA_FLAG)
        log.write(1003, commit, flags=LOG_FUA_FLAG)
    else:
        raise SystemExit("unknown kind %s" % kind)

    log.dump(path)


def build_atomslog(path):
    """
    Application writes that reach the device in every shape `torner atoms`
    has to tell apart.  The file IS the device image: page p lives at fs
    blocks 4p..4p+3, so a replayed image can be handed straight to
    `torner check --file`.  Entry indices, which the tests assert on:

       0  p0 v0, 4 sectors, one bio          setup (version 0) -- excluded
       1  FLUSH
       2  MARK torner:begin
       3  p1 v1, 4 sectors, one bio          one_bio
       4  FLUSH
       5  p2 v1 sectors 0-1                  split_window, first piece
       6  p2 v1 sectors 2-3                  ...second piece, same window
       7  FLUSH
       8  MARK torner:prog=7
       9  p3 v1 sectors 0-1                  split_flush, first piece
      10  FLUSH
      11  p3 v1 sectors 2-3                  ...second piece, after a FLUSH
      12  FLUSH
      13  p4 v1 embedded at byte 200 of a    one_bio via its first copy,
          20 KiB record at block 400         which is not block-aligned
      14  FLUSH
      15  p4 v1 in place, blocks 16-19       second copy of p4
      16  FUA write, block 600: a copy of p9 with one byte flipped -- the
          scanner must reject it, and no application write may come of it
      17  FLUSH
      18  MARK torner:end
    """
    log = Log()
    log.write(0, torner_unit(0, 0))
    log.barrier(LOG_FLUSH_FLAG)
    log.mark("torner:begin")
    log.write(4, torner_unit(1, 1))
    log.barrier(LOG_FLUSH_FLAG)
    log.write(8, torner_unit(2, 1, (0, 1)))
    log.write(10, torner_unit(2, 1, (2, 3)))
    log.barrier(LOG_FLUSH_FLAG)
    log.mark("torner:prog=7")
    log.write(12, torner_unit(3, 1, (0, 1)))
    log.barrier(LOG_FLUSH_FLAG)
    log.write(14, torner_unit(3, 1, (2, 3)))
    log.barrier(LOG_FLUSH_FLAG)
    rec = bytes(200) + torner_unit(4, 1)
    rec += bytes((-len(rec)) % FSBLK)
    log.write(400, rec)
    log.barrier(LOG_FLUSH_FLAG)
    log.write(16, torner_unit(4, 1))
    bad = bytearray(torner_sector(9, 1, 0))
    bad[1000] ^= 0x40
    log.write(600, bytes(bad), flags=LOG_FUA_FLAG)
    log.barrier(LOG_FLUSH_FLAG)
    log.mark("torner:end")
    log.dump(path)


def build_unit(path):
    """One intact unit for the sector round-trip test: page 0, version 1."""
    with open(path, "wb") as f:
        f.write(torner_unit(0, 1))


def build(kind, path):
    if kind == "datalog":
        build_datalog(path)
    elif kind == "atomslog":
        build_atomslog(path)
    elif kind == "unit":
        build_unit(path)
    else:
        build_tau(kind, path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: mklog.py {good|no-barrier|no-flags|fua-not-flush|"
                         "datalog|atomslog|unit} <out>")
    build(sys.argv[1], sys.argv[2])
