/* SPDX-License-Identifier: GPL-2.0
 *
 * torner loginv -- T2a, the static log invariant checker.
 *
 * Parses a dm-log-writes log and decides ordering invariants without ever
 * crashing anything.  That is the point: a probabilistic replay can miss a
 * missing barrier, because most replays of a barrier-less stream still happen
 * to land in a legal order.  Reading the log settles it.
 *
 * Two things make identifying tau's own blocks harder than grepping for a
 * magic number, and both were learned the hard way from a real capture:
 *
 *  - jbd2 uses the SAME magic (0xc03b3998, which tau inherited) and the same
 *    block types 1 and 2, and its commit header even agrees with tau's out to
 *    h_commit_sec.  On a tau-ext4 stack both journals are in the stream.  They
 *    are told apart by LBA: the tau superblock names the journal's geometry,
 *    and the segment map names where its segments physically live.
 *
 *  - A tau transaction is not "one descriptor plus its tags".  It is a CHAIN
 *    of descriptor blocks, each followed by the data blocks its tags name,
 *    all sharing one sequence number, closed by a single commit block.  So the
 *    transaction's extent is [first descriptor of that sequence, commit), and
 *    reconstructing it from a single descriptor's tag count is wrong.
 *
 * Two more decide WHICH write of a block is the transaction's.  Both came from
 * the record_fua_only control, whose crash states fail and which the first
 * version of I1 passed:
 *
 *  - dm-log-writes logs a plain write at the next FLUSH, but a FUA write at its
 *    own completion.  A record sent FUA without a preflush is therefore logged
 *    BEFORE the data it vouches for, and a block's write has to be looked for
 *    on both sides of the commit.
 *
 *  - A journal block is written once per ownership of its segment.  A segment
 *    goes back to the pool through a FREE on the segment map log, which goes
 *    out PREFLUSH|FUA and is waited for before the segment is handed out again
 *    (fs/taujournal/journal.c, __tau_maplog_free).  So between two FREEs of a
 *    segment each of its blocks is written once, by the transaction the layout
 *    puts there, whether that write is logged before its commit or after.
 */
#include "torner.h"
#include "tau_ondisk.h"
#include "log_writes.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * DIA_NONE is a stock ext4/xfs: no data journal, so the bio IS the durable
 * unit and bio containment is a verdict.  DIA_COW is ZFS, where the durable
 * unit is the transaction group -- CRASH_TODO §3.5 rules its on-disk format
 * out of scope, so it is measured through T2b only and no log invariant
 * applies.
 */
enum dialect { DIA_TAU, DIA_JBD2, DIA_NONE, DIA_COW };

/*
 * The host journal whose commit gates a tau record that went without a flush
 * of its own: jbd2 on tau-ext4, the XFS log on tau-xfs.
 */
enum hostlog { HOST_NONE, HOST_JBD2, HOST_XFS };

/* One tau journal metadata block seen in the stream. */
struct jblk {
	uint64_t lba;
	uint64_t entry_idx;
	uint64_t fepoch;	/* FLUSH-separated: the durability order */
	uint64_t next_segment;
	uint64_t inode_number;
	uint64_t serial;	/* the file's number in the mount, 0: none */
	uint64_t commit_epoch_field;	/* commit blocks: h_epoch */
	uint64_t maplog_seq;		/* commit blocks: its first claim, h_maplog */
	uint32_t maplog_nr;		/* ... and how many (TAU_COMMIT_F_MAPLOG) */
	uint64_t tail_blk;		/* commit blocks: h_tail_blk */
	uint32_t tail_tid;		/* ... h_tail_tid */
	uint32_t jgen;			/* ... h_jgen */
	uint32_t jtag_first;		/* descriptors: their journal tags, c->jtag[] */
	uint32_t jtag_n;
	uint32_t blocktype;
	uint32_t sequence;
	uint32_t commit_flags;		/* commit blocks: h_flags */
	uint32_t home_first;		/* descriptors: their HOME tags, c->home[] */
	uint32_t home_n;
	uint8_t	 fua;
};

/* One block of a logged write. */
struct wr {
	uint64_t lba;
	uint64_t entry_idx;
	uint64_t fepoch;
	uint8_t	 fua;		/* durable on its own completion */
};

/* A host journal commit: a jbd2 commit block (key: its tid) or an XFS log
 * record header (key: its LSN). */
struct hcommit {
	uint64_t key;
	uint64_t entry_idx;
	uint64_t fepoch;
};

/* A revoke tag, from a revoke block written at (lba, entry). */
struct rtag {
	uint64_t lba;
	uint64_t entry_idx;
	uint64_t scope;
	uint64_t pblk;
	uint32_t flags;		/* the block's h_flags: TAU_REVOKE_F_* */
};

static int rt_cmp(const void *x, const void *y);

/* A write of the tau superblock: where the map log's base was. */
struct sbwrite {
	uint64_t entry_idx;
	uint64_t fepoch;
	uint64_t base;
	uint32_t sequence;	/* s_sequence: the mount (= its records' h_jgen) */
	uint8_t	 fua;
};

/* A write of one segment map block, and the owned entries it names. */
struct mapwrite {
	uint64_t entry_idx;
	uint64_t fepoch;
	uint32_t ent_first;	/* c->ment[] */
	uint32_t ent_n;
	uint8_t	 fua;
};

struct mapent {
	uint64_t pba;
	uint64_t ino;
};

/* One entry of a map log CLAIM block: segment pba entered by ino. */
struct claiment {
	uint64_t pba;
	uint64_t ino;
	uint64_t seq;
	uint64_t entry_idx;
};

/* A write of one map log block (any kind), for the wrap rule. */
struct mlwrite {
	uint64_t lba;
	uint64_t seq;
	uint64_t entry_idx;
	uint32_t jgen;		/* h_jgen: the mount that wrote it */
};

/* A transaction I1 reconstructed, for I2 and I3. */
struct txinfo {
	size_t	 ci;		/* its commit in jb[] */
	uint64_t first_entry;	/* the earliest write of its own blocks */
	uint64_t first_lba;	/* its first block: its first descriptor */
	long	 seg[2];	/* the commit's segment, and the first one if two */
	uint32_t jt_first;	/* the home blocks of its journal copies, c->txjt[] */
	uint32_t jt_n;
	uint32_t rt_first;	/* its revoke tags, indices into c->rt[], c->txrt[] */
	uint32_t rt_n;
};

/* The write of one map log CLAIM block, by its h_seq. */
struct claimw {
	uint64_t seq;
	struct wr w;
};

/* A FREE on the segment map log: it ends one ownership of a segment. */
struct segfree {
	uint64_t pba;
	uint64_t seq;		/* the map log block's h_seq */
	uint64_t entry_idx;
	uint64_t fepoch;
};

/*
 * One torner data sector seen in the stream, for bio containment.
 *
 * This needs no journal format knowledge at all: the workload's sectors say
 * which atomic unit and which version they belong to, so the question "did all
 * k blocks of one application write travel together?" can be answered straight
 * off the log, for any file system.
 */
struct appsec {
	uint64_t page_id;
	uint64_t version;
	uint64_t entry_idx;
	uint64_t epoch;
	uint64_t fepoch;
	uint64_t lba;		/* the block it sits in */
	uint32_t sector_idx;
	uint32_t spu;
};

/* A block write that belongs to a durable unit, for I5: a tau transaction
 * (unit = its commit's index in jb[]) or a jbd2 transaction (unit = its tid,
 * entry = where its descriptor was logged). */
struct owner {
	uint64_t lba;
	uint64_t entry_idx;
	uint64_t unit;
};

struct region {
	uint64_t start;		/* first block */
	uint64_t end;		/* one past last */
};

struct ctx {
	enum dialect dia;
	enum hostlog host;
	int	 i1_strict;	/* judge on the record's own flush only */
	int	 debug;		/* TORNER_LOGINV_DEBUG: say why, on stderr */
	uint32_t fsblk;
	uint32_t sectorsize;

	/* journal geometry, discovered in passes 1 and 2 */
	int	 have_geom;
	uint64_t sb_lba;	/* tau superblock == j_blk_offset */
	uint64_t seg_blks;	/* blocks per segment */
	uint64_t map_nr;	/* segment map blocks after the superblock */
	uint64_t maplog_pba, maplog_len;
	struct region *regions;
	size_t	 nregions, regions_cap;
	uint64_t *idx2pba;	/* map entry -> segment, as the log goes */
	size_t	 idx_n;

	struct jblk *jb;	size_t jb_n, jb_cap;
	struct wr *jw;		size_t jw_n, jw_cap;	/* inside journal segments */
	struct wr *hw;		size_t hw_n, hw_cap;	/* to HOME-tagged blocks */
	uint64_t *home;		size_t home_n, home_cap;
	uint64_t *homeset;	size_t homeset_n;	/* sorted, unique */
	struct hcommit *hc;	size_t hc_n, hc_cap;
	struct segfree *sf;	size_t sf_n, sf_cap;
	struct claimw *cw;	size_t cw_n, cw_cap;
	uint64_t *jtag;		size_t jtag_n, jtag_cap;	/* journal tags' home blocks */
	struct rtag *rt;	size_t rt_n, rt_cap;
	struct sbwrite *sbw;	size_t sbw_n, sbw_cap;
	struct mapwrite *mw;	size_t mw_n, mw_cap;
	struct mapent *ment;	size_t ment_n, ment_cap;
	struct claiment *ce;	size_t ce_n, ce_cap;
	struct mlwrite *mlw;	size_t mlw_n, mlw_cap;
	uint64_t *idx2ino;	/* map entry -> its owner, as the log goes */
	struct txinfo *tx;	size_t tx_n, tx_cap;
	uint64_t *txjt;		size_t txjt_n, txjt_cap;
	size_t	 *txrt;		size_t txrt_n, txrt_cap;
	size_t	 *txof;		/* commit in jb[] -> its tx[], or SIZE_MAX */
	size_t	 *cix, *cpos, nc;	/* commits by (inode, serial, entry) */
	struct appsec *as;	size_t as_n, as_cap;
	struct owner *own;	size_t own_n, own_cap;	/* I5: block writes -> unit */

	/* ext4 data=journal: the jbd2 journal, for I5 */
	int	 have_jgeom;
	uint64_t jsb_lba, jmaxlen, jfirst;
	uint32_t jincompat;
	uint64_t n_jdesc, n_jcommit;
	int64_t	 begin_entry;	/* the torner:begin mark: gen's timed run starts */

	uint64_t entries, epochs, last_epoch;
	uint64_t fepochs, last_fepoch;
	uint64_t n_flush, n_fua, n_discard, n_mark, n_meta;
	uint64_t n_desc, n_commit, n_revoke, n_foreign, n_maplog;
	uint64_t bytes_data;
};

static void *xrealloc(void *p, size_t n)
{
	void *q = realloc(p, n ? n : 1);

	if (!q) {
		fprintf(stderr, "torner loginv: out of memory\n");
		exit(1);
	}
	return q;
}

#define GROW(arr, n, cap, first) do {					\
	if ((n) == (cap)) {						\
		(cap) = (cap) ? (cap) * 2 : (first);			\
		(arr) = xrealloc((arr), (cap) * sizeof(*(arr)));	\
	}								\
} while (0)

/* ---- geometry ----------------------------------------------------------- */

static void add_region(struct ctx *c, uint64_t start, uint64_t len)
{
	GROW(c->regions, c->nregions, c->regions_cap, 64);
	c->regions[c->nregions].start = start;
	c->regions[c->nregions].end = start + len;
	c->nregions++;
}

static int region_cmp(const void *x, const void *y)
{
	const struct region *a = x, *b = y;

	if (a->start != b->start)
		return a->start < b->start ? -1 : 1;
	return 0;
}

/* Sort, and fold the duplicates: a segment is named by every map block write
 * and every claim that mentions it. */
static void finish_regions(struct ctx *c)
{
	size_t i, n = 0;

	if (!c->nregions)
		return;
	qsort(c->regions, c->nregions, sizeof(*c->regions), region_cmp);
	for (i = 0; i < c->nregions; i++) {
		if (n && c->regions[n - 1].start == c->regions[i].start) {
			if (c->regions[i].end > c->regions[n - 1].end)
				c->regions[n - 1].end = c->regions[i].end;
			continue;
		}
		c->regions[n++] = c->regions[i];
	}
	c->nregions = n;
}

/* The journal segment holding @lba, or -1. */
static long seg_of(const struct ctx *c, uint64_t lba)
{
	size_t lo = 0, hi = c->nregions;

	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;

		if (c->regions[mid].start <= lba)
			lo = mid + 1;
		else
			hi = mid;
	}
	if (lo && lba < c->regions[lo - 1].end)
		return (long)(lo - 1);
	return -1;
}

static int in_journal(const struct ctx *c, uint64_t lba)
{
	return seg_of(c, lba) >= 0;
}

/*
 * Is this block the tau journal superblock?
 *
 * jbd2's superblock shares the first 48 bytes of layout, so the discriminator
 * has to be a field only tau has: s_segment_size, which jbd2 leaves inside
 * s_padding and therefore reads as zero.  Anchor on a sane blocksize too.
 */
static int is_tau_superblock(const uint8_t *b, uint64_t *seg_size)
{
	uint32_t bt = be32_at(b, TAU_HDR_OFF_BLOCKTYPE);
	uint32_t bs = be32_at(b, TAU_SB_OFF_BLOCKSIZE);
	uint32_t ss = be32_at(b, TAU_SB_OFF_SEGMENT_SIZE);
	uint32_t maxlen = be32_at(b, TAU_SB_OFF_MAXLEN);

	/*
	 * Block type first.  Without it a jbd2 *descriptor* can match: its tag
	 * array starts at offset 12, so a tag naming block 4096 reads as
	 * s_blocksize, and another tag can land on a power of two where
	 * s_segment_size lives.  That false positive was observed on a stock
	 * ext4 capture before this check existed.
	 */
	if (bt != TAU_SUPERBLOCK_BLOCKTYPE)
		return 0;
	if (bs != TAU_BLOCK_SIZE)
		return 0;
	if (!maxlen)
		return 0;
	if (ss < TAU_SEGMENT_SIZE_MIN_U32 || ss > TAU_SEGMENT_SIZE_MAX_U32)
		return 0;
	if (ss & (ss - 1))		/* segment size is a power of two */
		return 0;
	*seg_size = ss;
	return 1;
}

static void find_jbd2_sb(struct ctx *c, const uint8_t *b, uint64_t lba);

static int is_map_block(const struct ctx *c, uint64_t lba)
{
	return c->have_geom && lba > c->sb_lba && lba <= c->sb_lba + c->map_nr;
}

/*
 * Pass 1 -- the tau superblock.  It names the segment size and, in s_maxlen,
 * the journal file's length: the superblock and the segment map, so the map
 * is s_maxlen - 1 blocks (fs/taujournal/journal.c:1053).  Reading a fixed 64
 * blocks instead took whatever follows the journal file for map entries: on
 * tau-xfs that was 54,913 "segments" for a journal of 8.
 */
static void pass_sb(struct ctx *c, const uint8_t *buf, uint64_t bytes,
		    uint64_t first_lba, uint64_t idx, uint64_t fepoch, int fua)
{
	uint64_t off;

	for (off = 0; off + c->fsblk <= bytes; off += c->fsblk) {
		const uint8_t *b = buf + off;
		uint64_t lba = first_lba + off / c->fsblk;
		uint64_t segsz, pba;

		if (be32_at(b, TAU_HDR_OFF_MAGIC) != TAU_MAGIC_NUMBER)
			continue;
		if (c->dia == DIA_JBD2) {
			find_jbd2_sb(c, b, lba);
			continue;
		}
		if (!is_tau_superblock(b, &segsz))
			continue;
		if (!c->have_geom) {
			uint32_t maxlen = be32_at(b, TAU_SB_OFF_MAXLEN);

			c->sb_lba = lba;
			c->seg_blks = segsz / TAU_BLOCK_SIZE;
			c->map_nr = maxlen > 1 ? maxlen - 1 : TAU_SEGMAP_SCAN_MAX;
			if (c->map_nr > TAU_SEGMAP_SCAN_MAX)
				c->map_nr = TAU_SEGMAP_SCAN_MAX;
			c->have_geom = 1;
		} else if (lba != c->sb_lba) {
			continue;
		}
		/* the kernel fills the map log's place in at mount */
		pba = be64_at(b, TAU_SB_OFF_MAPLOG_PBA);
		if (pba) {
			c->maplog_pba = pba;
			c->maplog_len = be32_at(b, TAU_SB_OFF_MAPLOG_LEN);
		}
	}
}

