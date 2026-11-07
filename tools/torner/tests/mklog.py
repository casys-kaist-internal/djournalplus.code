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
    struct.pack_into(">I", b, 16, 2)              # s_maxlen: sb + one map block
    struct.pack_into(">I", b, 92, TAU_SEG_SIZE)   # s_segment_size
    return bytes(b)


def tau_segment_map(pbas, ino=14):
    """256 entries of {pba be64, ino be64}."""
    b = bytearray(FSBLK)
    for i, pba in enumerate(pbas):
        struct.pack_into(">QQ", b, i * 16, pba, ino)
    return bytes(b)


TAU_TAG_SAME_UUID = 2
TAU_TAG_HOME = 0x20
TAU_MAPLOG_BLOCK = 6
TAU_MAPLOG_FREE = 2
JBD2_COMMIT_BLOCK = 2
XLOG_MAGIC = 0xFEEDBABE


def tau_descriptor(seq, ino, tags, next_segment=0, serial=1, home=()):
    """Tags as the kernel lays them out (fs/taujournal/commit.c): 10 bytes
    each, the journal's UUID after the first, the file's serial in the last
    8 bytes.  Blocks in @home are tagged TAU_TAG_HOME: written straight home,
    no journal block."""
    b = bytearray(FSBLK)
    struct.pack_into(">IIII", b, 0, TAU_MAGIC, TAU_DESCRIPTOR_BLOCK, seq, 0)
    struct.pack_into(">Q", b, 16, ino)
    struct.pack_into(">Q", b, 24, next_segment)
    off = 32
    for i, blk in enumerate(tags):
        flags = TAU_TAG_LAST if i == len(tags) - 1 else 0
        if i:
            flags |= TAU_TAG_SAME_UUID
        if blk in home:
            flags |= TAU_TAG_HOME
        struct.pack_into(">IIH", b, off, blk & 0xFFFFFFFF, blk >> 32, flags)
        off += 10
        if not i:
            off += 16                              # the UUID
    struct.pack_into(">Q", b, FSBLK - 8, serial)
    return bytes(b)


def tau_commit(seq, ino, epoch, next_segment=0, serial=1, flags=0, maplog=(0, 0)):
    b = bytearray(FSBLK)
    struct.pack_into(">IIII", b, 0, TAU_MAGIC, TAU_COMMIT_BLOCK, seq, 0)
    struct.pack_into(">Q", b, 16, ino)
    struct.pack_into(">Q", b, 24, next_segment)
    struct.pack_into(">Q", b, 32, epoch)           # h_epoch: the host commit it names
    struct.pack_into(">I", b, 40, flags)           # h_flags
    struct.pack_into(">Q", b, 96, serial)          # h_serial
    if maplog[1]:
        flags |= 0x4                               # TAU_COMMIT_F_MAPLOG
        struct.pack_into(">I", b, 40, flags)
        struct.pack_into(">QI", b, 80, maplog[0], maplog[1])   # h_maplog, h_maplog_nr
    return bytes(b)


def jbd2_commit(tid):
    """jbd2's commit block: tau's magic and header, outside tau's segments."""
    b = bytearray(FSBLK)
    struct.pack_into(">III", b, 0, TAU_MAGIC, JBD2_COMMIT_BLOCK, tid)
    return bytes(b)


def xlog_record(cycle, block, at=0):
    """A block holding an XFS log record header at byte @at (a 512-byte
    boundary): h_magicno, h_cycle, h_version 2, h_len, h_lsn = cycle<<32|block."""
    b = bytearray(FSBLK)
    struct.pack_into(">IIIIQ", b, at, XLOG_MAGIC, cycle, 2, 512, (cycle << 32) | block)
    return bytes(b)


def maplog_claim(seq, ents, ino=12):
    """A CLAIM block of the segment map log: {e_index, e_pba, e_ino} each."""
    b = bytearray(FSBLK)
    struct.pack_into(">IIQIHH", b, 0, TAU_MAGIC, TAU_MAPLOG_BLOCK, seq, 1, 1, len(ents))
    for i, (index, pba) in enumerate(ents):
        struct.pack_into(">IIQQ", b, 32 + i * 24, index, 0, pba, ino)
    return bytes(b)


