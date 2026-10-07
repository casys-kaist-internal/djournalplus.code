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
 * Which journal's invariants this run is about.  DIA_NONE is a stock file
 * system with no tau journal: there is nothing for I1 to say, and saying
 * "pass" would be a lie.
 */
/*
 * DIA_NONE is a stock ext4/xfs: no data journal, so the bio IS the durable
 * unit and bio containment is a verdict.  DIA_COW is ZFS, where the durable
 * unit is the transaction group -- CRASH_TODO §3.5 rules its on-disk format
 * out of scope, so it is measured through T2b only and no log invariant
 * applies.
 */
enum dialect { DIA_TAU, DIA_JBD2, DIA_NONE, DIA_COW };

/* One journal metadata block seen in the stream. */
struct jblk {
	uint64_t lba;
	uint64_t entry_idx;
	uint64_t epoch;
	uint64_t fepoch;	/* FLUSH-separated: the durability order */
	uint32_t blocktype;
	uint32_t sequence;
	uint64_t next_segment;
	uint64_t inode_number;
	uint64_t commit_epoch_field;	/* commit blocks: h_epoch */
};

/*
 * One torner data sector seen in the stream, for I5.
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
	uint32_t sector_idx;
	uint32_t spu;
};

/* A write landing inside the journal region, for epoch lookups. */
struct jwrite {
	uint64_t lba;
	uint64_t epoch;
	uint64_t fepoch;
	uint64_t entry_idx;
	uint8_t	 fua;		/* durable on its own completion */
};

struct region {
	uint64_t start;		/* first block */
	uint64_t end;		/* one past last */
};

struct ctx {
	enum dialect dia;
	uint32_t fsblk;
	uint32_t sectorsize;

	/* journal geometry, discovered in pass 1 */
	int	 have_geom;
	uint64_t sb_lba;	/* tau superblock == j_blk_offset */
	uint64_t seg_blks;	/* blocks per segment */
	struct region *regions;
	size_t	 nregions;

	struct jblk *jb;
	size_t jb_n, jb_cap;

	struct jwrite *jw;
	size_t jw_n, jw_cap;

	struct appsec *as;
	size_t as_n, as_cap;

	uint64_t entries, epochs, last_epoch;
	uint64_t fepochs, last_fepoch;
	uint64_t n_flush, n_fua, n_discard, n_mark, n_meta;
	uint64_t n_desc, n_commit, n_revoke, n_foreign;
	uint64_t bytes_data;
};

static void *xrealloc(void *p, size_t n)
{
	void *q = realloc(p, n);

	if (!q) {
		fprintf(stderr, "torner loginv: out of memory\n");
		exit(1);
	}
	return q;
}