/*
 * Pass 2 -- where the journal's segments physically live: every segment any
 * write of the segment map names, and every segment a map log CLAIM enters.
 * Segments are allocated dynamically (fs/taujournal/journal.c: jballoc), so
 * this cannot be a constant.
 */
static void pass_map(struct ctx *c, const uint8_t *buf, uint64_t bytes,
		     uint64_t first_lba, uint64_t idx, uint64_t fepoch, int fua)
{
	uint64_t off;

	for (off = 0; off + c->fsblk <= bytes; off += c->fsblk) {
		const uint8_t *b = buf + off;
		uint64_t lba = first_lba + off / c->fsblk;
		uint32_t e, nr;

		if (is_map_block(c, lba)) {
			for (e = 0; e < TAU_SEGMENT_ENT_MAX; e++) {
				uint64_t pba = be64_at(b, (size_t)e * 16);

				if (pba)
					add_region(c, pba, c->seg_blks);
			}
			continue;
		}
		if (be32_at(b, TAU_HDR_OFF_MAGIC) != TAU_MAGIC_NUMBER ||
		    be32_at(b, TAU_HDR_OFF_BLOCKTYPE) != TAU_MAPLOG_BLOCK ||
		    be16_at(b, TAU_MAPLOG_OFF_KIND) != TAU_MAPLOG_CLAIM)
			continue;
		nr = be16_at(b, TAU_MAPLOG_OFF_NR);
		if (nr > TAU_MAPLOG_ENT_MAX)
			continue;
		for (e = 0; e < nr; e++) {
			size_t o = TAU_MAPLOG_HDR_SIZE + (size_t)e * TAU_MAPLOG_ENT_SIZE;
			uint64_t pba = be64_at(b, o + 8);

			if (pba)
				add_region(c, pba, c->seg_blks);
		}
	}
}

/* ---- pass 3: classification --------------------------------------------- */

static void jb_add(struct ctx *c, const struct jblk *j)
{
	GROW(c->jb, c->jb_n, c->jb_cap, 1024);
	c->jb[c->jb_n++] = *j;
}

static void wr_add(struct wr **arr, size_t *n, size_t *cap, uint64_t lba,
		   uint64_t idx, uint64_t fepoch, int fua)
{
	if (*n == *cap) {
		*cap = *cap ? *cap * 2 : 4096;
		*arr = xrealloc(*arr, *cap * sizeof(**arr));
	}
	(*arr)[*n].lba = lba;
	(*arr)[*n].entry_idx = idx;
	(*arr)[*n].fepoch = fepoch;
	(*arr)[*n].fua = fua ? 1 : 0;
	(*n)++;
}

static void hc_add(struct ctx *c, uint64_t key, uint64_t idx, uint64_t fepoch)
{
	GROW(c->hc, c->hc_n, c->hc_cap, 1024);
	c->hc[c->hc_n].key = key;
	c->hc[c->hc_n].entry_idx = idx;
	c->hc[c->hc_n].fepoch = fepoch;
	c->hc_n++;
}

static void sf_add(struct ctx *c, uint64_t pba, uint64_t seq, uint64_t idx,
		   uint64_t fepoch)
{
	GROW(c->sf, c->sf_n, c->sf_cap, 256);
	c->sf[c->sf_n].pba = pba;
	c->sf[c->sf_n].seq = seq;
	c->sf[c->sf_n].entry_idx = idx;
	c->sf[c->sf_n].fepoch = fepoch;
	c->sf_n++;
}

static void as_add(struct ctx *c, const struct appsec *a)
{
	GROW(c->as, c->as_n, c->as_cap, 8192);
	c->as[c->as_n++] = *a;
}

static void own_add(struct ctx *c, uint64_t lba, uint64_t idx, uint64_t unit)
{
	GROW(c->own, c->own_n, c->own_cap, 4096);
	c->own[c->own_n].lba = lba;
	c->own[c->own_n].entry_idx = idx;
	c->own[c->own_n].unit = unit;
	c->own_n++;
}

/*
 * The workload's sectors in one payload.  A sector of an atomic unit can be
 * smaller than a block (a 2 KiB append uses 512-byte sectors), so look at
 * every 512-byte boundary, not only at block starts, and take a sector only
 * if it verifies as atoms takes it (src/atoms.c, scan_entries): header sane,
 * CRC over the sector, fill matching its version.  A copy that did not fully
 * land fails to verify and is not counted.
 */
static void scan_appsecs(struct ctx *c, const uint8_t *buf, uint64_t bytes,
			 uint64_t first_lba, uint64_t idx, uint64_t fepoch)
{
	uint64_t off = 0;

	while (off + sizeof(struct torner_sector_hdr) <= bytes) {
		struct torner_sector_hdr hdr, h;
		struct appsec a;

		memcpy(&hdr, buf + off, sizeof(hdr));
		if (hdr.magic != TORNER_SECTOR_MAGIC ||
		    hdr.sector_size < 512 || hdr.sector_size > TORNER_DEF_SECTOR ||
		    hdr.sector_size % 512 || off + hdr.sector_size > bytes ||
		    torner_verify_sector(buf + off, hdr.sector_size, hdr.page_id,
					 hdr.sector_idx, 0, &h) != TORNER_SEC_OK ||
		    !h.sectors_per_unit ||
		    h.sectors_per_unit > TORNER_MAX_SECTORS_PER_UNIT ||
		    h.sector_idx >= h.sectors_per_unit) {
			off += 512;
			continue;
		}
		a.page_id = h.page_id;
		a.version = h.version;
		a.sector_idx = h.sector_idx;
		a.spu = h.sectors_per_unit;
		a.entry_idx = idx;
		a.epoch = c->epochs;
		a.fepoch = fepoch;
		a.lba = first_lba + off / c->fsblk;
		as_add(c, &a);
		off += h.sector_size;
	}
}

static int appsec_cmp(const void *x, const void *y)
{
	const struct appsec *a = x, *b = y;

	if (a->page_id != b->page_id) return a->page_id < b->page_id ? -1 : 1;
	if (a->version != b->version) return a->version < b->version ? -1 : 1;
	if (a->entry_idx != b->entry_idx) return a->entry_idx < b->entry_idx ? -1 : 1;
	if (a->sector_idx != b->sector_idx) return a->sector_idx < b->sector_idx ? -1 : 1;
	return 0;
}

/*
 * A descriptor's tags, walked as recovery walks them
 * (fs/taujournal/recovery.c:248, count_tags): from offset 32 to the serial at
 * the end, a zero block number or TAU_TAG_LAST ending the list, a 16-byte UUID
 * after every tag without TAU_TAG_SAME_UUID.  Only the HOME tags are kept:
 * their blocks went straight home and take no journal block, so they lie
 * outside the transaction's journal extent.
 */
static void parse_tags(struct ctx *c, const uint8_t *b, struct jblk *j)
{
	size_t off = TAU_HDR_SIZE, end = TAU_BLOCK_SIZE - TAU_DESC_SERIAL_FROM_END;

	j->home_first = (uint32_t)c->home_n;
	j->home_n = 0;
	j->jtag_first = (uint32_t)c->jtag_n;
	j->jtag_n = 0;
	while (off + TAU_TAG_SIZE <= end) {
		uint64_t blk = ((uint64_t)be32_at(b, off + TAU_TAG_OFF_HIGH) << 32) |
			       be32_at(b, off + TAU_TAG_OFF_BLOCKNR);
		uint16_t fl = be16_at(b, off + TAU_TAG_OFF_FLAGS);

		if (!blk)
			break;
		if (fl & TAU_TAG_HOME) {
			GROW(c->home, c->home_n, c->home_cap, 1024);
			c->home[c->home_n++] = blk;
			j->home_n++;
		} else {
			/* a journal copy standing for home block blk */
			GROW(c->jtag, c->jtag_n, c->jtag_cap, 1024);
			c->jtag[c->jtag_n++] = blk;
			j->jtag_n++;
		}
		off += TAU_TAG_SIZE;
		if (!(fl & TAU_TAG_SAME_UUID))
			off += 16;
		if (fl & TAU_TAG_LAST)
			break;
	}
}

/*
 * A write of the segment map, in log order: which segment each entry names,
 * and for whom.  An entry that stops naming its owner is a snapshot dropping
 * that segment, which ends its ownership as a FREE does (fs/taujournal/
 * journal.c: a snapshot is all map blocks PREFLUSH|FUA, waited, before the
 * superblock moves s_maplog_base).
 */
static void track_map_block(struct ctx *c, const uint8_t *b, uint64_t lba,
			    uint64_t idx, uint64_t fepoch, int fua)
{
	size_t base = (size_t)(lba - c->sb_lba - 1) * TAU_SEGMENT_ENT_MAX;
	struct mapwrite m;
	uint32_t e;

	memset(&m, 0, sizeof(m));
	m.entry_idx = idx;
	m.fepoch = fepoch;
	m.fua = fua ? 1 : 0;
	m.ent_first = (uint32_t)c->ment_n;
	for (e = 0; e < TAU_SEGMENT_ENT_MAX && base + e < c->idx_n; e++) {
		uint64_t pba = be64_at(b, (size_t)e * 16);
		uint64_t ino = be64_at(b, (size_t)e * 16 + 8);
		uint64_t opba = c->idx2pba[base + e], oino = c->idx2ino[base + e];

		/* the owner it named is gone: the segment's ownership ended */
		if (opba && oino && (pba != opba || ino != oino))
			sf_add(c, opba, UINT64_MAX - idx, idx, fepoch);
		/* a segment the map names before any claim of it in the log was
		 * published there: for I4 (a), a claim at this write (seq 0) */
		if (pba && !opba) {
			GROW(c->ce, c->ce_n, c->ce_cap, 256);
			c->ce[c->ce_n].pba = pba;
			c->ce[c->ce_n].ino = 0;
			c->ce[c->ce_n].seq = 0;
			c->ce[c->ce_n].entry_idx = idx;
			c->ce_n++;
		}
		c->idx2pba[base + e] = pba;
		c->idx2ino[base + e] = ino;
		if (pba && ino) {
			GROW(c->ment, c->ment_n, c->ment_cap, 256);
			c->ment[c->ment_n].pba = pba;
			c->ment[c->ment_n].ino = ino;
			c->ment_n++;
			m.ent_n++;
		}
	}
	GROW(c->mw, c->mw_n, c->mw_cap, 16);
	c->mw[c->mw_n++] = m;
}

/*
 * A map log block.  A CLAIM moves a map entry onto a segment; a FREE ends the
 * segment's ownership, and one with e_pba 0 gives it back to the host too
 * (fs/taujournal/journal.c, tau_journal_maybe_shrink), so its segment is the
 * one the entry named until then.
 */
static void track_maplog_block(struct ctx *c, const uint8_t *b, uint64_t lba,
			       uint64_t idx, uint64_t fepoch, int fua)
{
	uint32_t kind = be16_at(b, TAU_MAPLOG_OFF_KIND);
	uint32_t nr = be16_at(b, TAU_MAPLOG_OFF_NR), e;
	uint64_t seq = be64_at(b, TAU_MAPLOG_OFF_SEQ);

	if (nr > TAU_MAPLOG_ENT_MAX)
		return;
	GROW(c->mlw, c->mlw_n, c->mlw_cap, 256);
	c->mlw[c->mlw_n].lba = lba;
	c->mlw[c->mlw_n].seq = seq;
	c->mlw[c->mlw_n].entry_idx = idx;
	c->mlw[c->mlw_n].jgen = be32_at(b, TAU_MAPLOG_OFF_JGEN);
	c->mlw_n++;
	if (kind == TAU_MAPLOG_CLAIM) {
		GROW(c->cw, c->cw_n, c->cw_cap, 256);
		c->cw[c->cw_n].seq = seq;
		c->cw[c->cw_n].w.lba = lba;
		c->cw[c->cw_n].w.entry_idx = idx;
		c->cw[c->cw_n].w.fepoch = fepoch;
		c->cw[c->cw_n].w.fua = fua ? 1 : 0;
		c->cw_n++;
	}
	for (e = 0; e < nr; e++) {
		size_t o = TAU_MAPLOG_HDR_SIZE + (size_t)e * TAU_MAPLOG_ENT_SIZE;
		uint32_t index = be32_at(b, o);
		uint64_t pba = be64_at(b, o + 8);

		if (kind == TAU_MAPLOG_CLAIM) {
			uint64_t ino = be64_at(b, o + 16);

			if (index < c->idx_n) {
				c->idx2pba[index] = pba;
				c->idx2ino[index] = ino;
			}
			GROW(c->ce, c->ce_n, c->ce_cap, 256);
			c->ce[c->ce_n].pba = pba;
			c->ce[c->ce_n].ino = ino;
			c->ce[c->ce_n].seq = seq;
			c->ce[c->ce_n].entry_idx = idx;
			c->ce_n++;
		} else if (kind == TAU_MAPLOG_FREE) {
			uint64_t p = pba;

			if (!p && index < c->idx_n)
				p = c->idx2pba[index];
			if (index < c->idx_n) {
				if (!pba)
					c->idx2pba[index] = 0;
				c->idx2ino[index] = 0;
			}
			if (p)
				sf_add(c, p, seq, idx, fepoch);
		}
	}
}

/*
 * XFS log record headers sit on 512-byte boundaries, not block ones.  A
 * header is taken only if its LSN's cycle is its own h_cycle: every other
 * 512-byte sector of a log record starts with the cycle number instead
 * (xlog_pack_data), so the magic cannot occur there.
 */
static void scan_xlog(struct ctx *c, const uint8_t *buf, uint64_t bytes,
		      uint64_t idx, uint64_t fepoch)
{
	uint64_t off;

	for (off = 0; off + XLOG_BBSIZE <= bytes; off += XLOG_BBSIZE) {
		const uint8_t *p = buf + off;
		uint32_t ver;
		uint64_t lsn;

		if (be32_at(p, 0) != XLOG_HEADER_MAGIC)
			continue;
		ver = be32_at(p, XLOG_OFF_VERSION);
		lsn = be64_at(p, XLOG_OFF_LSN);
		if (ver != 1 && ver != 2)
			continue;
		if ((lsn >> 32) != be32_at(p, XLOG_OFF_CYCLE) ||
		    !be32_at(p, XLOG_OFF_LEN))
			continue;
		hc_add(c, lsn, idx, fepoch);
	}
}

/*
 * ext4 data=journal: jbd2's own journal, for I5.  The superblock
 * (include/linux/jbd2.h: blocktype 3 or 4, s_blocksize@12, s_maxlen@16,
 * s_first@20, s_feature_incompat@0x28 in a V2 one) sits at journal block 0;
 * an internal journal that mke2fs laid out contiguously then occupies
 * [superblock, superblock + s_maxlen).  tau's superblock has the same shape
 * but a non-zero s_segment_size, which jbd2 leaves in its padding.
 */
#define JBD2_DESCRIPTOR_TYPE		1
#define JBD2_SB_V1			3
#define JBD2_SB_V2			4
#define JBD2_SB_OFF_INCOMPAT		0x28
#define JBD2_INCOMPAT_64BIT		0x2
#define JBD2_INCOMPAT_CSUM_V2		0x8
#define JBD2_INCOMPAT_CSUM_V3		0x10
#define JBD2_FLAG_SAME_UUID		2
#define JBD2_FLAG_LAST_TAG		8
#define JBD2_HDR_SIZE			12

static void find_jbd2_sb(struct ctx *c, const uint8_t *b, uint64_t lba)
{
	uint32_t bt = be32_at(b, TAU_HDR_OFF_BLOCKTYPE);

	if (bt != JBD2_SB_V1 && bt != JBD2_SB_V2)
		return;
	if (be32_at(b, TAU_SB_OFF_BLOCKSIZE) != c->fsblk ||
	    !be32_at(b, TAU_SB_OFF_MAXLEN) ||
	    be32_at(b, TAU_SB_OFF_SEGMENT_SIZE))
		return;
	/*
	 * The last write of it counts: mke2fs leaves the features 0 and the
	 * mount sets the ones the tags depend on (ext4 turns on CSUM_V3 and
	 * 64BIT with metadata_csum, which makes every tag 16 bytes), before any
	 * descriptor is written.
	 */
	if (c->have_jgeom && lba != c->jsb_lba)
		return;
	c->jsb_lba = lba;
	c->jmaxlen = be32_at(b, TAU_SB_OFF_MAXLEN);
	c->jfirst = be32_at(b, TAU_SB_OFF_FIRST);
	c->jincompat = bt == JBD2_SB_V2 ? be32_at(b, JBD2_SB_OFF_INCOMPAT) : 0;
	if (!c->jfirst || c->jfirst >= c->jmaxlen)
		c->jfirst = 1;
	c->have_jgeom = 1;
}