def maplog_free(seq, ents):
    """A FREE block of the segment map log: {e_index, e_pba, e_ino 0} each."""
    b = bytearray(FSBLK)
    struct.pack_into(">IIQIHH", b, 0, TAU_MAGIC, TAU_MAPLOG_BLOCK, seq, 1,
                     TAU_MAPLOG_FREE, len(ents))
    for i, (index, pba) in enumerate(ents):
        struct.pack_into(">IIQQ", b, 32 + i * 24, index, 0, pba, 0)
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

    The first four records name no host commit (h_epoch 0), so only their own
    flush can order them.  The gated cases name jbd2 tid 5 (or an XFS LSN),
    as a record sent without a flush of its own since kernel #376 does.
    """
    log = Log()
    desc = tau_descriptor(seq=42, ino=12, tags=[5000, 5001])
    payload = bytes(FSBLK) * 2
    commit = tau_commit(seq=42, ino=12, epoch=0)
    gated = tau_commit(seq=42, ino=12, epoch=5)

    # Geometry first: without it nothing in the stream can be attributed to
    # tau, and the checker refuses the log rather than reporting it clean.
    log.write(TAU_SB_LBA, tau_superblock())
    log.write(TAU_SB_LBA + 1, tau_segment_map([TAU_SEG_PBA]))

    if kind in ("fua-first", "fua-first-nofree"):
        # The record_fua_only control's shape.  The segment's previous owner
        # wrote block 1001, and (fua-first) its FREE went out on the map log.
        # Then the record goes FUA with no preflush: dm-log-writes logs a FUA
        # write at its completion but plain writes only at the next FLUSH, so
        # the record lands in the log AHEAD of the descriptor and data it
        # vouches for.  The checker has to find them after it, and must not
        # take the previous owner's 1001 for this transaction's.
        log.write(1001, bytes(FSBLK))
        log.barrier(LOG_FLUSH_FLAG)
        if kind == "fua-first":
            log.write(9100, maplog_free(1, [(0, TAU_SEG_PBA)]), flags=LOG_FUA_FLAG)
        log.write(1003, commit, flags=LOG_FUA_FLAG)
        log.write(1000, desc)
        log.write(1001, payload)
        log.barrier(LOG_FLUSH_FLAG)
        log.dump(path)
        return

    if kind in ("claim-ok", "claim-late"):
        # The record names its claim on the map log (h_seq 5, one block):
        # the segment it entered counts only if the record does, so the claim
        # has to be durable before the record can count, like its data.
        log.write(1000, desc)
        log.write(1001, payload)
        if kind == "claim-ok":
            log.write(9200, maplog_claim(5, [(0, TAU_SEG_PBA)]))
        log.barrier(LOG_FLUSH_FLAG)
        log.write(1003, tau_commit(seq=42, ino=12, epoch=0, maplog=(5, 1)),
                  flags=LOG_FUA_FLAG)
        if kind == "claim-late":
            log.write(9200, maplog_claim(5, [(0, TAU_SEG_PBA)]))
            log.barrier(LOG_FLUSH_FLAG)
        log.dump(path)
        return

    if kind in ("home-ok", "home-late"):
        # Tag 7000 is HOME: a new block written straight home, outside the
        # journal.  Its write must be durable before the record, like the
        # journal copies.
        desc = tau_descriptor(seq=42, ino=12, tags=[5000, 7000], home=(7000,))
        log.write(1000, desc)
        log.write(1001, bytes(FSBLK))
        if kind == "home-ok":
            log.write(7000, bytes(FSBLK))
        log.barrier(LOG_FLUSH_FLAG)
        log.write(1002, commit, flags=LOG_FUA_FLAG)
        if kind == "home-late":
            log.write(7000, bytes(FSBLK))
            log.barrier(LOG_FLUSH_FLAG)
        log.dump(path)
        return

    if kind == "gated-late":
        # A record without a flush of its own naming jbd2 tid 5, but data
        # block 1002 completes only after jbd2's preflush went out: it is
        # logged at the next flush, after the host commit.  The record can
        # count with that block not on disk.
        log.write(1000, desc)
        log.write(1001, bytes(FSBLK))
        log.write(1003, gated)
        log.barrier(LOG_FLUSH_FLAG)
        log.write(9500, jbd2_commit(5), flags=LOG_FUA_FLAG)
        log.write(1002, bytes(FSBLK))
        log.barrier(LOG_FLUSH_FLAG)
        log.dump(path)
        return

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
    elif kind == "gated-ok":
        # A record without a flush of its own, logged in its data's window,
        # naming jbd2 tid 5.  jbd2's commit block of tid 5 goes out behind a
        # flush (PREFLUSH|FUA: dm logs the empty flush, then the FUA write),
        # so the data is durable before the record can count.
        log.write(1003, gated)
        log.barrier(LOG_FLUSH_FLAG)
        log.write(9500, jbd2_commit(5), flags=LOG_FUA_FLAG)
    elif kind == "gate-closed":
        # The record names tid 5, whose commit never reaches the log: no crash
        # state of this log counts the record, so its order cannot hurt.
        log.write(1003, gated)
        log.barrier(LOG_FLUSH_FLAG)
    elif kind == "xfs-gated-ok":
        # tau-xfs: the record names the LSN of the XFS log record it waits
        # for (cycle 3, block 64).  The header sits at a 512-byte boundary
        # inside the block, not at its start.
        log.write(1003, tau_commit(seq=42, ino=12, epoch=(3 << 32) | 64))
        log.barrier(LOG_FLUSH_FLAG)
        log.write(9600, xlog_record(3, 64, at=512), flags=LOG_FUA_FLAG)
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


# ---- I5: one application write against the durable units ------------------
#
# A 16 KiB unit (page 0, version 1) of four 4 KiB sectors, journaled either in
# one transaction or split across two.  On ext4 data=journal the unit is the
# jbd2 transaction, on tau the tau transaction.

JBD2_SB_LBA = 2000
JBD2_INCOMPAT = 0x12            # CSUM_V3 | 64BIT, as ext4 with metadata_csum mounts it


def jbd2_superblock(incompat=JBD2_INCOMPAT):
    b = bytearray(FSBLK)
    struct.pack_into(">III", b, 0, TAU_MAGIC, 4, 0)       # SUPERBLOCK_V2
    struct.pack_into(">III", b, 12, FSBLK, 1024, 1)       # blocksize, maxlen, first
    struct.pack_into(">I", b, 0x28, incompat)
    return bytes(b)


def jbd2_descriptor(tid, homes):
    """tag3 (16 bytes: blocknr, flags be32, blocknr_high, checksum), the UUID
    after the first tag, a 4-byte tail."""
    b = bytearray(FSBLK)
    struct.pack_into(">III", b, 0, TAU_MAGIC, 1, tid)
    off = 12
    for i, blk in enumerate(homes):
        flags = (8 if i == len(homes) - 1 else 0) | (2 if i else 0)
        struct.pack_into(">IIII", b, off, blk & 0xFFFFFFFF, flags, blk >> 32, 0)
        off += 16
        if not i:
            off += 16
    return bytes(b)


def build_i5(kind, path):
    log = Log()
    unit = [torner_sector(0, 1, k) for k in range(4)]
    if kind.startswith("i5-jbd2"):
        log.write(JBD2_SB_LBA, jbd2_superblock(0))       # mke2fs: no features yet
        log.write(JBD2_SB_LBA, jbd2_superblock())        # the mount sets them
        groups = [[0, 1], [2, 3]] if kind == "i5-jbd2-split" else [[0, 1, 2, 3]]
        jb = JBD2_SB_LBA + 1
        for tid, g in enumerate(groups, 1):
            log.write(jb, jbd2_descriptor(tid, [6000 + k for k in g]))
            for n, k in enumerate(g):
                log.write(jb + 1 + n, unit[k])
            log.barrier(LOG_FLUSH_FLAG)
            log.write(jb + 1 + len(g), jbd2_commit(tid), flags=LOG_FUA_FLAG)
            jb += 2 + len(g)
    else:
        log.write(TAU_SB_LBA, tau_superblock())
        log.write(TAU_SB_LBA + 1, tau_segment_map([TAU_SEG_PBA]))
        groups = [[0, 1], [2, 3]] if kind == "i5-tau-split" else [[0, 1, 2, 3]]
        jb = TAU_SEG_PBA
        for seq, g in enumerate(groups, 42):
            log.write(jb, tau_descriptor(seq=seq, ino=12, tags=[5000 + k for k in g]))
            for n, k in enumerate(g):
                log.write(jb + 1 + n, unit[k])
            log.barrier(LOG_FLUSH_FLAG)
            log.write(jb + 1 + len(g), tau_commit(seq=seq, ino=12, epoch=0),
                      flags=LOG_FUA_FLAG)
            jb += 2 + len(g)
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
    elif kind.startswith("i5-"):
        build_i5(kind, path)
    else:
        build_tau(kind, path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: mklog.py {good|no-barrier|no-flags|fua-not-flush|"
                         "gated-ok|gated-late|gate-closed|xfs-gated-ok|"
                         "fua-first|fua-first-nofree|home-ok|home-late|"
                         "i5-jbd2-ok|i5-jbd2-split|i5-tau-ok|i5-tau-split|"
                         "claim-ok|claim-late|"
                         "datalog|atomslog|unit} <out>")
    build(sys.argv[1], sys.argv[2])