static int in_journal(const struct ctx *c, uint64_t lba)
{
	size_t i;

	for (i = 0; i < c->nregions; i++)
		if (lba >= c->regions[i].start && lba < c->regions[i].end)
			return 1;
	return 0;
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

static void add_region(struct ctx *c, uint64_t start, uint64_t len)
{
	size_t i;

	for (i = 0; i < c->nregions; i++)
		if (c->regions[i].start == start)
			return;
	c->regions = xrealloc(c->regions, (c->nregions + 1) * sizeof(*c->regions));
	c->regions[c->nregions].start = start;
	c->regions[c->nregions].end = start + len;
	c->nregions++;
}

/*
 * Pass 1 -- find the tau superblock and, from the segment map that follows it,
 * the physical extents the journal actually occupies.  Segments are allocated
 * dynamically (fs/taujournal/journal.c: jballoc), so this cannot be a constant.
 *
 * Layout, from fs/taujournal/journal.c:657,682-704:
 *   j_blk_offset      tau superblock
 *   +1 .. +seg_map_nr segment map, TAU_SEGMENT_ENT_MAX entries of {pba, ino}
 */
static void scan_geometry(struct ctx *c, const uint8_t *buf, uint64_t bytes,
			  uint64_t first_lba)
{
	uint64_t off;

	for (off = 0; off + c->fsblk <= bytes; off += c->fsblk) {
		const uint8_t *b = buf + off;
		uint64_t lba = first_lba + off / c->fsblk;
		uint64_t segsz;

		if (!c->have_geom) {
			if (be32_at(b, TAU_HDR_OFF_MAGIC) != TAU_MAGIC_NUMBER)
				continue;
			if (!is_tau_superblock(b, &segsz))
				continue;
			c->sb_lba = lba;
			c->seg_blks = segsz / TAU_BLOCK_SIZE;
			c->have_geom = 1;
			continue;
		}

		/* segment map blocks sit immediately after the superblock */
		if (lba > c->sb_lba && lba <= c->sb_lba + TAU_SEGMAP_SCAN_MAX) {
			uint32_t e;

			for (e = 0; e < TAU_SEGMENT_ENT_MAX; e++) {
				uint64_t pba = be64_at(b, (size_t)e * 16);

				if (!pba)
					continue;
				add_region(c, pba, c->seg_blks);
			}
		}
	}
}

static void jb_add(struct ctx *c, const struct jblk *j)
{
	if (c->jb_n == c->jb_cap) {
		c->jb_cap = c->jb_cap ? c->jb_cap * 2 : 1024;
		c->jb = xrealloc(c->jb, c->jb_cap * sizeof(*c->jb));
	}
	c->jb[c->jb_n++] = *j;
}

static void jw_add(struct ctx *c, uint64_t lba, uint64_t epoch,
		   uint64_t fepoch, int fua, uint64_t idx)
{
	if (c->jw_n == c->jw_cap) {
		c->jw_cap = c->jw_cap ? c->jw_cap * 2 : 4096;
		c->jw = xrealloc(c->jw, c->jw_cap * sizeof(*c->jw));
	}
	c->jw[c->jw_n].lba = lba;
	c->jw[c->jw_n].epoch = epoch;
	c->jw[c->jw_n].fepoch = fepoch;
	c->jw[c->jw_n].fua = fua ? 1 : 0;
	c->jw[c->jw_n].entry_idx = idx;
	c->jw_n++;
}

static void as_add(struct ctx *c, const struct appsec *a)
{
	if (c->as_n == c->as_cap) {
		c->as_cap = c->as_cap ? c->as_cap * 2 : 8192;
		c->as = xrealloc(c->as, c->as_cap * sizeof(*c->as));
	}
	c->as[c->as_n++] = *a;
}

/* Recognise a torner data sector and pull out what I5 needs. */
static int parse_appsec(const uint8_t *b, struct appsec *a)
{
	uint64_t magic;
	uint32_t spu, ssz;

	memcpy(&magic, b + 0, 8);
	if (magic != TORNER_SECTOR_MAGIC)
		return 0;
	memcpy(&a->page_id, b + 8, 8);
	memcpy(&a->version, b + 16, 8);
	memcpy(&a->sector_idx, b + 36, 4);
	memcpy(&spu, b + 40, 4);
	memcpy(&ssz, b + 44, 4);
	if (!spu || spu > TORNER_MAX_SECTORS_PER_UNIT || a->sector_idx >= spu)
		return 0;
	a->spu = spu;
	return 1;
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

/* Pass 2 -- classify blocks and record journal-region writes. */
static void scan_payload(struct ctx *c, const uint8_t *buf, uint64_t bytes,
			 uint64_t first_lba, uint64_t epoch, uint64_t fepoch,
			 int fua, uint64_t idx)
{
	uint64_t off;

	for (off = 0; off + c->fsblk <= bytes; off += c->fsblk) {
		const uint8_t *b = buf + off;
		uint64_t lba = first_lba + off / c->fsblk;
		struct jblk j;
		uint32_t bt;
		int mine;

		mine = in_journal(c, lba);
		if (mine)
			jw_add(c, lba, epoch, fepoch, fua, idx);

		{
			struct appsec a;

			if (parse_appsec(b, &a)) {
				a.entry_idx = idx;
				a.epoch = epoch;
				as_add(c, &a);
			}
		}

		if (be32_at(b, TAU_HDR_OFF_MAGIC) != TAU_MAGIC_NUMBER)
			continue;
		bt = be32_at(b, TAU_HDR_OFF_BLOCKTYPE);

		/*
		 * Outside the journal extents this magic belongs to some other
		 * journal (jbd2 on a tau-ext4 stack).  Count it so coverage is
		 * visible, but never assert tau invariants on it.
		 */
		if (!mine) {
			c->n_foreign++;
			continue;
		}

		memset(&j, 0, sizeof(j));
		j.lba = lba;
		j.entry_idx = idx;
		j.epoch = epoch;
		j.fepoch = fepoch;
		j.blocktype = bt;
		j.sequence = be32_at(b, TAU_HDR_OFF_SEQUENCE);
		j.next_segment = be64_at(b, TAU_HDR_OFF_NEXT_SEGMENT);
		j.inode_number = be64_at(b, TAU_HDR_OFF_INODE_NUMBER);

		switch (bt) {
		case TAU_DESCRIPTOR_BLOCK:
			c->n_desc++;
			break;
		case TAU_COMMIT_BLOCK:
			j.commit_epoch_field = be64_at(b, TAU_COMMIT_OFF_EPOCH);
			c->n_commit++;
			break;
		case TAU_REVOKE_BLOCK:
			c->n_revoke++;
			break;
		default:
			c->n_foreign++;
			continue;
		}
		jb_add(c, &j);
	}
}

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

/*
 * I1 -- every block a transaction commits must be durable before its commit
 * block can be.  "Durable before" is decided by FLUSH alone: a data block d is
 * guaranteed on media ahead of commit c iff a FLUSH lies between them
 * (fepoch(c) > fepoch(d)), or d itself was written FUA.  If that fails, a
 * crash can leave the commit durable and its data not, and recovery replays
 * garbage over a live file.  This is the invariant tauJournal's atomicity
 * claim rests on.
 *
 * A FUA write is not a barrier -- it makes only itself durable.  An earlier
 * version of this check split epochs on FUA as well (as CrashMonkey's
 * permuter does), and then any unrelated FUA write that happened to fall
 * between a transaction's data and its commit -- a journal superblock update,
 * say -- made a commit issued without a preflush look correctly ordered.
 *
 * The one thing the log cannot show is submission order: a FUA write issued
 * concurrently with a FLUSH, rather than after it completed, is logged the
 * same way.  Commits issued as PREFLUSH|FUA are sequenced by the block layer
 * and are not affected.
 *
 * A transaction occupies [first descriptor with this sequence, commit block).
 * Every journal-region write in that extent is part of it -- descriptors,
 * their data blocks, and any revoke blocks.
 */
static void check_i1(struct ctx *c, struct viol_out *v, uint64_t *checked,
		     uint64_t *skipped, uint64_t *blocks)
{
	size_t i, k;

	for (i = 0; i < c->jb_n; i++) {
		const struct jblk *cm = &c->jb[i];
		const struct jblk *desc = NULL;
		uint64_t worst_epoch = 0, worst_lba = 0, worst_entry = 0;
		uint64_t n_in = 0;
		int have_worst = 0;

		if (cm->blocktype != TAU_COMMIT_BLOCK)
			continue;
		/* worst_epoch below is a FLUSH epoch: the latest one any
		 * non-FUA block of this transaction was logged in */

		/* earliest descriptor of this sequence at or before the commit */
		for (k = 0; k < i; k++) {
			if (c->jb[k].blocktype != TAU_DESCRIPTOR_BLOCK)
				continue;
			if (c->jb[k].sequence != cm->sequence)
				continue;
			if (c->jb[k].inode_number != cm->inode_number)
				continue;	/* tids are per file (tau->tx_seq) */
			desc = &c->jb[k];
			break;
		}
		if (!desc || desc->lba >= cm->lba) {
			/* no descriptor, or the journal wrapped between the two
			 * so the extent is not a simple range -- do not guess */
			(*skipped)++;
			continue;
		}

		(*checked)++;

		for (k = 0; k < c->jw_n; k++) {
			const struct jwrite *w = &c->jw[k];

			if (w->lba < desc->lba || w->lba >= cm->lba)
				continue;
			if (w->entry_idx > cm->entry_idx)
				continue;	/* a later transaction reusing space */
			n_in++;
			if (w->fua)
				continue;	/* durable on its own completion */
			if (!have_worst || w->fepoch >= worst_epoch) {
				worst_epoch = w->fepoch;
				worst_lba = w->lba;
				worst_entry = w->entry_idx;
				have_worst = 1;
			}
		}
		*blocks += n_in;

		if (have_worst && cm->fepoch <= worst_epoch && viol_begin(v)) {
			printf("{\"invariant\":\"I1\""
			       ",\"detail\":\"commit not ordered after data\""
			       ",\"sequence\":%u"
			       ",\"commit_lba\":%" PRIu64
			       ",\"commit_epoch\":%" PRIu64
			       ",\"commit_entry\":%" PRIu64
			       ",\"data_lba\":%" PRIu64
			       ",\"data_epoch\":%" PRIu64
			       ",\"data_entry\":%" PRIu64
			       ",\"first_descriptor_lba\":%" PRIu64
			       ",\"blocks_in_transaction\":%" PRIu64
			       ",\"epoch_model\":\"flush\"}",
			       cm->sequence, cm->lba, cm->fepoch, cm->entry_idx,
			       worst_lba, worst_epoch, worst_entry,
			       desc->lba, n_in);
		}
	}
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
		uint64_t best_entry = 0, min_entries = 0;
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
				uint32_t mask = 0, n = 0;
				size_t m = k;

				while (m < j && c->as[m].entry_idx == ent) {
					if (!(mask & (1u << c->as[m].sector_idx))) {
						mask |= 1u << c->as[m].sector_idx;
						n++;
					}
					m++;
				}
				if (n == spu) {
					contained = 1;
					best_entry = ent;
				}
				k = m;
			}
		}

		ep_lo = c->as[i].epoch;
		ep_hi = c->as[j - 1].epoch;
		min_entries = 0;
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
		(void)best_entry;
		i = j;
	}
}