/* fs/jbd2/journal.c:2692, journal_tag_bytes() */
static size_t jbd2_tag_bytes(uint32_t incompat)
{
	size_t sz = 12;		/* sizeof(journal_block_tag_t) */

	if (incompat & JBD2_INCOMPAT_CSUM_V3)
		return 16;	/* sizeof(journal_block_tag3_t) */
	if (incompat & JBD2_INCOMPAT_CSUM_V2)
		sz += 2;
	return (incompat & JBD2_INCOMPAT_64BIT) ? sz : sz - 4;
}

static int in_jbd2(const struct ctx *c, uint64_t lba)
{
	return c->have_jgeom && lba >= c->jsb_lba && lba < c->jsb_lba + c->jmaxlen;
}

/*
 * A jbd2 descriptor names, tag by tag, the journal blocks that follow it, so
 * each of them gets the descriptor's tid -- walked as jbd2's recovery walks it
 * (fs/jbd2/recovery.c, count_tags: tags to the block tail, a UUID after any
 * tag without SAME_UUID, LAST_TAG ending the list; t_flags read as the be16 at
 * offset 6, the low half of tag3's be32), wrapping from s_maxlen to s_first.
 */
static void scan_jbd2(struct ctx *c, const uint8_t *buf, uint64_t bytes,
		      uint64_t first_lba, uint64_t idx)
{
	uint64_t off;

	for (off = 0; off + c->fsblk <= bytes; off += c->fsblk) {
		const uint8_t *b = buf + off;
		uint64_t lba = first_lba + off / c->fsblk;
		size_t tb, end, t;
		uint64_t jb, k = 0;
		uint32_t bt;

		if (!in_jbd2(c, lba) || lba == c->jsb_lba ||
		    be32_at(b, TAU_HDR_OFF_MAGIC) != TAU_MAGIC_NUMBER)
			continue;
		bt = be32_at(b, TAU_HDR_OFF_BLOCKTYPE);
		if (bt == JBD2_COMMIT_BLOCK_TYPE)
			c->n_jcommit++;
		if (bt != JBD2_DESCRIPTOR_TYPE)
			continue;
		c->n_jdesc++;
		tb = jbd2_tag_bytes(c->jincompat);
		end = c->fsblk - ((c->jincompat & (JBD2_INCOMPAT_CSUM_V2 |
						   JBD2_INCOMPAT_CSUM_V3)) ? 4 : 0);
		jb = lba - c->jsb_lba;
		for (t = JBD2_HDR_SIZE; t + tb <= end; ) {
			uint16_t fl = be16_at(b, t + 6);
			uint64_t x = jb + 1 + k++;

			while (x >= c->jmaxlen)
				x = x - c->jmaxlen + c->jfirst;
			own_add(c, c->jsb_lba + x, idx,
				be32_at(b, TAU_HDR_OFF_SEQUENCE));
			t += tb;
			if (!(fl & JBD2_FLAG_SAME_UUID))
				t += 16;
			if (fl & JBD2_FLAG_LAST_TAG)
				break;
		}
	}
}

/* Pass 3 -- classify blocks, record journal-region writes and host commits. */
static void pass_classify(struct ctx *c, const uint8_t *buf, uint64_t bytes,
			  uint64_t first_lba, uint64_t idx, uint64_t fepoch,
			  int fua)
{
	uint64_t off;

	if (c->host == HOST_XFS)
		scan_xlog(c, buf, bytes, idx, fepoch);
	scan_appsecs(c, buf, bytes, first_lba, idx, fepoch);
	if (c->dia == DIA_JBD2) {
		scan_jbd2(c, buf, bytes, first_lba, idx);
		return;
	}

	for (off = 0; off + c->fsblk <= bytes; off += c->fsblk) {
		const uint8_t *b = buf + off;
		uint64_t lba = first_lba + off / c->fsblk;
		struct jblk j;
		uint32_t bt;
		int mine;

		mine = in_journal(c, lba);
		if (mine)
			wr_add(&c->jw, &c->jw_n, &c->jw_cap, lba, idx, fepoch, fua);

		if (is_map_block(c, lba)) {
			track_map_block(c, b, lba, idx, fepoch, fua);
			continue;
		}
		if (be32_at(b, TAU_HDR_OFF_MAGIC) != TAU_MAGIC_NUMBER)
			continue;
		if (c->have_geom && lba == c->sb_lba) {
			/* where the map log's base was, for I4 */
			GROW(c->sbw, c->sbw_n, c->sbw_cap, 16);
			c->sbw[c->sbw_n].entry_idx = idx;
			c->sbw[c->sbw_n].fepoch = fepoch;
			c->sbw[c->sbw_n].base = be64_at(b, TAU_SB_OFF_MAPLOG_BASE);
			c->sbw[c->sbw_n].sequence = be32_at(b, TAU_SB_OFF_SEQUENCE);
			c->sbw[c->sbw_n].fua = fua ? 1 : 0;
			c->sbw_n++;
			continue;
		}
		bt = be32_at(b, TAU_HDR_OFF_BLOCKTYPE);

		if (bt == TAU_MAPLOG_BLOCK) {
			track_maplog_block(c, b, lba, idx, fepoch, fua);
			c->n_maplog++;
			continue;
		}

		/*
		 * Outside the journal extents this magic belongs to some other
		 * journal (jbd2 on a tau-ext4 stack).  Count it so coverage is
		 * visible, but never assert tau invariants on it.  jbd2's
		 * commit blocks are what gate tau-ext4's flush-less records.
		 */
		if (!mine) {
			if (c->host == HOST_JBD2 && bt == JBD2_COMMIT_BLOCK_TYPE)
				hc_add(c, be32_at(b, TAU_HDR_OFF_SEQUENCE), idx, fepoch);
			c->n_foreign++;
			continue;
		}

		memset(&j, 0, sizeof(j));
		j.lba = lba;
		j.entry_idx = idx;
		j.fepoch = fepoch;
		j.fua = fua ? 1 : 0;
		j.blocktype = bt;
		j.sequence = be32_at(b, TAU_HDR_OFF_SEQUENCE);
		j.next_segment = be64_at(b, TAU_HDR_OFF_NEXT_SEGMENT);
		j.inode_number = be64_at(b, TAU_HDR_OFF_INODE_NUMBER);

		switch (bt) {
		case TAU_DESCRIPTOR_BLOCK:
			j.serial = be64_at(b, TAU_BLOCK_SIZE - TAU_DESC_SERIAL_FROM_END);
			parse_tags(c, b, &j);
			c->n_desc++;
			break;
		case TAU_COMMIT_BLOCK:
			j.serial = be64_at(b, TAU_COMMIT_OFF_SERIAL);
			j.commit_epoch_field = be64_at(b, TAU_COMMIT_OFF_EPOCH);
			j.commit_flags = be32_at(b, TAU_COMMIT_OFF_FLAGS);
			if (j.commit_flags & TAU_COMMIT_F_MAPLOG) {
				j.maplog_seq = be64_at(b, TAU_COMMIT_OFF_MAPLOG);
				j.maplog_nr = be32_at(b, TAU_COMMIT_OFF_MAPLOG_NR);
			}
			if (j.commit_flags & TAU_COMMIT_F_TAIL) {
				j.jgen = be32_at(b, TAU_COMMIT_OFF_JGEN);
				j.tail_tid = be32_at(b, TAU_COMMIT_OFF_TAIL_TID);
				j.tail_blk = be64_at(b, TAU_COMMIT_OFF_TAIL_BLK);
			}
			c->n_commit++;
			break;
		case TAU_REVOKE_BLOCK: {
			uint32_t n = be32_at(b, TAU_REVOKE_OFF_NUM_TAGS), t;
			uint32_t fl = (uint32_t)be64_at(b, TAU_REVOKE_OFF_FLAGS);

			if (n > (TAU_BLOCK_SIZE - TAU_REVOKE_META_SIZE) / TAU_REVOKE_TAG_SIZE)
				n = (TAU_BLOCK_SIZE - TAU_REVOKE_META_SIZE) / TAU_REVOKE_TAG_SIZE;
			for (t = 0; t < n; t++) {
				size_t o = TAU_REVOKE_META_SIZE + (size_t)t * TAU_REVOKE_TAG_SIZE;

				GROW(c->rt, c->rt_n, c->rt_cap, 256);
				c->rt[c->rt_n].lba = lba;
				c->rt[c->rt_n].entry_idx = idx;
				c->rt[c->rt_n].scope = be64_at(b, o);
				c->rt[c->rt_n].pblk = be64_at(b, o + 8);
				c->rt[c->rt_n].flags = fl;
				c->rt_n++;
			}
			c->n_revoke++;
			break;
		}
		default:
			c->n_foreign++;
			continue;
		}
		jb_add(c, &j);
	}
}

static int u64_cmp(const void *x, const void *y)
{
	uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;

	return a < b ? -1 : a > b;
}

static int in_homeset(const struct ctx *c, uint64_t lba)
{
	size_t lo = 0, hi = c->homeset_n;

	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;

		if (c->homeset[mid] < lba)
			lo = mid + 1;
		else
			hi = mid;
	}
	return lo < c->homeset_n && c->homeset[lo] == lba;
}

/* Pass 4 -- every write to a block some descriptor tagged HOME. */
static void pass_home(struct ctx *c, const uint8_t *buf, uint64_t bytes,
		      uint64_t first_lba, uint64_t idx, uint64_t fepoch, int fua)
{
	uint64_t off;

	for (off = 0; off + c->fsblk <= bytes; off += c->fsblk) {
		uint64_t lba = first_lba + off / c->fsblk;

		if (in_homeset(c, lba))
			wr_add(&c->hw, &c->hw_n, &c->hw_cap, lba, idx, fepoch, fua);
	}
}

/* ---- the log walk ------------------------------------------------------- */

typedef void (*walk_fn)(struct ctx *c, const uint8_t *buf, uint64_t bytes,
			uint64_t first_lba, uint64_t idx, uint64_t fepoch,
			int fua);

struct walkbuf {
	uint8_t *hdr;
	uint8_t *data;
	size_t	 data_cap;
};

/*
 * One pass over the log.  Epochs are recounted every pass, so each pass sees
 * the same numbering; the counters are kept from the classification pass.
 */
static int walk(struct ctx *c, int fd, const struct log_write_super_d *sup,
		walk_fn fn, int count, struct walkbuf *w)
{
	off_t pos = lseek(fd, c->sectorsize, SEEK_SET);

	if (pos < 0)
		return -1;
	c->entries = 0;
	c->epochs = 1;
	c->fepochs = 1;
	if (count) {
		c->n_flush = c->n_fua = c->n_discard = c->n_mark = c->n_meta = 0;
		c->bytes_data = 0;
	}

	while (c->entries < sup->nr_entries) {
		struct log_write_entry_d ent;
		uint64_t bytes, flags;
		ssize_t n;

		n = read(fd, w->hdr, c->sectorsize);
		if (n <= 0)
			break;
		if (n != (ssize_t)c->sectorsize) {
			if (count)
				fprintf(stderr, "torner loginv: truncated"
					" entry header at %" PRIu64 "\n",
					c->entries);
			break;
		}
		memcpy(&ent, w->hdr, sizeof(ent));
		c->entries++;

		flags = ent.flags;
		bytes = ent.nr_sectors * (uint64_t)c->sectorsize;

		/* gen marks where its timed run starts, the only part explore
		 * crashes in; a mark keeps its text in its own header sector */
		if (count && (flags & LOG_MARK_FLAG) && c->begin_entry < 0) {
			size_t len = ent.data_len;

			if (len > c->sectorsize - sizeof(ent))
				len = c->sectorsize - sizeof(ent);
			if (memmem(w->hdr + sizeof(ent), len, "torner:begin", 12))
				c->begin_entry = (int64_t)(c->entries - 1);
		}
		if (count) {
			if (flags & LOG_FLUSH_FLAG)	c->n_flush++;
			if (flags & LOG_FUA_FLAG)	c->n_fua++;
			if (flags & LOG_DISCARD_FLAG)	c->n_discard++;
			if (flags & LOG_MARK_FLAG)	c->n_mark++;
			if (flags & LOG_METADATA_FLAG)	c->n_meta++;
		}

		/* DISCARD carries no payload; MARK keeps its string in the
		 * header sector, not as a payload block. */
		if (bytes && !(flags & LOG_DISCARD_FLAG)) {
			if (bytes > w->data_cap) {
				w->data_cap = bytes;
				w->data = xrealloc(w->data, w->data_cap);
			}
			if (read(fd, w->data, bytes) != (ssize_t)bytes) {
				if (count)
					fprintf(stderr, "torner loginv:"
						" truncated payload at %"
						PRIu64 "\n", c->entries - 1);
				break;
			}
			if (count)
				c->bytes_data += bytes;

			if (!(flags & LOG_MARK_FLAG))
				fn(c, w->data, bytes,
				   ent.sector * (uint64_t)c->sectorsize / c->fsblk,
				   c->entries - 1, c->fepochs,
				   (flags & LOG_FUA_FLAG) != 0);
		}

		c->last_epoch = c->epochs;
		c->last_fepoch = c->fepochs;
		if (flags & (LOG_FLUSH_FLAG | LOG_FUA_FLAG))
			c->epochs++;
		if (flags & LOG_FLUSH_FLAG)
			c->fepochs++;
	}
	if (c->entries) {
		c->epochs = c->last_epoch;
		c->fepochs = c->last_fepoch;
	}
	return 0;
}

/* ---- violations --------------------------------------------------------- */

struct viol_out {
	uint64_t n;
	uint64_t cap;
	int first;
};

static void viol_open(struct viol_out *v, uint64_t cap)
{
	v->n = 0;
	v->cap = cap;
	v->first = 1;
	printf(",\"violations\":[");
}

static int viol_begin(struct viol_out *v)
{
	v->n++;
	if (v->n > v->cap)
		return 0;
	if (!v->first)
		printf(",");
	v->first = 0;
	return 1;
}

static void viol_close(struct viol_out *v)
{
	printf("]");
}

/* ---- I1 ------------------------------------------------------------------ */

static int wr_cmp(const void *x, const void *y)
{
	const struct wr *a = x, *b = y;

	if (a->lba != b->lba)
		return a->lba < b->lba ? -1 : 1;
	if (a->entry_idx != b->entry_idx)
		return a->entry_idx < b->entry_idx ? -1 : 1;
	return 0;
}

static int hc_cmp(const void *x, const void *y)
{
	const struct hcommit *a = x, *b = y;

	if (a->key != b->key)
		return a->key < b->key ? -1 : 1;
	if (a->entry_idx != b->entry_idx)
		return a->entry_idx < b->entry_idx ? -1 : 1;
	return 0;
}

static int sf_seq_cmp(const void *x, const void *y)
{
	const struct segfree *a = x, *b = y;

	if (a->pba != b->pba)
		return a->pba < b->pba ? -1 : 1;
	if (a->seq != b->seq)
		return a->seq < b->seq ? -1 : 1;
	if (a->entry_idx != b->entry_idx)
		return a->entry_idx < b->entry_idx ? -1 : 1;
	return 0;
}

static int sf_entry_cmp(const void *x, const void *y)
{
	const struct segfree *a = x, *b = y;

	if (a->pba != b->pba)
		return a->pba < b->pba ? -1 : 1;
	if (a->entry_idx != b->entry_idx)
		return a->entry_idx < b->entry_idx ? -1 : 1;
	return 0;
}

/* A map log block logged twice is one FREE: keep its first write. */
static void finish_frees(struct ctx *c)
{
	size_t i, n = 0;

	if (!c->sf_n)
		return;
	qsort(c->sf, c->sf_n, sizeof(*c->sf), sf_seq_cmp);
	for (i = 0; i < c->sf_n; i++) {
		if (n && c->sf[n - 1].pba == c->sf[i].pba &&
		    c->sf[n - 1].seq == c->sf[i].seq)
			continue;
		c->sf[n++] = c->sf[i];
	}
	c->sf_n = n;
	qsort(c->sf, c->sf_n, sizeof(*c->sf), sf_entry_cmp);
}

/*
 * The ownership of segment @pba that log entry @e falls in, as the entries
 * [*lo, *hi): from the FREE before @e to the FREE after it.
 */