static void usage(void)
{
	fprintf(stderr,
"usage: torner loginv --log <logdev> [options]\n"
"\n"
"  --log <path>        dm-log-writes log device or image\n"
"  --config <c>        tau-ext4 | tau-xfs | ext4-data      [tau-ext4]\n"
"  --check I1[,I5]     invariants to run                   [I1]\n"
"                      I5 applies to every config; I1 needs a tau journal\n"
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
	uint8_t *hdrbuf = NULL, *data = NULL;
	uint64_t max_viol = 64, i1_checked = 0, i1_skipped = 0, i1_blocks = 0;
	uint64_t i5_checked = 0, i5_split = 0, i5_max_entries = 0;
	int want_i5;
	size_t data_cap = 0;
	int fd = -1, i, rc = 1, stat_only = 0, want_i1, pass;

	memset(&c, 0, sizeof(c));
	c.fsblk = TAU_BLOCK_SIZE;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *val = (i + 1 < argc) ? argv[i + 1] : NULL;

#define NEEDV() do { if (!val) { usage(); return 1; } i++; } while (0)
		if (!strcmp(a, "--log"))              { NEEDV(); logpath = val; }
		else if (!strcmp(a, "--config"))      { NEEDV(); config = val; }
		else if (!strcmp(a, "--check"))       { NEEDV(); checks = val; }
		else if (!strcmp(a, "--fsblock"))     { NEEDV(); c.fsblk = strtoul(val, NULL, 0); }
		else if (!strcmp(a, "--max-violations")) { NEEDV(); max_viol = strtoull(val, NULL, 0); }
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
	if (!strcmp(config, "tau-ext4") || !strcmp(config, "tau-xfs"))
		c.dia = DIA_TAU;
	else if (!strcmp(config, "ext4-data"))
		c.dia = DIA_JBD2;
	else if (!strcmp(config, "ext4") || !strcmp(config, "xfs"))
		c.dia = DIA_NONE;
	else if (!strncmp(config, "zfs", 3))
		c.dia = DIA_COW;
	else {
		fprintf(stderr, "torner loginv: unknown --config '%s'\n", config);
		return 1;
	}
	want_i1 = !stat_only && c.dia == DIA_TAU && strstr(checks, "I1") != NULL;
	/* I5 keys off the workload's own self-describing sectors, so it applies
	 * to every configuration -- no journal format needed. */
	want_i5 = !stat_only && (strstr(checks, "I5") != NULL ||
				 strstr(checks, "bio") != NULL);

	fd = open(logpath, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "torner loginv: open %s: %s\n",
			logpath, strerror(errno));
		return 1;
	}

	/*
	 * Two passes: the superblock and segment map can appear anywhere in
	 * the stream, and nothing can be attributed to tau until they have.
	 */
	for (pass = 1; pass <= 2; pass++) {
		off_t pos;

		if (lseek(fd, 0, SEEK_SET) < 0)
			goto out;
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
			fprintf(stderr, "torner loginv: bad sectorsize %u\n",
				c.sectorsize);
			goto out;
		}
		if (!hdrbuf) {
			hdrbuf = malloc(c.sectorsize);
			if (!hdrbuf)
				goto out;
		}

		pos = lseek(fd, c.sectorsize, SEEK_SET);
		if (pos < 0)
			goto out;

		c.entries = 0;
		c.epochs = 1;
		c.fepochs = 1;
		if (pass == 2) {
			c.n_flush = c.n_fua = c.n_discard = c.n_mark = c.n_meta = 0;
			c.bytes_data = 0;
		}

		while (c.entries < sup.nr_entries) {
			struct log_write_entry_d ent;
			uint64_t bytes, flags;
			ssize_t n;

			n = read(fd, hdrbuf, c.sectorsize);
			if (n <= 0)
				break;
			if (n != (ssize_t)c.sectorsize) {
				if (pass == 2)
					fprintf(stderr, "torner loginv: truncated"
						" entry header at %" PRIu64 "\n",
						c.entries);
				break;
			}
			memcpy(&ent, hdrbuf, sizeof(ent));
			c.entries++;

			flags = ent.flags;
			bytes = ent.nr_sectors * (uint64_t)c.sectorsize;

			if (pass == 2) {
				if (flags & LOG_FLUSH_FLAG)	c.n_flush++;
				if (flags & LOG_FUA_FLAG)	c.n_fua++;
				if (flags & LOG_DISCARD_FLAG)	c.n_discard++;
				if (flags & LOG_MARK_FLAG)	c.n_mark++;
				if (flags & LOG_METADATA_FLAG)	c.n_meta++;
			}

			/* DISCARD carries no payload; MARK keeps its string in
			 * the header sector, not as a payload block. */
			if (bytes && !(flags & LOG_DISCARD_FLAG)) {
				if (bytes > data_cap) {
					data_cap = bytes;
					data = xrealloc(data, data_cap);
				}
				if (read(fd, data, bytes) != (ssize_t)bytes) {
					if (pass == 2)
						fprintf(stderr, "torner loginv:"
							" truncated payload at %"
							PRIu64 "\n", c.entries - 1);
					break;
				}
				if (pass == 2)
					c.bytes_data += bytes;

				if (!(flags & LOG_MARK_FLAG)) {
					uint64_t blk = ent.sector *
						(uint64_t)c.sectorsize / c.fsblk;

					if (pass == 1)
						scan_geometry(&c, data, bytes, blk);
					else
						scan_payload(&c, data, bytes, blk,
							     c.epochs, c.fepochs,
							     (flags & LOG_FUA_FLAG) != 0,
							     c.entries - 1);
				}
			}

			c.last_epoch = c.epochs;
			c.last_fepoch = c.fepochs;
			if (flags & (LOG_FLUSH_FLAG | LOG_FUA_FLAG))
				c.epochs++;
			if (flags & LOG_FLUSH_FLAG)
				c.fepochs++;
		}
	}
	if (c.entries) {
		c.epochs = c.last_epoch;
		c.fepochs = c.last_fepoch;
	}

	/* ---- report ---- */
	printf("{\"tool\":\"torner-loginv\",\"config\":\"%s\"", config);
	printf(",\"log\":{\"entries\":%" PRIu64 ",\"epochs\":%" PRIu64
	       ",\"fepochs\":%" PRIu64
	       ",\"flush\":%" PRIu64 ",\"fua\":%" PRIu64 ",\"discard\":%" PRIu64
	       ",\"mark\":%" PRIu64 ",\"metadata\":%" PRIu64
	       ",\"data_bytes\":%" PRIu64 ",\"sectorsize\":%u}",
	       c.entries, c.epochs, c.fepochs, c.n_flush, c.n_fua, c.n_discard,
	       c.n_mark, c.n_meta, c.bytes_data, c.sectorsize);

	printf(",\"journal\":{\"superblock_lba\":%" PRIu64
	       ",\"segment_blocks\":%" PRIu64 ",\"segments\":%zu"
	       ",\"descriptors\":%" PRIu64 ",\"commits\":%" PRIu64
	       ",\"revokes\":%" PRIu64 ",\"foreign_magic_blocks\":%" PRIu64 "}",
	       c.sb_lba, c.seg_blks, c.nregions,
	       c.n_desc, c.n_commit, c.n_revoke, c.n_foreign);

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
	printf(",\"usable\":true");

	/*
	 * A stock file system has no tau journal, so I1 is not applicable
	 * rather than passing.  The distinction matters: "no violations" from a
	 * checker that had nothing to check is the failure this tool exists to
	 * avoid reporting.
	 */
	printf(",\"checks\":{\"I1\":\"%s\",\"I2\":\"not_implemented\""
	       ",\"I3\":\"not_implemented\",\"I4\":\"not_implemented\""
	       ",\"I5\":\"%s\",\"bio_containment\":\"%s\"}",
	       c.dia != DIA_TAU ? "not_applicable" : (want_i1 ? "run" : "skipped"),
	       /* I5 needs per-config durable units; only the no-data-journal
		* case is covered, where the bio is the durable unit. */
	       c.dia == DIA_NONE ? (want_i5 ? "run" : "skipped") : "not_implemented",
	       want_i5 ? "run" : "skipped");

	viol_open(&v, max_viol);
	if (want_i1)
		check_i1(&c, &v, &i1_checked, &i1_skipped, &i1_blocks);
	if (want_i5)
		check_bio_containment(&c, &v, &i5_checked, &i5_split,
				      &i5_max_entries);
	viol_close(&v);

	printf(",\"coverage\":{\"i1_transactions_checked\":%" PRIu64
	       ",\"i1_transactions_skipped\":%" PRIu64
	       ",\"i1_blocks_examined\":%" PRIu64
	       ",\"app_writes_checked\":%" PRIu64
	       ",\"app_writes_spanning_multiple_bios\":%" PRIu64
	       ",\"max_bios_per_app_write\":%" PRIu64 "}",
	       i1_checked, i1_skipped, i1_blocks,
	       i5_checked, i5_split, i5_max_entries);
	printf(",\"violation_count\":%" PRIu64 "}\n", v.n);

	rc = v.n ? 2 : 0;

out:
	free(hdrbuf);
	free(data);
	free(c.jb);
	free(c.jw);
	free(c.as);
	free(c.regions);
	if (fd >= 0)
		close(fd);
	return rc;
}