static void own_period(const struct ctx *c, uint64_t pba, uint64_t e,
		       uint64_t *lo, uint64_t *hi)
{
	size_t a = 0, b = c->sf_n;

	*lo = 0;
	*hi = UINT64_MAX;
	/* first FREE of this segment at or after entry e */
	while (a < b) {
		size_t mid = a + (b - a) / 2;
		const struct segfree *s = &c->sf[mid];

		if (s->pba < pba || (s->pba == pba && s->entry_idx < e))
			a = mid + 1;
		else
			b = mid;
	}
	if (a < c->sf_n && c->sf[a].pba == pba)
		*hi = c->sf[a].entry_idx;
	if (a > 0 && c->sf[a - 1].pba == pba)
		*lo = c->sf[a - 1].entry_idx + 1;
}

/*
 * The transaction's write of @lba among the writes in entries [lo, hi), the
 * commit being entry @e: the last one logged before the commit, or failing
 * that the first one logged after it -- where a record sent FUA without a
 * preflush leaves its data.  *before and *after count the writes on each side.
 */
static const struct wr *pick_write(const struct wr *a, size_t n, uint64_t lba,
				   uint64_t lo, uint64_t hi, uint64_t e,
				   size_t *before, size_t *after)
{
	const struct wr *out = NULL;
	size_t l = 0, r = n;

	*before = *after = 0;
	while (l < r) {
		size_t mid = l + (r - l) / 2;

		if (a[mid].lba < lba || (a[mid].lba == lba && a[mid].entry_idx < lo))
			l = mid + 1;
		else
			r = mid;
	}
	/* in entry order: every write before @e replaces the pick, and the
	 * first one after @e is taken only if none came before */
	for (; l < n && a[l].lba == lba && a[l].entry_idx < hi; l++) {
		if (a[l].entry_idx < e)
			(*before)++;
		else
			(*after)++;
		if (a[l].entry_idx < e || !out)
			out = &a[l];
	}
	return out;
}

/* The first host commit with @key: jbd2's commit block of tid @key, or the
 * XFS log record at LSN @key. */
static const struct hcommit *host_commit(const struct ctx *c, uint64_t key)
{
	size_t l = 0, r = c->hc_n;

	while (l < r) {
		size_t mid = l + (r - l) / 2;

		if (c->hc[mid].key < key)
			l = mid + 1;
		else
			r = mid;
	}
	return (l < c->hc_n && c->hc[l].key == key) ? &c->hc[l] : NULL;
}

/* Orders for the per-file indexes. */
static const struct ctx *g_c;

static int dix_cmp(const void *x, const void *y)
{
	const struct jblk *a = &g_c->jb[*(const size_t *)x];
	const struct jblk *b = &g_c->jb[*(const size_t *)y];

	if (a->inode_number != b->inode_number)
		return a->inode_number < b->inode_number ? -1 : 1;
	if (a->serial != b->serial)
		return a->serial < b->serial ? -1 : 1;
	if (a->sequence != b->sequence)
		return a->sequence < b->sequence ? -1 : 1;
	if (a->entry_idx != b->entry_idx)
		return a->entry_idx < b->entry_idx ? -1 : 1;
	return 0;
}

static int cix_cmp(const void *x, const void *y)
{
	const struct jblk *a = &g_c->jb[*(const size_t *)x];
	const struct jblk *b = &g_c->jb[*(const size_t *)y];

	if (a->inode_number != b->inode_number)
		return a->inode_number < b->inode_number ? -1 : 1;
	if (a->serial != b->serial)
		return a->serial < b->serial ? -1 : 1;
	if (a->entry_idx != b->entry_idx)
		return a->entry_idx < b->entry_idx ? -1 : 1;
	return 0;
}

static int cw_cmp(const void *x, const void *y)
{
	const struct claimw *a = x, *b = y;

	if (a->seq != b->seq)
		return a->seq < b->seq ? -1 : 1;
	if (a->w.entry_idx != b->w.entry_idx)
		return a->w.entry_idx < b->w.entry_idx ? -1 : 1;
	return 0;
}

/* The first write of the claim block with h_seq @seq, or NULL. */
static const struct wr *claim_write(const struct ctx *c, uint64_t seq)
{
	size_t l = 0, r = c->cw_n;

	while (l < r) {
		size_t mid = l + (r - l) / 2;

		if (c->cw[mid].seq < seq)
			l = mid + 1;
		else
			r = mid;
	}
	return (l < c->cw_n && c->cw[l].seq == seq) ? &c->cw[l].w : NULL;
}

struct i1stat {
	uint64_t checked, skipped_nodesc, skipped_multiseg, two_segment;
	uint64_t claim_blocks;
	uint64_t blocks, home_blocks, missing, ambiguous, home_ambiguous;
	uint64_t own, gated, gate_closed, strict;
	uint64_t viol, viol_ungated;
};

/* One block a transaction vouches for, and the write of it that is the
 * transaction's (NULL: none in the log). */
struct vblk {
	uint64_t lba;
	const struct wr *w;
	uint8_t	 home;
};

/* What the worst block of a transaction was, for the report. */
struct worst {
	int	 have;
	int	 missing;
	int	 home;
	uint64_t lba, entry, fepoch;
};

/* How many of @n blocks are not durable before flush epoch @bound. */
static void judge(const struct vblk *b, size_t n, uint64_t bound,
		  uint64_t *unordered, uint64_t *missing, struct worst *w)
{
	size_t k;

	*unordered = *missing = 0;
	memset(w, 0, sizeof(*w));
	for (k = 0; k < n; k++) {
		const struct wr *x = b[k].w;

		if (x && (x->fua || x->fepoch < bound))
			continue;
		if (!x) {
			(*missing)++;
			if (!w->missing) {
				w->have = w->missing = 1;
				w->home = b[k].home;
				w->lba = b[k].lba;
			}
			continue;
		}
		(*unordered)++;
		if (w->missing)
			continue;	/* a missing block is as bad as it gets */
		if (!w->have || x->fepoch >= w->fepoch) {
			w->have = 1;
			w->home = b[k].home;
			w->lba = b[k].lba;
			w->entry = x->entry_idx;
			w->fepoch = x->fepoch;
		}
	}
}

struct vlist {
	struct vblk *b;
	size_t n, cap;
};

static void vadd(struct vlist *l, uint64_t lba, const struct wr *w, int home)
{
	GROW(l->b, l->n, l->cap, 64);
	l->b[l->n].lba = lba;
	l->b[l->n].w = w;
	l->b[l->n].home = home ? 1 : 0;
	l->n++;
}

/* The journal blocks [from, to) of segment @seg, each with its write. */
static void add_journal_blocks(struct ctx *c, struct vlist *l, struct i1stat *st,
			       long seg, uint64_t from, uint64_t to, uint64_t e)
{
	uint64_t lo, hi, lba;

	own_period(c, c->regions[seg].start, e, &lo, &hi);
	for (lba = from; lba < to; lba++) {
		size_t nb, na;
		const struct wr *x = pick_write(c->jw, c->jw_n, lba, lo, hi, e,
						&nb, &na);

		/* one write per block per ownership */
		if (nb + na > 1) {
			st->ambiguous++;
			if (c->debug)
				fprintf(stderr, "loginv: ambiguous lba %" PRIu64
					" (segment %" PRIu64 ", ownership [%" PRIu64
					", %" PRIu64 ")): %zu writes before commit"
					" entry %" PRIu64 ", %zu after; took entry %"
					PRIu64 "\n", lba, c->regions[seg].start, lo,
					hi, nb, e, na, x->entry_idx);
		}
		vadd(l, lba, x, 0);
	}
}

/*
 * I1 -- every block a transaction commits must be durable before recovery can
 * count its record.  "Durable before" is decided by FLUSH alone: a block d is
 * guaranteed on media ahead of x iff a FLUSH lies between them (fepoch(x) >
 * fepoch(d)), or d itself was written FUA.
 *
 * A record counts once it is durable and, if it names a host epoch (h_epoch),
 * once that host commit is too: tau-ext4's recovery takes it iff jbd2's
 * commit of tid h_epoch is on disk, tau-xfs's iff the XFS log record at LSN
 * h_epoch is.  Since kernel #376 most records go without a flush of their own
 * and rely on exactly that: the host commit goes out behind a flush, over
 * everything the record vouches for (fs/taujournal/commit.c,
 * tau_record_noflush).  So a block must be durable before the record AND the
 * host commit both are, i.e. fepoch(d) < max(fepoch(record), fepoch(host
 * commit)); judged on the record's own flush alone ("strict"), nearly every
 * record of #376 and later fails.
 *
 * A record whose host commit is not in the log at all is never counted by any
 * crash state of this log: that is "gate never open", not a violation.
 *
 * A FUA write is not a barrier -- it makes only itself durable.  An earlier
 * version of this check split epochs on FUA as well (as CrashMonkey's permuter
 * does), and then any unrelated FUA write that happened to fall between a
 * transaction's data and its commit made a commit issued without a preflush
 * look correctly ordered.  The one thing the log cannot show is submission
 * order: a FUA write issued concurrently with a FLUSH, rather than after it
 * completed, is logged the same way.
 *
 * The blocks: from the transaction's first descriptor to its commit in the
 * journal -- descriptors, the data their tags name, revoke blocks -- plus the
 * blocks its descriptors tag HOME, written straight home.  The journal is
 * written linearly through a segment and on at the start of the next one in
 * the transaction's chain (fs/taujournal/commit.c, tau_next_log_block, and
 * h_next_segment = that segment's first block), so a transaction that crossed
 * into a second segment is [first descriptor, end of its segment) plus [start
 * of the commit's segment, commit).  A transaction is (inode, serial,
 * sequence).
 */
static void check_i1(struct ctx *c, struct viol_out *v, struct i1stat *st,
		     int report)
{
	size_t *dix, *cix, *cpos, nd = 0, nc = 0, i, k;
	uint64_t *homes = NULL, *jts = NULL;
	size_t homes_cap = 0, jts_cap = 0;
	struct vlist vl = { NULL, 0, 0 };

	qsort(c->jw, c->jw_n, sizeof(*c->jw), wr_cmp);
	qsort(c->hw, c->hw_n, sizeof(*c->hw), wr_cmp);
	qsort(c->hc, c->hc_n, sizeof(*c->hc), hc_cmp);
	qsort(c->cw, c->cw_n, sizeof(*c->cw), cw_cmp);
	finish_frees(c);

	qsort(c->rt, c->rt_n, sizeof(*c->rt), rt_cmp);
	dix = xrealloc(NULL, (c->jb_n + 1) * sizeof(*dix));
	cix = xrealloc(NULL, (c->jb_n + 1) * sizeof(*cix));
	cpos = xrealloc(NULL, (c->jb_n + 1) * sizeof(*cpos));
	c->txof = xrealloc(NULL, (c->jb_n + 1) * sizeof(*c->txof));
	for (i = 0; i < c->jb_n; i++)
		c->txof[i] = SIZE_MAX;
	for (i = 0; i < c->jb_n; i++) {
		if (c->jb[i].blocktype == TAU_DESCRIPTOR_BLOCK)
			dix[nd++] = i;
		else if (c->jb[i].blocktype == TAU_COMMIT_BLOCK)
			cix[nc++] = i;
	}
	g_c = c;
	qsort(dix, nd, sizeof(*dix), dix_cmp);
	qsort(cix, nc, sizeof(*cix), cix_cmp);
	for (k = 0; k < nc; k++)
		cpos[cix[k]] = k;
	c->cix = cix;
	c->cpos = cpos;
	c->nc = nc;

	for (i = 0; i < c->jb_n; i++) {
		const struct jblk *cm = &c->jb[i];
		uint64_t home_lo = 0, desc_lo = 0, first = UINT64_MAX;
		uint64_t first_a = UINT64_MAX, next_a = 0;
		uint64_t n_home = 0, n_unordered, n_missing, bound;
		size_t nh = 0, in = 0, l, r, p, njt = 0;
		long cseg, aseg = -1;
		int odd = 0, ok;
		const struct hcommit *hcm = NULL;
		struct worst w;
		const char *gate;

		if (cm->blocktype != TAU_COMMIT_BLOCK)
			continue;

		/*
		 * The file's previous commit bounds its HOME blocks from below:
		 * they were allocated for this commit, after that one was done,
		 * and a write before it was someone else's.  Nothing bounds a
		 * transaction from above in log order -- a record sent FUA can
		 * be logged ahead of the file's earlier descriptors -- and none
		 * is needed: (inode, serial, sequence) names one transaction.
		 * Only a journal without serials (before #385) has to bound its
		 * descriptors by the previous commit too.
		 */
		p = cpos[i];
		if (p > 0) {
			const struct jblk *q = &c->jb[cix[p - 1]];

			if (q->inode_number == cm->inode_number && q->serial == cm->serial) {
				home_lo = q->entry_idx + 1;
				if (!cm->serial)
					desc_lo = q->entry_idx + 1;
			}
		}

		cseg = seg_of(c, cm->lba);
		/* this transaction's descriptors: in the commit's segment before
		 * it, or in one segment whose chain leads to the commit's */
		l = 0;
		r = nd;
		while (l < r) {
			size_t mid = l + (r - l) / 2;
			const struct jblk *d = &c->jb[dix[mid]];

			if (d->inode_number < cm->inode_number ||
			    (d->inode_number == cm->inode_number &&
			     (d->serial < cm->serial ||
			      (d->serial == cm->serial && d->sequence < cm->sequence))))
				l = mid + 1;
			else
				r = mid;
		}
		nh = 0;
		njt = 0;
		for (; l < nd; l++) {
			const struct jblk *d = &c->jb[dix[l]];
			long ds;

			if (d->inode_number != cm->inode_number ||
			    d->serial != cm->serial || d->sequence != cm->sequence)
				break;
			if (d->entry_idx < desc_lo)
				continue;
			ds = seg_of(c, d->lba);
			if (ds == cseg) {
				if (d->lba >= cm->lba) {
					odd = 1;
					continue;
				}
				in++;
				if (d->lba < first)
					first = d->lba;
			} else {
				if (aseg >= 0 && ds != aseg) {
					odd = 1;	/* three segments or more */
					continue;
				}
				aseg = ds;
				if (d->lba < first_a) {
					first_a = d->lba;
					next_a = d->next_segment;
				}
			}
			for (k = 0; k < d->home_n; k++) {
				if (nh == homes_cap) {
					homes_cap = homes_cap ? homes_cap * 2 : 64;
					homes = xrealloc(homes, homes_cap * sizeof(*homes));
				}
				homes[nh++] = c->home[d->home_first + k];
			}
			for (k = 0; k < d->jtag_n; k++) {
				GROW(jts, njt, jts_cap, 64);
				jts[njt++] = c->jtag[d->jtag_first + k];
			}
		}
		if (aseg >= 0 && !odd && next_a != c->regions[cseg].start)
			odd = 1;	/* that segment's chain does not lead here */
		if (odd) {
			st->skipped_multiseg++;
			continue;
		}
		if (!in && aseg < 0) {
			/* no descriptor in the log: nothing to say which blocks */
			st->skipped_nodesc++;
			continue;
		}
		st->checked++;

		vl.n = 0;
		if (aseg >= 0) {
			st->two_segment++;
			add_journal_blocks(c, &vl, st, aseg, first_a,
					   c->regions[aseg].end, cm->entry_idx);
			add_journal_blocks(c, &vl, st, cseg, c->regions[cseg].start,
					   cm->lba, cm->entry_idx);
			first = first_a;
		} else {
			add_journal_blocks(c, &vl, st, cseg, first, cm->lba,
					   cm->entry_idx);
		}
		qsort(homes, nh, sizeof(*homes), u64_cmp);
		for (k = 0; k < nh; k++) {
			size_t nb, na;
			const struct wr *x;

			if (k && homes[k] == homes[k - 1])
				continue;
			x = pick_write(c->hw, c->hw_n, homes[k], home_lo, UINT64_MAX,
				       cm->entry_idx, &nb, &na);
			/* later writes are the checkpoints of later commits;
			 * two before this one are not */
			if (nb > 1)
				st->home_ambiguous++;
			vadd(&vl, homes[k], x, 1);
			n_home++;
		}
		/* its claims on the map log count only if it does */
		for (k = 0; k < cm->maplog_nr && k < 4096; k++) {
			const struct wr *x = claim_write(c, cm->maplog_seq + k);

			vadd(&vl, x ? x->lba : 0, x, 0);
			st->claim_blocks++;
		}
		st->blocks += vl.n;
		st->home_blocks += n_home;
		/* for I5: these writes are this transaction's */
		for (k = 0; k < vl.n; k++)
			if (vl.b[k].w)
				own_add(c, vl.b[k].w->lba, vl.b[k].w->entry_idx, i);
		/* for I2 and I3: what it journaled, what its revoke blocks say */
		{
			struct txinfo tx;
			size_t q;

			memset(&tx, 0, sizeof(tx));
			tx.ci = i;
			tx.first_entry = UINT64_MAX;
			tx.first_lba = first;
			tx.seg[0] = cseg;
			tx.seg[1] = aseg;
			for (k = 0; k < vl.n; k++)
				if (vl.b[k].w && vl.b[k].w->entry_idx < tx.first_entry)
					tx.first_entry = vl.b[k].w->entry_idx;
			qsort(jts, njt, sizeof(*jts), u64_cmp);
			tx.jt_first = (uint32_t)c->txjt_n;
			for (k = 0; k < njt; k++) {
				if (k && jts[k] == jts[k - 1])
					continue;
				GROW(c->txjt, c->txjt_n, c->txjt_cap, 1024);
				c->txjt[c->txjt_n++] = jts[k];
				tx.jt_n++;
			}
			tx.rt_first = (uint32_t)c->txrt_n;
			for (k = 0; k < vl.n; k++) {
				const struct wr *w = vl.b[k].w;
				size_t lo2 = 0, hi2 = c->rt_n;

				if (!w || vl.b[k].home)
					continue;
				while (lo2 < hi2) {
					size_t mid = lo2 + (hi2 - lo2) / 2;

					if (c->rt[mid].lba < w->lba || (c->rt[mid].lba == w->lba &&
					    c->rt[mid].entry_idx < w->entry_idx))
						lo2 = mid + 1;
					else
						hi2 = mid;
				}
				for (q = lo2; q < c->rt_n && c->rt[q].lba == w->lba &&
				     c->rt[q].entry_idx == w->entry_idx; q++) {
					GROW(c->txrt, c->txrt_n, c->txrt_cap, 256);
					c->txrt[c->txrt_n++] = q;
					tx.rt_n++;
				}
			}
			GROW(c->tx, c->tx_n, c->tx_cap, 1024);
			c->txof[i] = c->tx_n;
			c->tx[c->tx_n++] = tx;
		}

		/* judged on the record's own flush */
		judge(vl.b, vl.n, cm->fepoch, &n_unordered, &n_missing, &w);
		st->missing += n_missing;
		if (!n_unordered && !n_missing) {
			st->own++;
			continue;
		}
		st->strict++;

		ok = 0;
		gate = "none";
		if (c->i1_strict) {
			gate = "strict";
		} else if (cm->commit_epoch_field) {
			gate = "host";
			hcm = host_commit(c, cm->commit_epoch_field);
			if (!hcm) {
				st->gate_closed++;
				continue;
			}
			/* before the record and its host commit both */
			bound = cm->fepoch > hcm->fepoch ? cm->fepoch : hcm->fepoch;
			judge(vl.b, vl.n, bound, &n_unordered, &n_missing, &w);
			ok = !n_unordered && !n_missing;
		} else if (cm->commit_flags & TAU_COMMIT_F_ISIZE) {
			/* only the size rollback stands in the way, which a
			 * log of block writes cannot judge */
			gate = "isize";
		}
		if (ok) {
			st->gated++;
			continue;
		}

		st->viol++;
		if (!cm->commit_epoch_field && !(cm->commit_flags & TAU_COMMIT_F_ISIZE))
			st->viol_ungated++;
		if (report && viol_begin(v)) {
			printf("{\"invariant\":\"I1\""
			       ",\"detail\":\"%s\""
			       ",\"gate\":\"%s\""
			       ",\"inode\":%" PRIu64
			       ",\"serial\":%" PRIu64
			       ",\"sequence\":%u"
			       ",\"commit_lba\":%" PRIu64
			       ",\"commit_epoch\":%" PRIu64
			       ",\"commit_entry\":%" PRIu64
			       ",\"commit_fua\":%d"
			       ",\"commit_h_epoch\":%" PRIu64
			       ",\"commit_h_flags\":%u",
			       !strcmp(gate, "host") ?
			       "a block not durable before the host commit that gates the record" :
			       "commit not ordered after data",
			       gate, cm->inode_number, cm->serial, cm->sequence,
			       cm->lba, cm->fepoch, cm->entry_idx, cm->fua,
			       cm->commit_epoch_field, cm->commit_flags);
			if (hcm)
				printf(",\"host_commit_entry\":%" PRIu64
				       ",\"host_commit_epoch\":%" PRIu64,
				       hcm->entry_idx, hcm->fepoch);
			if (w.missing)
				printf(",\"data_lba\":%" PRIu64 ",\"data_missing\":true",
				       w.lba);
			else
				printf(",\"data_lba\":%" PRIu64
				       ",\"data_epoch\":%" PRIu64
				       ",\"data_entry\":%" PRIu64,
				       w.lba, w.fepoch, w.entry);
			printf(",\"data_home\":%d"
			       ",\"first_descriptor_lba\":%" PRIu64
			       ",\"segments\":%d"
			       ",\"blocks_in_transaction\":%zu"
			       ",\"home_blocks\":%" PRIu64
			       ",\"blocks_unordered\":%" PRIu64
			       ",\"blocks_missing\":%" PRIu64
			       ",\"epoch_model\":\"flush\"}",
			       w.home, first, aseg >= 0 ? 2 : 1, vl.n, n_home,
			       n_unordered, n_missing);
		}
	}
	free(vl.b);
	free(homes);
	free(jts);
	free(dix);
}

/* ---- I2, I3, I4: the tail, revoke tags, the segment map log -------------- */

/* tid order within one file: tids wrap (fs/taujournal: tid_gt) */
static int tid_gt32(uint32_t a, uint32_t b)
{
	return (int32_t)(a - b) > 0;
}

/* A point a write has to be durable by: before flush epoch fep, or, written
 * FUA, logged before entry. */
struct dline {
	uint64_t fep;
	uint64_t entry;
};

#define DL_NEVER ((struct dline){ UINT64_MAX, UINT64_MAX })

static int dl_never(const struct dline *d)
{
	return d->fep == UINT64_MAX;
}

static int dl_less(const struct dline *a, const struct dline *b)
{
	return a->fep != b->fep ? a->fep < b->fep : a->entry < b->entry;
}

static int durable_by(uint64_t fepoch, uint64_t entry, int fua,
		      const struct dline *d)
{
	return fepoch < d->fep || (fua && entry < d->entry);
}

/* When a record can count: it and the host commit its h_epoch names durable
 * (gated I1's bound); never, if that host commit is not in the log. */
static struct dline record_dline(const struct ctx *c, const struct jblk *cm)
{
	struct dline d = { cm->fepoch, cm->entry_idx };
	const struct hcommit *h;

	if (!cm->commit_epoch_field)
		return d;
	h = host_commit(c, cm->commit_epoch_field);
	if (!h)
		return DL_NEVER;
	if (h->fepoch > d.fep)
		d.fep = h->fepoch;
	if (h->entry_idx > d.entry)
		d.entry = h->entry_idx;
	return d;
}

/* track_map_block() files a snapshot's drop with a seq no map log block has */
static int sf_is_snapshot(const struct segfree *f)
{
	return f->seq > (UINT64_MAX >> 1);
}

/* The first FREE, or snapshot drop, of segment @pba logged after entry @e. */
static const struct segfree *next_free(const struct ctx *c, uint64_t pba,
				       uint64_t e)
{
	size_t a = 0, b = c->sf_n;

	while (a < b) {
		size_t mid = a + (b - a) / 2;
		const struct segfree *s = &c->sf[mid];

		if (s->pba < pba || (s->pba == pba && s->entry_idx <= e))
			a = mid + 1;
		else
			b = mid;
	}
	return (a < c->sf_n && c->sf[a].pba == pba) ? &c->sf[a] : NULL;
}

/*
 * The superblock write that moves s_maplog_base, of mount @gen, first after
 * entry @e.  Recovery applies the log blocks past the base over the map
 * blocks, so a snapshot's drop takes effect only there (the kernel session,
 * 11-07).  A new mount's first write does not move it: that base passes the
 * previous mount's whole log.
 */
static const struct sbwrite *base_move_after(const struct ctx *c, uint64_t e,
					     uint32_t gen)
{
	size_t k;

	for (k = 0; k < c->sbw_n; k++) {
		const struct sbwrite *sb = &c->sbw[k];

		if (sb->entry_idx > e && sb->sequence == gen && k &&
		    c->sbw[k - 1].sequence == gen && sb->base > c->sbw[k - 1].base)
			return sb;
	}
	return NULL;
}

/* (ino, serial, pblk) -> the transactions that journaled pblk, in log order */
struct jtref {
	uint64_t ino, serial, pblk, entry;
	size_t tx;
};

static int jtref_cmp(const void *x, const void *y)
{
	const struct jtref *a = x, *b = y;

	if (a->ino != b->ino) return a->ino < b->ino ? -1 : 1;
	if (a->serial != b->serial) return a->serial < b->serial ? -1 : 1;
	if (a->pblk != b->pblk) return a->pblk < b->pblk ? -1 : 1;
	return a->entry < b->entry ? -1 : a->entry > b->entry;
}

/* The first jtref of (ino, serial, pblk) logged at or after entry @e. */
static size_t jtref_lower(const struct jtref *jr, size_t n, uint64_t ino,
			  uint64_t serial, uint64_t pblk, uint64_t e)
{
	struct jtref key = { ino, serial, pblk, e, 0 };
	size_t l = 0, r = n;

	while (l < r) {
		size_t mid = l + (r - l) / 2;

		if (jtref_cmp(&jr[mid], &key) < 0)
			l = mid + 1;
		else
			r = mid;
	}
	return l;
}

static int rt_cmp(const void *x, const void *y)
{
	const struct rtag *a = x, *b = y;

	if (a->lba != b->lba) return a->lba < b->lba ? -1 : 1;
	return a->entry_idx < b->entry_idx ? -1 : a->entry_idx > b->entry_idx;
}

/* Is it the same file of the same mount? */
static int same_file(const struct jblk *x, const struct jblk *y)
{
	return x->inode_number == y->inode_number && x->serial == y->serial &&
	       x->jgen == y->jgen;
}

/*
 * Every journal copy of every reconstructed transaction, and every block a
 * conditional revoke tag names (with the commit that carries it), keyed by
 * file and block.  I2 and I3 look copies up here.
 */
static void build_refs(struct ctx *c, struct jtref **jrp, size_t *jrn,
		       struct jtref **cdp, size_t *cdn)
{
	struct jtref *jr = NULL, *cd = NULL;
	size_t jr_n = 0, jr_cap = 0, cd_n = 0, cd_cap = 0, t, k;

	for (t = 0; t < c->tx_n; t++) {
		const struct txinfo *x = &c->tx[t];
		const struct jblk *cm = &c->jb[x->ci];

		for (k = 0; k < x->jt_n; k++) {
			GROW(jr, jr_n, jr_cap, 1024);
			jr[jr_n] = (struct jtref){ cm->inode_number, cm->serial,
				c->txjt[x->jt_first + k], cm->entry_idx, t };
			jr_n++;
		}
		for (k = 0; k < x->rt_n; k++) {
			const struct rtag *rg = &c->rt[c->txrt[x->rt_first + k]];

			if (!(rg->flags & TAU_REVOKE_F_COND))
				continue;
			GROW(cd, cd_n, cd_cap, 64);
			cd[cd_n] = (struct jtref){ cm->inode_number, cm->serial,
				rg->pblk, cm->entry_idx, t };
			cd_n++;
		}
	}
	qsort(jr, jr_n, sizeof(*jr), jtref_cmp);
	qsort(cd, cd_n, sizeof(*cd), jtref_cmp);
	*jrp = jr;
	*jrn = jr_n;
	*cdp = cd;
	*cdn = cd_n;
}

struct i2stat {
	uint64_t txs, never, by_free, by_snapshot, blocks, home, handoff;
	uint64_t deferred, uncovered, leads, snapshot_leads;
	uint64_t tailblk_checked, tailblk_bad;
};

/*
 * I2 -- the tail.  A record whose h_tail_tid is past tx T (tid_gt) ends T's
 * replay, and so does a FREE dropping one of T's segments, or a snapshot doing
 * so once the superblock moves the map log's base past it.  By the earliest of
 * these, every home block T journaled has to be covered (the kernel session's
 * rules, 11-07):
 *  (i)  a home write of it after T's first block, durable by then -- from any
 *       engine, carrying T's version or newer; or
 *  (ii) a later transaction of the file that journaled it again, still
 *       replayed there and itself valid by then (the handoff).
 * A truncate's conditional tags and an unlinked file are the other two ways
 * out; no gen here makes them yet, so a block a conditional tag of the file
 * names, in T or later, is counted as deferred rather than judged.
 *
 * Counted, not judged: a home write of one of T's journal blocks before T's
 * record is valid (with tau_defer_txdirty_cpflush on, expected never: a lead
 * for the kernel session), and a block covered at the base write but not at
 * the snapshot's map block (the stricter point).
 *
 * And h_tail_blk, structurally: it names the first block of tx h_tail_tid.
 */
static void check_i2(struct ctx *c, struct viol_out *v, struct i2stat *st,
		     const struct jtref *jr, size_t jr_n,
		     const struct jtref *cd, size_t cd_n)
{
	struct dline *dlc = xrealloc(NULL, (c->jb_n + 1) * sizeof(*dlc));
	struct dline *suf = xrealloc(NULL, (c->nc + 1) * sizeof(*suf));
	size_t i, k, a, b, t;

	for (i = 0; i < c->jb_n; i++)
		if (c->jb[i].blocktype == TAU_COMMIT_BLOCK)
			dlc[i] = record_dline(c, &c->jb[i]);
	/* when a tail-moving record of the file, this one or later, can count */
	for (a = 0; a < c->nc; a = b) {
		for (b = a + 1; b < c->nc &&
			    same_file(&c->jb[c->cix[a]], &c->jb[c->cix[b]]); b++)
			;
		for (k = b; k-- > a; ) {
			const struct jblk *r = &c->jb[c->cix[k]];
			struct dline nx = (k + 1 < b) ? suf[k + 1] : DL_NEVER;

			suf[k] = ((r->commit_flags & TAU_COMMIT_F_TAIL) &&
				  dl_less(&dlc[c->cix[k]], &nx)) ? dlc[c->cix[k]] : nx;
		}
	}

	for (t = 0; t < c->tx_n; t++) {
		const struct txinfo *x = &c->tx[t];
		const struct jblk *cm = &c->jb[x->ci];
		size_t p = c->cpos[x->ci], q, bind_rec = SIZE_MAX;
		struct dline dl = DL_NEVER, mine = dlc[x->ci], snapmap = DL_NEVER;
		const struct segfree *fr = NULL;
		int s, snap = 0;

		st->txs++;
		/* the first record of the file whose tail passes T; the tail
		 * never moves back, so every later one passes it too */
		for (q = p + 1; q < c->nc && same_file(cm, &c->jb[c->cix[q]]); q++) {
			const struct jblk *r = &c->jb[c->cix[q]];

			if ((r->commit_flags & TAU_COMMIT_F_TAIL) &&
			    tid_gt32(r->tail_tid, cm->sequence)) {
				dl = suf[q];
				bind_rec = q;
				break;
			}
		}
		for (s = 0; s < 2; s++) {
			const struct segfree *f;
			struct dline fd;

			if (x->seg[s] < 0)
				continue;
			f = next_free(c, c->regions[x->seg[s]].start, cm->entry_idx);
			if (!f)
				continue;
			if (sf_is_snapshot(f)) {
				const struct sbwrite *sb = base_move_after(c, f->entry_idx,
									   cm->jgen);

				if (!sb)
					continue;
				fd = (struct dline){ sb->fepoch, sb->entry_idx };
			} else {
				fd = (struct dline){ f->fepoch, f->entry_idx };
			}
			if (dl_less(&fd, &dl)) {
				dl = fd;
				fr = f;
				snap = sf_is_snapshot(f);
				if (snap)
					snapmap = (struct dline){ f->fepoch, f->entry_idx };
			}
		}
		if (dl_never(&dl)) {
			st->never++;
			continue;
		}
		if (fr && snap)
			st->by_snapshot++;
		else if (fr)
			st->by_free++;

		for (k = 0; k < x->jt_n; k++) {
			uint64_t pb = c->txjt[x->jt_first + k];
			size_t l = 0, r = c->hw_n, nh = 0, h;
			int covered = 0, covered_map = 0, handoff = 0;
			const struct wr *last = NULL;

			st->blocks++;
			/* a truncate, punch or zero of it, in T or later: deferred */
			l = jtref_lower(cd, cd_n, cm->inode_number, cm->serial, pb,
					cm->entry_idx);
			if (l < cd_n && cd[l].ino == cm->inode_number &&
			    cd[l].serial == cm->serial && cd[l].pblk == pb) {
				st->deferred++;
				continue;
			}
			l = 0;
			while (l < r) {
				size_t mid = l + (r - l) / 2;

				if (c->hw[mid].lba < pb || (c->hw[mid].lba == pb &&
				    c->hw[mid].entry_idx <= x->first_entry))
					l = mid + 1;
				else
					r = mid;
			}
			for (h = l; h < c->hw_n && c->hw[h].lba == pb; h++) {
				const struct wr *w = &c->hw[h];

				nh++;
				last = w;
				if (durable_by(w->fepoch, w->entry_idx, w->fua, &dl))
					covered = 1;
				if (snap && durable_by(w->fepoch, w->entry_idx, w->fua,
						       &snapmap))
					covered_map = 1;
				/* before T's own record could count */
				if (!dl_never(&mine) && w->entry_idx < mine.entry) {
					st->leads++;
					if (c->debug)
						fprintf(stderr, "loginv: lead: home write of %" PRIu64
							" at entry %" PRIu64 " before tx %u (ino %" PRIu64
							") is valid at entry %" PRIu64 "\n", pb,
							w->entry_idx, cm->sequence, cm->inode_number,
							mine.entry);
				}
			}
			if (covered) {
				st->home++;
				if (snap && !covered_map)
					st->snapshot_leads++;
				continue;
			}
			/* the handoff: a later transaction of the file has it */
			for (l = jtref_lower(jr, jr_n, cm->inode_number, cm->serial, pb,
					     cm->entry_idx + 1);
			     l < jr_n && jr[l].ino == cm->inode_number &&
			     jr[l].serial == cm->serial && jr[l].pblk == pb && !handoff; l++) {
				const struct txinfo *y = &c->tx[jr[l].tx];
				const struct jblk *cy = &c->jb[y->ci];
				struct dline yd = dlc[y->ci];

				if (cy->jgen != cm->jgen)
					continue;
				if (bind_rec != SIZE_MAX && !fr &&
				    tid_gt32(c->jb[c->cix[bind_rec]].tail_tid, cy->sequence))
					continue;	/* passed too: no copy there */
				if (fr && ((y->seg[0] >= 0 && c->regions[y->seg[0]].start == fr->pba) ||
					   (y->seg[1] >= 0 && c->regions[y->seg[1]].start == fr->pba)))
					continue;	/* freed with T */
				if (!dl_never(&yd) && !dl_less(&dl, &yd))
					handoff = 1;
			}
			if (handoff) {
				st->handoff++;
				continue;
			}
			st->uncovered++;
			if (!viol_begin(v))
				continue;
			printf("{\"invariant\":\"I2\""
			       ",\"detail\":\"%s with a block of it neither durable at home nor"
			       " in a later replayed transaction\""
			       ",\"inode\":%" PRIu64 ",\"serial\":%" PRIu64 ",\"sequence\":%u"
			       ",\"commit_entry\":%" PRIu64 ",\"by\":\"%s\""
			       ",\"bound_epoch\":%" PRIu64 ",\"bound_entry\":%" PRIu64
			       ",\"pblk\":%" PRIu64 ",\"home_writes\":%zu",
			       fr ? (snap ? "a snapshot dropped the transaction's segment" :
					    "a FREE dropped the transaction's segment") :
				    "a record's tail passed the transaction",
			       cm->inode_number, cm->serial, cm->sequence, cm->entry_idx,
			       fr ? (snap ? "snapshot" : "free") : "tail", dl.fep, dl.entry,
			       pb, nh);
			if (last)
				printf(",\"last_home_entry\":%" PRIu64
				       ",\"last_home_epoch\":%" PRIu64,
				       last->entry_idx, last->fepoch);
			printf("}");
		}
	}

	/* h_tail_blk: the first block of tx h_tail_tid of the same file; the
	 * tail is at or before the record's own tx, so look back from it */
	for (i = 0; i < c->jb_n; i++) {
		const struct jblk *cm = &c->jb[i];
		size_t q, tx = SIZE_MAX;

		if (cm->blocktype != TAU_COMMIT_BLOCK ||
		    !(cm->commit_flags & TAU_COMMIT_F_TAIL))
			continue;
		for (q = c->cpos[i] + 1; q-- > 0 && same_file(cm, &c->jb[c->cix[q]]); ) {
			if (c->jb[c->cix[q]].sequence == cm->tail_tid) {
				tx = c->txof[c->cix[q]];
				break;
			}
		}
		if (tx == SIZE_MAX)
			continue;	/* not in the log, or not reconstructed */
		st->tailblk_checked++;
		if (c->tx[tx].first_lba == cm->tail_blk)
			continue;
		st->tailblk_bad++;
		if (viol_begin(v))
			printf("{\"invariant\":\"tail_blk\",\"detail\":\"h_tail_blk"
			       " is not the first block of the tail transaction\""
			       ",\"inode\":%" PRIu64 ",\"sequence\":%u"
			       ",\"tail_tid\":%u,\"tail_blk\":%" PRIu64
			       ",\"first_block\":%" PRIu64 "}",
			       cm->inode_number, cm->sequence, cm->tail_tid,
			       cm->tail_blk, c->tx[tx].first_lba);
	}
	free(dlc);
	free(suf);
}

struct i3stat {
	uint64_t scoped, cond, vacuous, home, copy, violations;
};

/*
 * I3 -- a scoped revoke tag (pblk, scope S) in record C stands in for the
 * in-place data written over the file's last journal copy of pblk.  Let J be
 * the newest transaction of the file with tid <= S holding a journal copy of
 * pblk (none: the tag is vacuous).  Then either the last home write of pblk
 * after J's record (failing that, the first after C) is durable by the time
 * C can count, or a transaction of the file in (S, C] journaled pblk again --
 * an undo block hit by a write journaled whole goes back into the running tx
 * with its tag still queued -- and records of a file become valid in tid
 * order, so that copy is valid when C is (the kernel session's rules, 11-07).
 *
 * Conditional tags (truncate, punch, zero) and the revoke-range path are
 * counted only: their rules are about the host's free, which no gen makes yet.
 */
static void check_i3(struct ctx *c, struct viol_out *v, struct i3stat *st,
		     const struct jtref *jr, size_t jr_n)
{
	size_t t, k;

	for (t = 0; t < c->tx_n; t++) {
		const struct txinfo *x = &c->tx[t];
		const struct jblk *cm = &c->jb[x->ci];
		struct dline dl = record_dline(c, cm);

		for (k = 0; k < x->rt_n; k++) {
			const struct rtag *rg = &c->rt[c->txrt[x->rt_first + k]];
			uint32_t S = (uint32_t)rg->scope;
			const struct jblk *J = NULL;
			int copy = 0;
			size_t l, nb, na;
			const struct wr *w;

			if (rg->flags & TAU_REVOKE_F_COND) {
				st->cond++;
				continue;
			}
			if (!(rg->flags & TAU_REVOKE_F_SCOPED))
				continue;
			st->scoped++;
			if (dl_never(&dl))
				continue;	/* no state counts the record */
			for (l = jtref_lower(jr, jr_n, cm->inode_number, cm->serial,
					     rg->pblk, 0);
			     l < jr_n && jr[l].ino == cm->inode_number &&
			     jr[l].serial == cm->serial && jr[l].pblk == rg->pblk; l++) {
				const struct jblk *cy = &c->jb[c->tx[jr[l].tx].ci];

				if (cy->jgen != cm->jgen)
					continue;
				if (!tid_gt32(cy->sequence, S)) {
					if (cy->entry_idx < cm->entry_idx)
						J = cy;	/* the newest so far */
				} else if (!tid_gt32(cy->sequence, cm->sequence) &&
					   !dl_never(&(struct dline){ record_dline(c, cy).fep, 0 })) {
					copy = 1;	/* in (S, C] */
				}
			}
			if (!J) {
				st->vacuous++;
				continue;
			}
			if (copy) {
				st->copy++;
				continue;
			}
			w = pick_write(c->hw, c->hw_n, rg->pblk, J->entry_idx + 1,
				       UINT64_MAX, cm->entry_idx, &nb, &na);
			if (w && durable_by(w->fepoch, w->entry_idx, w->fua, &dl)) {
				st->home++;
				continue;
			}
			st->violations++;
			if (!viol_begin(v))
				continue;
			printf("{\"invariant\":\"I3\",\"detail\":\"%s\""
			       ",\"inode\":%" PRIu64 ",\"serial\":%" PRIu64 ",\"sequence\":%u"
			       ",\"commit_entry\":%" PRIu64 ",\"bound_epoch\":%" PRIu64
			       ",\"pblk\":%" PRIu64 ",\"scope\":%u,\"copy_sequence\":%u",
			       w ? "the in-place data a scoped tag stands in for is not durable"
				   " before the record carrying it can count" :
				   "no in-place write of the block a scoped tag stands in for",
			       cm->inode_number, cm->serial, cm->sequence, cm->entry_idx,
			       dl.fep, rg->pblk, S, J->sequence);
			if (w)
				printf(",\"home_entry\":%" PRIu64 ",\"home_epoch\":%" PRIu64,
				       w->entry_idx, w->fepoch);
			printf("}");
		}
	}
}

struct i4stat {
	uint64_t base_moves, map_writes, overwrites, owners_named, owners_claimed;
	uint64_t reuses, violations;
};

static int ce_cmp(const void *x, const void *y)
{
	const struct claiment *a = x, *b = y;

	if (a->pba != b->pba) return a->pba < b->pba ? -1 : 1;
	if (a->ino != b->ino) return a->ino < b->ino ? -1 : 1;
	return a->entry_idx < b->entry_idx ? -1 : a->entry_idx > b->entry_idx;
}

static int ce_entry_cmp(const void *x, const void *y)
{
	const struct claiment *a = x, *b = y;

	if (a->pba != b->pba) return a->pba < b->pba ? -1 : 1;
	return a->entry_idx < b->entry_idx ? -1 : a->entry_idx > b->entry_idx;
}

static int mlw_cmp(const void *x, const void *y)
{
	const struct mlwrite *a = x, *b = y;

	if (a->lba != b->lba) return a->lba < b->lba ? -1 : 1;
	return a->entry_idx < b->entry_idx ? -1 : a->entry_idx > b->entry_idx;
}

/*
 * I4 -- the segment map log (the kernel session's rules, 11-07), per mount:
 *  (a) a segment whose claim reached the log is written by its next owner --
 *      the same file included -- only after a completed FREE naming it, or a
 *      snapshot whose base passed the claim.  Each journal block is written
 *      once per ownership, so a second write of a block marks a reuse.
 *  (e) a snapshot writes every map block (PREFLUSH|FUA, waited) before the
 *      superblock moves s_maplog_base; and log block seq s is overwritten, by
 *      seq s + s_maplog_len, only after the base reached s.
 *  (f) a map block names an owner only for a segment whose claim's record
 *      can count already: a snapshot waits until no claim is in flight.
 * (c) -- a FREE only after its transactions are covered at home -- is I2's
 * FREE deadline; a give-back's other half (the host writes nothing into the
 * segment before it) needs a nearly full host FS, and is not checked.
 */
static void check_i4(struct ctx *c, struct viol_out *v, struct i4stat *st)
{
	struct claiment *cp = NULL;
	size_t k, m, j, prev_sb = SIZE_MAX, cpn = c->ce_n, r;
	uint64_t prev_base = 0;

	/* (a) reuse only after a FREE, or a snapshot past the claim */
	cp = xrealloc(NULL, (cpn + 1) * sizeof(*cp));
	memcpy(cp, c->ce, cpn * sizeof(*cp));
	qsort(cp, cpn, sizeof(*cp), ce_entry_cmp);
	for (r = 0; r < c->nregions; r++) {
		const struct region *rg = &c->regions[r];
		size_t l = 0, h = cpn, lo, hi;
		uint64_t lba;

		while (l < h) {
			size_t mid = l + (h - l) / 2;

			if (cp[mid].pba < rg->start)
				l = mid + 1;
			else
				h = mid;
		}
		if (l >= cpn || cp[l].pba != rg->start)
			continue;	/* never claimed in this log */
		lo = l;
		for (hi = lo; hi < cpn && cp[hi].pba == rg->start; hi++)
			;
		for (lba = rg->start; lba < rg->end; lba++) {
			size_t a = 0, b = c->jw_n, w;

			while (a < b) {
				size_t mid = a + (b - a) / 2;

				if (c->jw[mid].lba < lba)
					a = mid + 1;
				else
					b = mid;
			}
			for (w = a; w + 1 < c->jw_n && c->jw[w + 1].lba == lba; w++) {
				const struct wr *w1 = &c->jw[w], *w2 = &c->jw[w + 1];
				const struct claiment *cl = NULL;
				const struct segfree *f;
				int ok = 0;

				/* the claim of the ownership w1 belongs to: logged
				 * before it, or with it -- a claim goes out plain
				 * with its transaction's blocks, so it can land
				 * after them in the same flush window */
				for (j = lo; j < hi && cp[j].entry_idx < w2->entry_idx; j++) {
					const struct wr *cw = claim_write(c, cp[j].seq);

					if (cp[j].entry_idx <= w1->entry_idx ||
					    (cw && cw->fepoch <= w1->fepoch))
						cl = &cp[j];
				}
				if (!cl)
					continue;	/* an ownership the log never published */
				st->reuses++;
				f = next_free(c, rg->start, w1->entry_idx);
				ok = f && !sf_is_snapshot(f) && f->entry_idx < w2->entry_idx;
				for (m = 1; m < c->sbw_n && !ok; m++)
					ok = c->sbw[m].entry_idx > w1->entry_idx &&
					     c->sbw[m].entry_idx < w2->entry_idx &&
					     c->sbw[m].sequence == c->sbw[m - 1].sequence &&
					     c->sbw[m].base > c->sbw[m - 1].base &&
					     c->sbw[m].base >= cl->seq;
				if (ok)
					continue;
				st->violations++;
				if (viol_begin(v))
					printf("{\"invariant\":\"I4\",\"detail\":\"a segment whose"
					       " claim reached the log was written by its next"
					       " owner with no FREE naming it (or snapshot past"
					       " the claim) completed first\""
					       ",\"pba\":%" PRIu64 ",\"lba\":%" PRIu64
					       ",\"claim_seq\":%" PRIu64 ",\"prev_write_entry\":%"
					       PRIu64 ",\"reuse_entry\":%" PRIu64 "}",
					       rg->start, lba, cl->seq, w1->entry_idx,
					       w2->entry_idx);
			}
		}
	}
	free(cp);

	/* (e) map blocks before the base, per mount */
	for (k = 0; k < c->sbw_n; k++) {
		const struct sbwrite *sb = &c->sbw[k];
		uint64_t lo = prev_sb == SIZE_MAX ? 0 : c->sbw[prev_sb].entry_idx;
		size_t n = 0, late = 0;

		if (prev_sb == SIZE_MAX || c->sbw[prev_sb].sequence != sb->sequence) {
			prev_base = sb->base;	/* a mount: a new log */
			prev_sb = k;
			continue;
		}
		if (sb->base > prev_base) {
			st->base_moves++;
			for (m = 0; m < c->mw_n; m++) {
				const struct mapwrite *w = &c->mw[m];
				struct dline d = { sb->fepoch, sb->entry_idx };

				if (w->entry_idx <= lo || w->entry_idx >= sb->entry_idx)
					continue;
				n++;
				if (!durable_by(w->fepoch, w->entry_idx, w->fua, &d))
					late++;
			}
			if (!n || late) {
				st->violations++;
				if (viol_begin(v))
					printf("{\"invariant\":\"I4\",\"detail\":\"%s\""
					       ",\"superblock_entry\":%" PRIu64 ",\"base\":%" PRIu64
					       ",\"map_writes\":%zu,\"not_durable\":%zu}",
					       n ? "map blocks not durable before the superblock"
						   " moved the map log's base" :
						   "the map log's base moved with no map block"
						   " written since the superblock before",
					       sb->entry_idx, sb->base, n, late);
			}
			prev_base = sb->base;
		}
		prev_sb = k;
	}

	/* (e) a log block overwritten only after its mount's base passed it */
	qsort(c->mlw, c->mlw_n, sizeof(*c->mlw), mlw_cmp);
	for (k = 1; k < c->mlw_n; k++) {
		const struct mlwrite *o = &c->mlw[k - 1], *n = &c->mlw[k];
		int ok = 0;

		if (o->lba != n->lba || o->jgen != n->jgen || n->seq <= o->seq)
			continue;
		st->overwrites++;
		for (m = 0; m < c->sbw_n && !ok; m++)
			ok = c->sbw[m].entry_idx < n->entry_idx &&
			     c->sbw[m].sequence == o->jgen && c->sbw[m].base >= o->seq;
		if (ok)
			continue;
		st->violations++;
		if (viol_begin(v))
			printf("{\"invariant\":\"I4\",\"detail\":\"a map log block was"
			       " overwritten before the base reached its seq\""
			       ",\"lba\":%" PRIu64 ",\"seq\":%" PRIu64 ",\"by_seq\":%" PRIu64
			       ",\"entry\":%" PRIu64 "}", n->lba, o->seq, n->seq, n->entry_idx);
	}

	/* (f) owners named by a map block: their claim's record valid first */
	qsort(c->ce, c->ce_n, sizeof(*c->ce), ce_cmp);
	for (m = 0; m < c->mw_n; m++) {
		const struct mapwrite *w = &c->mw[m];
		struct dline d = { w->fepoch, w->entry_idx };

		st->map_writes++;
		for (j = 0; j < w->ent_n; j++) {
			const struct mapent *me = &c->ment[w->ent_first + j];
			const struct claiment *cl = NULL;
			const struct jblk *rec = NULL;
			size_t l = 0, h = c->ce_n, i;
			struct dline rd;

			st->owners_named++;
			/* the latest claim of this segment by this owner before it */
			while (l < h) {
				size_t mid = l + (h - l) / 2;
				const struct claiment *x = &c->ce[mid];

				if (x->pba < me->pba || (x->pba == me->pba &&
				    (x->ino < me->ino || (x->ino == me->ino &&
				     x->entry_idx < w->entry_idx))))
					l = mid + 1;
				else
					h = mid;
			}
			if (l > 0 && c->ce[l - 1].pba == me->pba && c->ce[l - 1].ino == me->ino)
				cl = &c->ce[l - 1];
			if (!cl)
				continue;	/* owned since before the log */
			st->owners_claimed++;
			for (i = 0; i < c->jb_n && !rec; i++) {
				const struct jblk *x = &c->jb[i];

				if (x->blocktype == TAU_COMMIT_BLOCK && x->maplog_nr &&
				    x->inode_number == me->ino && cl->seq >= x->maplog_seq &&
				    cl->seq < x->maplog_seq + x->maplog_nr)
					rec = x;
			}
			if (rec) {
				rd = record_dline(c, rec);
				if (!dl_never(&rd) && !dl_less(&d, &rd) &&
				    durable_by(rec->fepoch, rec->entry_idx, rec->fua, &d))
					continue;
			}
			st->violations++;
			if (viol_begin(v))
				printf("{\"invariant\":\"I4\",\"detail\":\"%s\""
				       ",\"map_entry\":%" PRIu64 ",\"pba\":%" PRIu64
				       ",\"ino\":%" PRIu64 ",\"claim_seq\":%" PRIu64 "}",
				       rec ? "a map block names an owner before the record of"
					     " its claim can count" :
					     "a map block names an owner whose claim no record"
					     " vouches for",
				       w->entry_idx, me->pba, me->ino, cl->seq);
		}
	}
}

/* ---- I5 ------------------------------------------------------------------ */

static int own_cmp(const void *x, const void *y)
{
	const struct owner *a = x, *b = y;

	if (a->lba != b->lba)
		return a->lba < b->lba ? -1 : 1;
	if (a->entry_idx != b->entry_idx)
		return a->entry_idx < b->entry_idx ? -1 : 1;
	return 0;
}

/*
 * The durable unit the block write (lba, entry) belongs to.  On tau it is the
 * transaction whose I1 reconstruction took exactly that write.  On jbd2 it is
 * the descriptor naming that journal block, logged nearest to the write: a
 * commit writes its descriptors and their blocks together, and a journal
 * block is reused only a full journal later.
 */
static int unit_of(const struct ctx *c, uint64_t lba, uint64_t entry,
		   uint64_t *unit)
{
	size_t l = 0, r = c->own_n;
	uint64_t bestd = UINT64_MAX;
	int found = 0;

	while (l < r) {
		size_t mid = l + (r - l) / 2;

		if (c->own[mid].lba < lba)
			l = mid + 1;
		else
			r = mid;
	}
	for (; l < c->own_n && c->own[l].lba == lba; l++) {
		const struct owner *o = &c->own[l];
		uint64_t d = o->entry_idx > entry ? o->entry_idx - entry
						  : entry - o->entry_idx;

		if (c->dia == DIA_TAU) {
			if (o->entry_idx == entry) {
				*unit = o->unit;
				return 1;
			}
			continue;
		}
		if (d < bestd) {
			bestd = d;
			*unit = o->unit;
			found = 1;
		}
	}
	return found;
}

struct i5stat {
	uint64_t checked, split, partial, unjournaled;
	uint64_t split_run, partial_run;	/* ... starting in gen's timed run */
};

struct upair {
	uint64_t unit;
	uint32_t sidx;
};

static int upair_cmp(const void *x, const void *y)
{
	const struct upair *a = x, *b = y;

	if (a->unit != b->unit)
		return a->unit < b->unit ? -1 : 1;
	return a->sidx < b->sidx ? -1 : a->sidx > b->sidx;
}

/*
 * I5 -- an application atomic write is contained in one durable unit: some
 * single unit carries every sector of it.  The unit is the jbd2 transaction on
 * ext4 data=journal and the tau transaction on tau (CRASH_TODO §3.5); a write
 * whose sectors only some units carry between them, or some no unit carries
 * at all, can be left half replayed.  Only the copies a unit carries count --
 * a checkpoint's write home belongs to none.
 *
 * This is ext4 data=journal's commit-induced split, read off the log: its
 * data goes through the journal page by page, so a commit not caused by the
 * write's own fsync can close a transaction with half of it.
 */
static void check_i5_units(struct ctx *c, struct viol_out *v, struct i5stat *st)
{
	struct upair *pr = NULL;
	size_t prcap = 0, i, j;
	const char *unit = c->dia == DIA_TAU ? "tau transaction" : "jbd2 transaction";

	qsort(c->own, c->own_n, sizeof(*c->own), own_cmp);
	qsort(c->as, c->as_n, sizeof(*c->as), appsec_cmp);

	for (i = 0; i < c->as_n; i = j) {
		uint64_t page = c->as[i].page_id, ver = c->as[i].version;
		uint32_t spu = c->as[i].spu;
		uint64_t full = spu >= 64 ? ~0ULL : (1ULL << spu) - 1;
		uint64_t allmask = 0, efirst = UINT64_MAX, elast = 0;
		uint64_t ffirst = UINT64_MAX, flast = 0;
		size_t n = 0, k, nunits = 0;
		int contained = 0;

		for (j = i; j < c->as_n && c->as[j].page_id == page &&
			    c->as[j].version == ver; j++) {
			uint64_t u;

			if (!unit_of(c, c->as[j].lba, c->as[j].entry_idx, &u))
				continue;
			if (n == prcap) {
				prcap = prcap ? prcap * 2 : 64;
				pr = xrealloc(pr, prcap * sizeof(*pr));
			}
			pr[n].unit = u;
			pr[n++].sidx = c->as[j].sector_idx;
			allmask |= 1ULL << c->as[j].sector_idx;
			if (c->as[j].entry_idx < efirst)
				efirst = c->as[j].entry_idx;
			if (c->as[j].entry_idx > elast)
				elast = c->as[j].entry_idx;
			if (c->as[j].fepoch < ffirst)
				ffirst = c->as[j].fepoch;
			if (c->as[j].fepoch > flast)
				flast = c->as[j].fepoch;
		}
		if (!n) {
			st->unjournaled++;
			if (c->debug) {
				size_t q;

				fprintf(stderr, "loginv: page %" PRIu64 " v%" PRIu64
					" in no unit; its copies:", page, ver);
				for (q = i; q < j; q++)
					fprintf(stderr, " [lba %" PRIu64 " entry %" PRIu64
						" sidx %u]", c->as[q].lba,
						c->as[q].entry_idx, c->as[q].sector_idx);
				fprintf(stderr, "\n");
			}
			continue;
		}
		st->checked++;
		qsort(pr, n, sizeof(*pr), upair_cmp);
		for (k = 0; k < n; ) {
			uint64_t mask = 0;
			size_t m = k;

			while (m < n && pr[m].unit == pr[k].unit)
				mask |= 1ULL << pr[m++].sidx;
			nunits++;
			if ((mask & full) == full)
				contained = 1;
			k = m;
		}
		if (contained)
			continue;
		if (nunits < 2) {
			/*
			 * One unit holds part of it and no unit the rest.  On
			 * tau the rest reached home from the page cache through
			 * the checkpoint of an older transaction, with no journal
			 * copy of its own; how recovery treats that copy is the
			 * file's tail rule (I2's territory), which a block log
			 * does not settle.  Counted, not judged.  On jbd2 every
			 * data block goes through the journal, so it is judged.
			 */
			st->partial++;
			if (c->begin_entry >= 0 && efirst >= (uint64_t)c->begin_entry)
				st->partial_run++;
			if (c->dia == DIA_TAU)
				continue;
		} else {
			st->split++;
			if (c->begin_entry >= 0 && efirst >= (uint64_t)c->begin_entry)
				st->split_run++;
		}
		if (!viol_begin(v))
			continue;
		printf("{\"invariant\":\"I5\""
		       ",\"detail\":\"application atomic write not contained in one %s\""
		       ",\"kind\":\"%s\""
		       ",\"page_id\":%" PRIu64 ",\"version\":%" PRIu64
		       ",\"sectors\":%u,\"sectors_in_units\":%d,\"units\":%zu",
		       unit, nunits < 2 ? "partial" : "split",
		       page, ver, spu, __builtin_popcountll(allmask & full), nunits);
		if (c->dia == DIA_TAU)
			printf(",\"inode\":%" PRIu64 ",\"sequence_first\":%u"
			       ",\"sequence_last\":%u",
			       c->jb[pr[0].unit].inode_number,
			       c->jb[pr[0].unit].sequence,
			       c->jb[pr[n - 1].unit].sequence);
		else
			printf(",\"tid_first\":%" PRIu64 ",\"tid_last\":%" PRIu64,
			       pr[0].unit, pr[n - 1].unit);
		printf(",\"entry_first\":%" PRIu64 ",\"entry_last\":%" PRIu64
		       ",\"epoch_first\":%" PRIu64 ",\"epoch_last\":%" PRIu64 "}",
		       efirst, elast, ffirst, flast);
	}
	free(pr);
}

/*
 * BIO CONTAINMENT -- of the k blocks making up one application atomic write
 * (page_id, version), is there any single log entry carrying all k?
 *
 * This is NOT I5, and must not be reported as I5.  I5 (CRASH_TODO §3.5) asks
 * whether the write is contained in a single DURABLE UNIT, and what counts as
 * one differs per configuration:
 *
 *   plain ext4 (ordered), xfs   the bio -- there is no data journal, so this
 *                               measurement is the answer
 *   ext4 data=journal           the JBD2 transaction
 *   tauJournal                  the tau transaction, closed by its commit block
 *
 * Measured against a tau capture, bio containment reports ~100% "split",
 * because tau deliberately writes data into its journal in journal-sized
 * chunks and checkpoints it later -- which is the mechanism that makes the
 * write atomic, not a violation of it.  Reporting that as an I5 failure would
 * invert the result.
 *
 * What it IS good for: it explains why entry-subset replay finds no tears on
 * ext4/xfs (the 16 KiB write is one bio, dropped or kept whole) while the
 * torn-entry strategy does.
 */
static void check_bio_containment(struct ctx *c, struct viol_out *v,
				  uint64_t *checked, uint64_t *split,
				  uint64_t *max_entries)
{
	size_t i, j;

	if (!c->as_n)
		return;
	qsort(c->as, c->as_n, sizeof(*c->as), appsec_cmp);

	for (i = 0; i < c->as_n; ) {
		uint64_t page = c->as[i].page_id, ver = c->as[i].version;
		uint32_t spu = c->as[i].spu;
		uint64_t min_entries = 0;
		uint64_t ep_lo = 0, ep_hi = 0;
		int contained = 0;

		/* the run of records for this (page, version) */
		for (j = i; j < c->as_n && c->as[j].page_id == page &&
			    c->as[j].version == ver; j++)
			;

		/* how many distinct entries does any one appearance need? */
		{
			size_t k = i;

			while (k < j) {
				uint64_t ent = c->as[k].entry_idx;
				uint64_t mask = 0;
				uint32_t n = 0;
				size_t m = k;

				while (m < j && c->as[m].entry_idx == ent) {
					uint64_t bit = 1ULL << c->as[m].sector_idx;

					if (!(mask & bit)) {
						mask |= bit;
						n++;
					}
					m++;
				}
				if (n == spu)
					contained = 1;
				k = m;
			}
		}

		ep_lo = c->as[i].epoch;
		ep_hi = c->as[j - 1].epoch;
		{
			size_t k = i;
			uint64_t last = UINT64_MAX;

			while (k < j) {
				if (c->as[k].entry_idx != last) {
					last = c->as[k].entry_idx;
					min_entries++;
				}
				k++;
			}
		}

		(*checked)++;
		if (min_entries > *max_entries)
			*max_entries = min_entries;

		if (!contained) {
			(*split)++;
			/*
			 * Only a violation where the bio *is* the durable unit.
			 * Elsewhere it is a structural observation, reported in
			 * coverage rather than as a verdict.
			 */
			if (c->dia == DIA_NONE && viol_begin(v))
				printf("{\"invariant\":\"bio_containment\""
				       ",\"detail\":\"application atomic write spans"
				       " more than one bio; with no data journal there"
				       " is nothing below to make it atomic\""
				       ",\"page_id\":%" PRIu64 ",\"version\":%" PRIu64
				       ",\"blocks\":%u,\"log_entries\":%" PRIu64
				       ",\"epoch_first\":%" PRIu64
				       ",\"epoch_last\":%" PRIu64 "}",
				       page, ver, spu, min_entries, ep_lo, ep_hi);
		}
		i = j;
	}
}

static void usage(void)
{
	fprintf(stderr,
"usage: torner loginv --log <logdev> [options]\n"
"\n"
"  --log <path>        dm-log-writes log device or image\n"
"  --config <c>        tau-ext4 | tau-xfs | ext4-data | ext4[-*] | xfs | zfs*  [tau-ext4]\n"
"  --check I1[,I2,I3,I4,I5]  invariants to run             [I1]\n"
"                      I5 applies to every config; I1-I4 need a tau journal\n"
"  --i1-strict         I1 on the record's own flush only, ignoring the host\n"
"                      commit a flush-less record names (the pre-#376 rule)\n"
"  --fsblock <bytes>   file system block size              [4096]\n"
"  --stat-only         parse and report counters, run no invariant\n"
"  --max-violations n  cap the reported list               [64]\n"
"\n"
"exit: 0 = all requested invariants hold, 2 = violation, 1 = error/unusable\n");
}

int torner_loginv(int argc, char **argv)
{
	const char *logpath = NULL, *config = "tau-ext4", *checks = "I1";
	struct ctx c;
	struct viol_out v;
	struct log_write_super_d sup;
	struct walkbuf wb = { NULL, NULL, 0 };
	struct i1stat st;
	uint64_t max_viol = 64;
	uint64_t i5_checked = 0, i5_split = 0, i5_max_entries = 0;
	int want_i5;
	int fd = -1, i, rc = 1, stat_only = 0, want_i1, need_txs;
	int want_i2, want_i3, want_i4;
	struct i2stat s2;
	struct i3stat s3;
	struct i4stat s4;
	struct jtref *jr = NULL, *cd = NULL;
	size_t jr_n = 0, cd_n = 0;
	struct i5stat s5;

	memset(&c, 0, sizeof(c));
	memset(&st, 0, sizeof(st));
	memset(&s5, 0, sizeof(s5));
	memset(&s2, 0, sizeof(s2));
	memset(&s3, 0, sizeof(s3));
	memset(&s4, 0, sizeof(s4));
	torner_crc32_init();
	c.begin_entry = -1;
	c.fsblk = TAU_BLOCK_SIZE;
	c.debug = getenv("TORNER_LOGINV_DEBUG") != NULL;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *val = (i + 1 < argc) ? argv[i + 1] : NULL;

#define NEEDV() do { if (!val) { usage(); return 1; } i++; } while (0)
		if (!strcmp(a, "--log"))              { NEEDV(); logpath = val; }
		else if (!strcmp(a, "--config"))      { NEEDV(); config = val; }
		else if (!strcmp(a, "--check"))       { NEEDV(); checks = val; }
		else if (!strcmp(a, "--fsblock"))     { NEEDV(); c.fsblk = strtoul(val, NULL, 0); }
		else if (!strcmp(a, "--max-violations")) { NEEDV(); max_viol = strtoull(val, NULL, 0); }
		else if (!strcmp(a, "--i1-strict"))   { c.i1_strict = 1; }
		else if (!strcmp(a, "--stat-only"))   { stat_only = 1; }
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
		else {
			fprintf(stderr, "torner loginv: unknown option '%s'\n", a);
			usage();
			return 1;
		}
#undef NEEDV
	}

	if (!logpath) {
		fprintf(stderr, "torner loginv: --log is required\n");
		usage();
		return 1;
	}
	if (c.fsblk < 512 || c.fsblk % 512) {
		fprintf(stderr, "torner loginv: bad --fsblock\n");
		return 1;
	}
	if (!strcmp(config, "tau-ext4")) {
		c.dia = DIA_TAU;
		c.host = HOST_JBD2;
	} else if (!strcmp(config, "tau-xfs")) {
		c.dia = DIA_TAU;
		c.host = HOST_XFS;
	} else if (!strcmp(config, "ext4-data"))
		c.dia = DIA_JBD2;
	/* ext4's other variants (ext4-dioread-lock, ext4-nodelalloc) journal
	 * metadata only, as plain ext4 does */
	else if (!strcmp(config, "ext4") || !strcmp(config, "xfs") ||
		 !strncmp(config, "ext4-", 5))
		c.dia = DIA_NONE;
	else if (!strncmp(config, "zfs", 3))
		c.dia = DIA_COW;
	else {
		fprintf(stderr, "torner loginv: unknown --config '%s'\n", config);
		return 1;
	}
	if (c.dia == DIA_TAU && c.fsblk != TAU_BLOCK_SIZE) {
		fprintf(stderr, "torner loginv: a tau journal has %u-byte blocks\n",
			TAU_BLOCK_SIZE);
		return 1;
	}
	want_i1 = !stat_only && c.dia == DIA_TAU && strstr(checks, "I1") != NULL;
	want_i2 = !stat_only && c.dia == DIA_TAU && strstr(checks, "I2") != NULL;
	want_i3 = !stat_only && c.dia == DIA_TAU && strstr(checks, "I3") != NULL;
	want_i4 = !stat_only && c.dia == DIA_TAU && strstr(checks, "I4") != NULL;
	/* bio containment keys off the workload's own self-describing sectors,
	 * so it applies to every configuration -- no journal format needed. */
	want_i5 = !stat_only && (strstr(checks, "I5") != NULL ||
				 strstr(checks, "bio") != NULL);

	fd = open(logpath, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "torner loginv: open %s: %s\n",
			logpath, strerror(errno));
		return 1;
	}
	if (read(fd, &sup, sizeof(sup)) != (ssize_t)sizeof(sup)) {
		fprintf(stderr, "torner loginv: short read on superblock\n");
		goto out;
	}
	if (sup.magic != WRITE_LOG_MAGIC) {
		fprintf(stderr, "torner loginv: bad log magic 0x%" PRIx64
			" (expected 0x%" PRIx64 ")\n",
			sup.magic, (uint64_t)WRITE_LOG_MAGIC);
		goto out;
	}
	if (sup.version != WRITE_LOG_VERSION) {
		fprintf(stderr, "torner loginv: log version %" PRIu64
			", this build understands %" PRIu64 "\n",
			sup.version, (uint64_t)WRITE_LOG_VERSION);
		goto out;
	}
	c.sectorsize = sup.sectorsize;
	if (!c.sectorsize || c.sectorsize % 512) {
		fprintf(stderr, "torner loginv: bad sectorsize %u\n", c.sectorsize);
		goto out;
	}
	wb.hdr = xrealloc(NULL, c.sectorsize);

	/*
	 * Separate passes: the superblock, the segment map and the HOME tags can
	 * each appear anywhere in the stream, and nothing can be attributed until
	 * what it depends on has been seen.
	 */
	if (walk(&c, fd, &sup, pass_sb, 0, &wb))
		goto out;
	if (c.have_geom) {
		c.idx_n = (size_t)c.map_nr * TAU_SEGMENT_ENT_MAX;
		c.idx2pba = xrealloc(NULL, c.idx_n * sizeof(*c.idx2pba));
		memset(c.idx2pba, 0, c.idx_n * sizeof(*c.idx2pba));
		c.idx2ino = xrealloc(NULL, c.idx_n * sizeof(*c.idx2ino));
		memset(c.idx2ino, 0, c.idx_n * sizeof(*c.idx2ino));
		if (walk(&c, fd, &sup, pass_map, 0, &wb))
			goto out;
		finish_regions(&c);
	}
	if (walk(&c, fd, &sup, pass_classify, 1, &wb))
		goto out;
	/* I5 on tau needs the transactions I1 rebuilds, HOME blocks and all */
	need_txs = c.dia == DIA_TAU && (want_i1 || want_i2 || want_i3 || want_i4 ||
					want_i5);
	if (need_txs && (c.home_n || c.jtag_n || c.rt_n)) {
		size_t r;

		/* every block a record vouches for at home: HOME tags, the home
		 * blocks of journal copies (I2) and of revoke tags (I3) */
		c.homeset_n = c.home_n + c.jtag_n + c.rt_n;
		c.homeset = xrealloc(NULL, c.homeset_n * sizeof(*c.homeset));
		memcpy(c.homeset, c.home, c.home_n * sizeof(*c.homeset));
		memcpy(c.homeset + c.home_n, c.jtag, c.jtag_n * sizeof(*c.homeset));
		for (r = 0; r < c.rt_n; r++)
			c.homeset[c.home_n + c.jtag_n + r] = c.rt[r].pblk;
		qsort(c.homeset, c.homeset_n, sizeof(*c.homeset), u64_cmp);
		{
			size_t a, n = 0;

			for (a = 0; a < c.homeset_n; a++)
				if (!n || c.homeset[n - 1] != c.homeset[a])
					c.homeset[n++] = c.homeset[a];
			c.homeset_n = n;
		}
		if (walk(&c, fd, &sup, pass_home, 0, &wb))
			goto out;
	}

	/* ---- report ---- */
	printf("{\"tool\":\"torner-loginv\",\"config\":\"%s\"", config);
	printf(",\"log\":{\"entries\":%" PRIu64 ",\"epochs\":%" PRIu64
	       ",\"fepochs\":%" PRIu64
	       ",\"flush\":%" PRIu64 ",\"fua\":%" PRIu64 ",\"discard\":%" PRIu64
	       ",\"mark\":%" PRIu64 ",\"metadata\":%" PRIu64
	       ",\"data_bytes\":%" PRIu64 ",\"sectorsize\":%u"
	       ",\"begin_entry\":%" PRId64 "}",
	       c.entries, c.epochs, c.fepochs, c.n_flush, c.n_fua, c.n_discard,
	       c.n_mark, c.n_meta, c.bytes_data, c.sectorsize, c.begin_entry);

	printf(",\"journal\":{\"superblock_lba\":%" PRIu64
	       ",\"segment_blocks\":%" PRIu64 ",\"map_blocks\":%" PRIu64
	       ",\"segments\":%zu"
	       ",\"descriptors\":%" PRIu64 ",\"commits\":%" PRIu64
	       ",\"revokes\":%" PRIu64 ",\"maplog_blocks\":%" PRIu64
	       ",\"maplog_frees\":%zu,\"home_tags\":%zu"
	       ",\"host_commits\":%zu"
	       ",\"foreign_magic_blocks\":%" PRIu64 "}",
	       c.sb_lba, c.seg_blks, c.map_nr, c.nregions,
	       c.n_desc, c.n_commit, c.n_revoke, c.n_maplog, c.sf_n,
	       c.home_n, c.hc_n, c.n_foreign);
	if (c.dia == DIA_JBD2)
		printf(",\"jbd2\":{\"superblock_lba\":%" PRIu64 ",\"maxlen\":%" PRIu64
		       ",\"first\":%" PRIu64 ",\"incompat\":%u"
		       ",\"descriptors\":%" PRIu64 ",\"commits\":%" PRIu64
		       ",\"tagged_blocks\":%zu}",
		       c.jsb_lba, c.jmaxlen, c.jfirst, c.jincompat, c.n_jdesc,
		       c.n_jcommit, c.own_n);

	/*
	 * Refuse rather than report a clean run when the log cannot support a
	 * verdict.  Both of these produce "zero violations" while checking
	 * nothing, which is the failure mode that makes a checker worthless.
	 */
	if (c.entries && !c.n_flush && !c.n_fua) {
		printf(",\"usable\":false,\"reason\":\"no FLUSH/FUA entries --"
		       " backing device advertises no write cache, so epochs are"
		       " meaningless (dm-log-writes.c:694)\"");
		printf(",\"checks\":{},\"violations\":[]}\n");
		rc = 1;
		goto out;
	}
	if (c.dia == DIA_TAU && (!c.have_geom || !c.nregions)) {
		printf(",\"usable\":false,\"reason\":\"config is %s but no tau"
		       " journal is in the stream (superblock or segment map"
		       " absent) -- check that the workload opted in with"
		       " O_TAU_UNTORN, or mount with tjournal_all\"", config);
		printf(",\"checks\":{},\"violations\":[]}\n");
		rc = 1;
		goto out;
	}
	if (c.dia == DIA_JBD2 && want_i5 && !c.have_jgeom) {
		printf(",\"usable\":false,\"reason\":\"config is ext4-data but no"
		       " jbd2 journal superblock is in the stream\"");
		printf(",\"checks\":{},\"violations\":[]}\n");
		rc = 1;
		goto out;
	}
	printf(",\"usable\":true");

	/*
	 * A stock file system has no tau journal, so I1 is not applicable
	 * rather than passing.  The distinction matters: "no violations" from a
	 * checker that had nothing to check is the failure this tool exists to
	 * avoid reporting.
	 */
	printf(",\"checks\":{\"I1\":\"%s\",\"I2\":\"%s\""
	       ",\"I3\":\"%s\",\"I4\":\"%s\""
	       ",\"I5\":\"%s\",\"bio_containment\":\"%s\"}",
	       c.dia != DIA_TAU ? "not_applicable" : (want_i1 ? "run" : "skipped"),
	       c.dia != DIA_TAU ? "not_applicable" : (want_i2 ? "run" : "skipped"),
	       c.dia != DIA_TAU ? "not_applicable" : (want_i3 ? "run" : "skipped"),
	       c.dia != DIA_TAU ? "not_applicable" : (want_i4 ? "run" : "skipped"),
	       /* the durable unit: the bio with no data journal, the jbd2
		* transaction on ext4 data=journal, the tau transaction; ZFS's
		* transaction group is out of scope */
	       c.dia == DIA_COW ? "not_implemented" : (want_i5 ? "run" : "skipped"),
	       want_i5 ? "run" : "skipped");
	if (want_i1)
		printf(",\"i1_model\":\"%s\"", c.i1_strict ? "strict" : "gated");

	viol_open(&v, max_viol);
	if (need_txs)
		check_i1(&c, &v, &st, want_i1);
	if (want_i2 || want_i3)
		build_refs(&c, &jr, &jr_n, &cd, &cd_n);
	if (want_i2)
		check_i2(&c, &v, &s2, jr, jr_n, cd, cd_n);
	if (want_i3)
		check_i3(&c, &v, &s3, jr, jr_n);
	if (want_i4)
		check_i4(&c, &v, &s4);
	if (want_i5) {
		/* on a stock FS the bio is the unit: bio containment is I5 */
		check_bio_containment(&c, &v, &i5_checked, &i5_split,
				      &i5_max_entries);
		if (c.dia == DIA_TAU || c.dia == DIA_JBD2)
			check_i5_units(&c, &v, &s5);
	}
	viol_close(&v);

	printf(",\"coverage\":{\"i1_transactions_checked\":%" PRIu64
	       ",\"i1_transactions_skipped\":%" PRIu64
	       ",\"i1_skipped_no_descriptor\":%" PRIu64
	       ",\"i1_skipped_multi_segment\":%" PRIu64
	       ",\"i1_blocks_examined\":%" PRIu64
	       ",\"i1_home_blocks\":%" PRIu64
	       ",\"i1_blocks_missing\":%" PRIu64
	       ",\"i1_blocks_ambiguous\":%" PRIu64
	       ",\"i1_home_blocks_ambiguous\":%" PRIu64
	       ",\"i1_two_segment\":%" PRIu64
	       ",\"i1_claim_blocks\":%" PRIu64
	       ",\"i1_ordered_own_flush\":%" PRIu64
	       ",\"i1_ordered_by_host_commit\":%" PRIu64
	       ",\"i1_gate_never_open\":%" PRIu64
	       ",\"i1_strict_unordered\":%" PRIu64
	       ",\"i1_violations\":%" PRIu64
	       ",\"i1_violations_ungated\":%" PRIu64
	       ",\"app_writes_checked\":%" PRIu64
	       ",\"app_writes_spanning_multiple_bios\":%" PRIu64
	       ",\"max_bios_per_app_write\":%" PRIu64
	       ",\"i5_writes_checked\":%" PRIu64
	       ",\"i5_writes_split\":%" PRIu64
	       ",\"i5_writes_partial\":%" PRIu64
	       ",\"i5_writes_in_no_unit\":%" PRIu64
	       ",\"i5_writes_split_in_run\":%" PRIu64
	       ",\"i5_writes_partial_in_run\":%" PRIu64
	       ",\"i2_transactions\":%" PRIu64 ",\"i2_never_passed\":%" PRIu64
	       ",\"i2_bound_by_free\":%" PRIu64 ",\"i2_bound_by_snapshot\":%" PRIu64
	       ",\"i2_blocks\":%" PRIu64 ",\"i2_covered_home\":%" PRIu64
	       ",\"i2_covered_handoff\":%" PRIu64 ",\"i2_deferred\":%" PRIu64
	       ",\"i2_uncovered\":%" PRIu64 ",\"i2_leads\":%" PRIu64
	       ",\"i2_snapshot_leads\":%" PRIu64
	       ",\"tail_blk_checked\":%" PRIu64 ",\"tail_blk_bad\":%" PRIu64
	       ",\"i3_scoped_tags\":%" PRIu64 ",\"i3_cond_tags\":%" PRIu64
	       ",\"i3_vacuous\":%" PRIu64 ",\"i3_covered_home\":%" PRIu64
	       ",\"i3_covered_copy\":%" PRIu64 ",\"i3_violations\":%" PRIu64
	       ",\"i4_base_moves\":%" PRIu64 ",\"i4_map_writes\":%" PRIu64
	       ",\"i4_log_overwrites\":%" PRIu64 ",\"i4_owners_named\":%" PRIu64
	       ",\"i4_owners_claimed\":%" PRIu64 ",\"i4_segment_reuses\":%" PRIu64
	       ",\"i4_violations\":%" PRIu64 "}",
	       st.checked, st.skipped_nodesc + st.skipped_multiseg,
	       st.skipped_nodesc, st.skipped_multiseg, st.blocks,
	       st.home_blocks, st.missing, st.ambiguous, st.home_ambiguous,
	       st.two_segment, st.claim_blocks, st.own, st.gated,
	       st.gate_closed, st.strict, st.viol, st.viol_ungated,
	       i5_checked, i5_split, i5_max_entries,
	       s5.checked, s5.split, s5.partial, s5.unjournaled,
	       s5.split_run, s5.partial_run,
	       s2.txs, s2.never, s2.by_free, s2.by_snapshot, s2.blocks, s2.home,
	       s2.handoff, s2.deferred, s2.uncovered, s2.leads, s2.snapshot_leads,
	       s2.tailblk_checked, s2.tailblk_bad,
	       s3.scoped, s3.cond, s3.vacuous, s3.home, s3.copy, s3.violations,
	       s4.base_moves, s4.map_writes, s4.overwrites, s4.owners_named,
	       s4.owners_claimed, s4.reuses, s4.violations);
	printf(",\"violation_count\":%" PRIu64 "}\n", v.n);

	rc = v.n ? 2 : 0;

out:
	free(wb.hdr);
	free(wb.data);
	free(c.jb);
	free(c.jw);
	free(c.hw);
	free(c.home);
	free(c.homeset);
	free(c.hc);
	free(c.sf);
	free(c.cw);
	free(c.jtag);
	free(c.rt);
	free(c.sbw);
	free(c.mw);
	free(c.ment);
	free(c.ce);
	free(c.mlw);
	free(c.idx2ino);
	free(c.tx);
	free(c.txjt);
	free(c.txrt);
	free(c.txof);
	free(c.cix);
	free(c.cpos);
	free(jr);
	free(cd);
	free(c.as);
	free(c.regions);
	free(c.idx2pba);
	free(c.own);
	if (fd >= 0)
		close(fd);
	return rc;
}
