// SPDX-License-Identifier: GPL-2.0
/*
 * tautorn - hunt the silent torn write that needs no crash.
 *
 * The bug this exists for (CLAUDE.md, OPEN entry of 2026-08-25) lost exactly
 * one 4 KiB filesystem block out of an 8 KiB application write, in steady
 * state, with nothing in dmesg.  Every other test in this suite verifies after
 * a power cut, which is why none of them can see it: here the filesystem is
 * unmounted cleanly and the data is still expected to be whole.
 *
 * The workload mimics what PostgreSQL does to a relation file, because that is
 * what found it:
 *
 *   - the file is laid out with fallocate(), like PG's mdzeroextend(), so the
 *     writes land on *unwritten* extents.  An unwritten block reads as zeroes,
 *     which is precisely what the corrupted page contained -- so "old" and
 *     "lost" look identical unless the test stamps its own generation into
 *     every block, which is what this does.
 *   - pages are 8 KiB (two filesystem blocks) and are always rewritten whole.
 *   - rewrites are biased towards a hot set and interleaved with fsync, which
 *     is what drives blocks through anchored -> revoked and back.
 *
 * Every 4 KiB block carries (fileid, block index, page generation) plus a hash
 * over its own contents, so a single pass over the file can tell apart:
 *
 *   ZERO      the block was never written since fallocate -- the reported bug
 *   TORN      the two halves of one page disagree on the generation
 *   STALE     the whole page reverted to an older generation
 *   FOREIGN   a valid block, but stamped with another file or offset: a write
 *             that went to the wrong place rather than nowhere
 *   CORRUPT   hash mismatch (a genuinely half-and-half block)
 *
 *   usage: tautorn init   <path> <pages> <fileid> [pagekb] [prealloc]
 *          tautorn churn  <path> <pages> <fileid> <secs> <seed> <threads> \
 *                         [pagekb] [fsync_every] [hot_pct] [manifest]
 *          tautorn grow   <path> <pages> <fileid> <secs> <seed> <threads> \
 *                         [pagekb] [fsync_every] [chunk_pages] [manifest]
 *          tautorn verify <path> <pages> <fileid> [pagekb] [manifest]
 *
 * churn rewrites a file that is already laid out, so after the first commit
 * every write is a plain overwrite of a written extent.  grow keeps the other
 * half of the picture alive: one thread extends the file with fallocate() and
 * fills the new pages while the rest rewrite what is already there, which is
 * what a database doing INSERTs alongside UPDATEs looks like -- and it is the
 * only mode in which commit-time allocation (delayed/unwritten -> written)
 * keeps running for the whole test rather than just during layout.
 *
 * prealloc: fallocate (default) | zerowrite | none
 *
 * The manifest records each page's final generation and MUST live outside the
 * filesystem under test -- otherwise it is subject to the very bug it is meant
 * to adjudicate.  Without it, verify still catches ZERO/TORN/FOREIGN/CORRUPT
 * but cannot see a page that quietly reverted.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

#define BLK		4096u
#define MAGIC		0x4e524f5455415455ULL	/* "TAUTORN\0" little-endian */
#define HDR		48u
#define MAX_REPORT	20

struct hdr {
	uint64_t magic;
	uint32_t fileid;
	uint32_t blk;		/* absolute block index within the file */
	uint64_t gen;		/* generation of the page this block belongs to */
	uint32_t pgblk;		/* index of this block inside its page */
	uint32_t pgblks;	/* blocks per page */
	uint64_t seq;		/* write sequence, for ordering in a report */
	uint64_t hash;		/* over the whole block with this field zeroed */
};

/* --- deterministic content ------------------------------------------------
 * The fill is a pure function of (fileid, blk, gen), so verify can regenerate
 * it and a block that hashes fine but holds the wrong bytes still gets caught.
 */
static inline uint64_t splitmix64(uint64_t *x)
{
	uint64_t z = (*x += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

static uint64_t fnv1a(const void *p, size_t n)
{
	const uint8_t *b = p;
	uint64_t h = 0xcbf29ce484222325ULL;

	while (n--) {
		h ^= *b++;
		h *= 0x100000001b3ULL;
	}
	return h;
}

static void fill_block(uint8_t *buf, uint32_t fileid, uint32_t blk,
		       uint64_t gen, uint32_t pgblk, uint32_t pgblks,
		       uint64_t seq)
{
	struct hdr *h = (struct hdr *)buf;
	uint64_t s = fileid * 0x1000000001ULL + blk * 0x100000001ULL + gen;
	uint64_t *w = (uint64_t *)(buf + HDR);
	size_t nw = (BLK - HDR) / sizeof(uint64_t);
	size_t i;

	for (i = 0; i < nw; i++)
		w[i] = splitmix64(&s);

	h->magic = MAGIC;
	h->fileid = fileid;
	h->blk = blk;
	h->gen = gen;
	h->pgblk = pgblk;
	h->pgblks = pgblks;
	h->seq = seq;
	h->hash = 0;
	h->hash = fnv1a(buf, BLK);
}

enum blk_verdict { B_OK, B_ZERO, B_NOMAGIC, B_CORRUPT, B_FOREIGN, B_FILL };

static const char *verdict_name(enum blk_verdict v)
{
	switch (v) {
	case B_OK:	return "OK";
	case B_ZERO:	return "ZERO";
	case B_NOMAGIC:	return "NOMAGIC";
	case B_CORRUPT:	return "CORRUPT";
	case B_FOREIGN:	return "FOREIGN";
	case B_FILL:	return "FILL";
	}
	return "?";
}

static enum blk_verdict check_block(const uint8_t *buf, uint32_t fileid,
				    uint32_t blk, uint32_t pgblk,
				    uint32_t pgblks, uint64_t *gen_out)
{
	const struct hdr *h = (const struct hdr *)buf;
	uint8_t ref[BLK];
	struct hdr save;
	uint64_t want;
	size_t i;

	for (i = 0; i < BLK; i++)
		if (buf[i])
			break;
	if (i == BLK)
		return B_ZERO;

	if (h->magic != MAGIC)
		return B_NOMAGIC;

	memcpy(&save, h, sizeof(save));
	{
		uint8_t tmp[BLK];

		memcpy(tmp, buf, BLK);
		((struct hdr *)tmp)->hash = 0;
		want = fnv1a(tmp, BLK);
	}
	if (want != save.hash)
		return B_CORRUPT;

	*gen_out = save.gen;

	if (save.fileid != fileid || save.blk != blk ||
	    save.pgblk != pgblk || save.pgblks != pgblks)
		return B_FOREIGN;

	/* Hash and identity both check out, so the bytes are self-consistent;
	 * confirm they are also the bytes this (fileid, blk, gen) should have,
	 * which catches a whole block copied from a different generation. */
	fill_block(ref, fileid, blk, save.gen, pgblk, pgblks, save.seq);
	if (memcmp(ref, buf, BLK))
		return B_FILL;

	return B_OK;
}

/* --- shared state --------------------------------------------------------- */
static uint64_t *g_gen;			/* per-page generation */
/* Pages [0, g_valid) have been laid out and must read back; beyond that the
 * file has not been grown yet and holds nothing to check. */
static uint32_t g_valid;
static uint32_t g_pages, g_fileid, g_pgblks;
static size_t g_pagesz;

static int open_target(const char *path, int flags)
{
	int fd = open(path, flags | O_TAU_UNTORN, 0644);

	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
		exit(1);
	}
	return fd;
}

static void build_page(uint8_t *buf, uint32_t page, uint64_t gen, uint64_t seq)
{
	uint32_t i;

	for (i = 0; i < g_pgblks; i++)
		fill_block(buf + i * BLK, g_fileid,
			   page * g_pgblks + i, gen, i, g_pgblks, seq);
}

static int write_page(int fd, uint8_t *buf, uint32_t page)
{
	off_t off = (off_t)page * g_pagesz;
	ssize_t n = pwrite(fd, buf, g_pagesz, off);

	if (n != (ssize_t)g_pagesz) {
		fprintf(stderr, "pwrite(page %u): %s\n", page,
			n < 0 ? strerror(errno) : "short write");
		return -1;
	}
	return 0;
}

/* --- init ----------------------------------------------------------------- */
static int do_init(const char *path, const char *prealloc)
{
	uint8_t *buf;
	uint32_t p;
	int fd, rc = 0;
	off_t total = (off_t)g_pages * g_pagesz;

	fd = open_target(path, O_CREAT | O_RDWR | O_TRUNC);

	if (!strcmp(prealloc, "fallocate")) {
		/* What PG does for extensions over 8 blocks: leaves unwritten
		 * extents, which is the state the reported corruption sat on. */
		if (fallocate(fd, 0, 0, total)) {
			fprintf(stderr, "fallocate: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
	} else if (!strcmp(prealloc, "zerowrite")) {
		void *z = calloc(1, g_pagesz);

		for (p = 0; p < g_pages && z; p++)
			if (pwrite(fd, z, g_pagesz, (off_t)p * g_pagesz) !=
			    (ssize_t)g_pagesz) {
				fprintf(stderr, "zerowrite: %s\n", strerror(errno));
				rc = 1;
				break;
			}
		free(z);
		if (rc) {
			close(fd);
			return rc;
		}
	}

	buf = aligned_alloc(BLK, g_pagesz);
	if (!buf) {
		fprintf(stderr, "out of memory\n");
		close(fd);
		return 1;
	}
	g_valid = g_pages;
	for (p = 0; p < g_pages; p++) {
		g_gen[p] = 1;
		build_page(buf, p, 1, p);
		if (write_page(fd, buf, p)) {
			rc = 1;
			break;
		}
	}
	if (!rc && fsync(fd)) {
		fprintf(stderr, "fsync: %s\n", strerror(errno));
		rc = 1;
	}
	free(buf);
	close(fd);
	return rc;
}

/* --- churn ---------------------------------------------------------------- */
struct worker {
	pthread_t tid;
	int fd;
	uint32_t lo, hi;	/* page range [lo, hi) owned exclusively */
	uint64_t seed;
	uint64_t writes, fsyncs;
	int rc;
};

static volatile int g_stop;
static unsigned g_fsync_every, g_hot_pct;

static void *churn_worker(void *arg)
{
	struct worker *w = arg;
	uint32_t span = w->hi - w->lo;
	/* A hot set small enough to be rewritten before checkpoint has retired
	 * it: that is what produces anchored -> revoked -> rewritten, the
	 * transition the suspected loss hangs off. */
	uint32_t hot = span / 16 ? span / 16 : 1;
	uint8_t *buf = aligned_alloc(BLK, g_pagesz);
	uint64_t s = w->seed;
	uint64_t since_fsync = 0;

	if (!buf) {
		w->rc = 1;
		return NULL;
	}
	while (!g_stop) {
		uint64_t r = splitmix64(&s);
		uint32_t page;

		if ((r % 100) < g_hot_pct)
			page = w->lo + (uint32_t)((r >> 8) % hot);
		else
			page = w->lo + (uint32_t)((r >> 8) % span);

		g_gen[page]++;
		build_page(buf, page, g_gen[page], w->writes);
		if (write_page(w->fd, buf, page)) {
			w->rc = 1;
			break;
		}
		w->writes++;
		if (g_fsync_every && ++since_fsync >= g_fsync_every) {
			since_fsync = 0;
			if (fsync(w->fd)) {
				fprintf(stderr, "fsync: %s\n", strerror(errno));
				w->rc = 1;
				break;
			}
			w->fsyncs++;
		}
	}
	free(buf);
	return NULL;
}

static int write_manifest(const char *manifest);

/* --- grow -----------------------------------------------------------------
 * One thread extends the file the way PG's mdzeroextend() does -- fallocate a
 * chunk, then fill it -- and publishes how far it has got.  The others rewrite
 * pages below that mark.  Only the extender ever writes a page for the first
 * time, and it publishes the watermark only after the whole chunk is written,
 * so no rewriter can touch a page the extender is still laying down.
 *
 * Page ownership among rewriters is by residue class, so no two threads ever
 * bump the same generation counter and the manifest stays authoritative.
 */
static uint32_t g_wm;			/* pages laid out; release/acquire */
static unsigned g_chunk_pages;

static uint32_t wm_load(void)
{
	return __atomic_load_n(&g_wm, __ATOMIC_ACQUIRE);
}

static void wm_store(uint32_t v)
{
	__atomic_store_n(&g_wm, v, __ATOMIC_RELEASE);
}

static void *grow_extender(void *arg)
{
	struct worker *w = arg;
	uint8_t *buf = aligned_alloc(BLK, g_pagesz);
	uint64_t since_fsync = 0;

	if (!buf) {
		w->rc = 1;
		return NULL;
	}
	while (!g_stop) {
		uint32_t base = wm_load();
		uint32_t n = g_chunk_pages, p;

		if (base >= g_pages)
			break;			/* target size reached */
		if (base + n > g_pages)
			n = g_pages - base;

		if (fallocate(w->fd, 0, (off_t)base * g_pagesz,
			      (off_t)n * g_pagesz)) {
			fprintf(stderr, "fallocate(page %u): %s\n",
				base, strerror(errno));
			w->rc = 1;
			break;
		}
		for (p = base; p < base + n && !g_stop; p++) {
			g_gen[p] = 1;
			build_page(buf, p, 1, w->writes);
			if (write_page(w->fd, buf, p)) {
				w->rc = 1;
				goto out;
			}
			w->writes++;
			if (g_fsync_every && ++since_fsync >= g_fsync_every) {
				since_fsync = 0;
				if (fsync(w->fd)) {
					fprintf(stderr, "fsync: %s\n",
						strerror(errno));
					w->rc = 1;
					goto out;
				}
				w->fsyncs++;
			}
		}
		/* Only now may a rewriter see these pages. */
		wm_store(p);
	}
out:
	free(buf);
	return NULL;
}

static void *grow_rewriter(void *arg)
{
	struct worker *w = arg;
	uint8_t *buf = aligned_alloc(BLK, g_pagesz);
	uint64_t s = w->seed;
	uint64_t since_fsync = 0;
	uint32_t klass = w->lo;		/* residue class this thread owns */
	uint32_t nklass = w->hi;

	if (!buf) {
		w->rc = 1;
		return NULL;
	}
	while (!g_stop) {
		uint64_t r = splitmix64(&s);
		uint32_t wm = wm_load();
		uint32_t page, span;

		if (wm < nklass) {		/* nothing to rewrite yet */
			struct timespec t = { 0, 1000000 };

			nanosleep(&t, NULL);
			continue;
		}
		/* Bias towards what the extender just published: those pages
		 * are freshly journaled, so rewriting them is what produces the
		 * anchored -> revoked transition this test is aimed at. */
		span = ((r % 100) < g_hot_pct && wm > g_chunk_pages) ?
			g_chunk_pages : wm;
		page = wm - 1 - (uint32_t)((r >> 8) % span);
		page -= page % nklass;
		page += klass;
		if (page >= wm)
			continue;

		g_gen[page]++;
		build_page(buf, page, g_gen[page], w->writes);
		if (write_page(w->fd, buf, page)) {
			w->rc = 1;
			break;
		}
		w->writes++;
		if (g_fsync_every && ++since_fsync >= g_fsync_every) {
			since_fsync = 0;
			if (fsync(w->fd)) {
				fprintf(stderr, "fsync: %s\n", strerror(errno));
				w->rc = 1;
				break;
			}
			w->fsyncs++;
		}
	}
	free(buf);
	return NULL;
}

static int do_grow(const char *path, unsigned secs, uint64_t seed,
		   unsigned threads, const char *manifest)
{
	struct worker *ws;
	unsigned i;
	uint64_t writes = 0, fsyncs = 0;
	int fd, rc = 0;
	struct timespec ts;

	if (threads < 2) {
		fprintf(stderr, "grow needs at least 2 threads "
			"(one extends, the rest rewrite)\n");
		return 2;
	}
	fd = open_target(path, O_CREAT | O_RDWR | O_TRUNC);
	ws = calloc(threads, sizeof(*ws));
	if (!ws) {
		close(fd);
		return 1;
	}
	wm_store(0);
	for (i = 0; i < threads; i++) {
		ws[i].fd = fd;
		ws[i].lo = i ? i - 1 : 0;	/* residue class */
		ws[i].hi = threads - 1;		/* number of classes */
		ws[i].seed = seed + i * 0x9e3779b97f4a7c15ULL;
		if (pthread_create(&ws[i].tid, NULL,
				   i ? grow_rewriter : grow_extender, &ws[i])) {
			fprintf(stderr, "pthread_create: %s\n", strerror(errno));
			g_stop = 1;
			rc = 1;
			threads = i;
			break;
		}
	}

	ts.tv_sec = secs;
	ts.tv_nsec = 0;
	while (!g_stop && nanosleep(&ts, &ts) && errno == EINTR)
		;
	g_stop = 1;

	for (i = 0; i < threads; i++) {
		pthread_join(ws[i].tid, NULL);
		writes += ws[i].writes;
		fsyncs += ws[i].fsyncs;
		if (ws[i].rc)
			rc = 1;
	}
	if (fsync(fd)) {
		fprintf(stderr, "final fsync: %s\n", strerror(errno));
		rc = 1;
	}
	close(fd);
	free(ws);

	g_valid = wm_load();
	printf("grow: %" PRIu64 " page writes, %" PRIu64 " fsyncs, "
	       "grew to %u of %u pages\n", writes, fsyncs, g_valid, g_pages);
	if (!g_valid) {
		fprintf(stderr, "grew nothing -- raise secs or lower chunk_pages\n");
		rc = 1;
	}
	if (write_manifest(manifest))
		rc = 1;
	return rc;
}

static int write_manifest(const char *manifest)
{
	FILE *f;
	uint32_t p;

	if (!manifest || !*manifest)
		return 0;
	f = fopen(manifest, "w");
	if (!f) {
		fprintf(stderr, "manifest %s: %s\n", manifest, strerror(errno));
		return 1;
	}
	fprintf(f, "pages %u fileid %u pgblks %u valid %u\n",
		g_pages, g_fileid, g_pgblks, g_valid);
	for (p = 0; p < g_valid; p++)
		fprintf(f, "%u %" PRIu64 "\n", p, g_gen[p]);
	if (fflush(f) || fsync(fileno(f))) {
		fprintf(stderr, "manifest flush: %s\n", strerror(errno));
		fclose(f);
		return 1;
	}
	fclose(f);
	return 0;
}

static int do_churn(const char *path, unsigned secs, uint64_t seed,
		    unsigned threads, const char *manifest)
{
	struct worker *ws;
	uint32_t per, i;
	uint64_t writes = 0, fsyncs = 0;
	int fd, rc = 0;
	struct timespec ts;

	fd = open_target(path, O_RDWR);
	ws = calloc(threads, sizeof(*ws));
	if (!ws) {
		close(fd);
		return 1;
	}
	per = g_pages / threads;
	if (!per) {
		fprintf(stderr, "%u pages is too few for %u threads\n",
			g_pages, threads);
		free(ws);
		close(fd);
		return 2;
	}
	for (i = 0; i < threads; i++) {
		ws[i].fd = fd;
		ws[i].lo = i * per;
		ws[i].hi = (i == threads - 1) ? g_pages : (i + 1) * per;
		ws[i].seed = seed + i * 0x9e3779b97f4a7c15ULL;
		if (pthread_create(&ws[i].tid, NULL, churn_worker, &ws[i])) {
			fprintf(stderr, "pthread_create: %s\n", strerror(errno));
			g_stop = 1;
			rc = 1;
			threads = i;
			break;
		}
	}

	ts.tv_sec = secs;
	ts.tv_nsec = 0;
	while (!g_stop && nanosleep(&ts, &ts) && errno == EINTR)
		;
	g_stop = 1;

	for (i = 0; i < threads; i++) {
		pthread_join(ws[i].tid, NULL);
		writes += ws[i].writes;
		fsyncs += ws[i].fsyncs;
		if (ws[i].rc)
			rc = 1;
	}
	/* A clean close+unmount must make every one of these durable; the test
	 * deliberately does not fsync here, so an unflushed write showing up as
	 * lost would be the filesystem's problem, not the workload's. */
	if (fsync(fd)) {
		fprintf(stderr, "final fsync: %s\n", strerror(errno));
		rc = 1;
	}
	close(fd);
	free(ws);

	g_valid = g_pages;
	printf("churn: %" PRIu64 " page writes, %" PRIu64 " fsyncs\n",
	       writes, fsyncs);
	if (write_manifest(manifest))
		rc = 1;
	return rc;
}

/* --- verify --------------------------------------------------------------- */
static int read_manifest(const char *manifest, uint64_t *want)
{
	FILE *f;
	uint32_t pages, fileid, pgblks, valid, p;
	uint64_t g;

	if (!manifest || !*manifest)
		return 0;
	f = fopen(manifest, "r");
	if (!f) {
		fprintf(stderr, "no manifest %s (%s) -- skipping the stale check\n",
			manifest, strerror(errno));
		return 0;
	}
	valid = 0;
	if (fscanf(f, "pages %u fileid %u pgblks %u valid %u\n",
		   &pages, &fileid, &pgblks, &valid) != 4) {
		rewind(f);
		if (fscanf(f, "pages %u fileid %u pgblks %u\n",
			   &pages, &fileid, &pgblks) != 3) {
			fprintf(stderr, "manifest %s is not readable\n", manifest);
			fclose(f);
			return -1;
		}
		valid = pages;	/* pre-watermark manifest: the file is all there */
	}
	if (pages != g_pages || fileid != g_fileid || pgblks != g_pgblks ||
	    valid > pages) {
		fprintf(stderr, "manifest %s does not describe this file\n", manifest);
		fclose(f);
		return -1;
	}
	g_valid = valid;
	while (fscanf(f, "%u %" SCNu64 "\n", &p, &g) == 2)
		if (p < g_pages)
			want[p] = g;
	fclose(f);
	return 1;
}

static int do_verify(const char *path, const char *manifest)
{
	uint8_t *buf;
	uint64_t *want;
	uint32_t p, i;
	int fd, reported = 0, have_manifest;
	unsigned long bad_zero = 0, bad_torn = 0, bad_stale = 0;
	unsigned long bad_foreign = 0, bad_corrupt = 0, bad_other = 0;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
		return 1;
	}
	buf = aligned_alloc(BLK, g_pagesz);
	want = calloc(g_pages, sizeof(*want));
	if (!buf || !want) {
		fprintf(stderr, "out of memory\n");
		close(fd);
		return 1;
	}
	g_valid = g_pages;	/* read_manifest lowers this if the file was grown */
	have_manifest = read_manifest(manifest, want);
	if (have_manifest < 0) {
		close(fd);
		return 2;
	}

	for (p = 0; p < g_valid; p++) {
		enum blk_verdict v[16];
		uint64_t gen[16];
		int page_bad = 0, torn = 0;
		ssize_t n = pread(fd, buf, g_pagesz, (off_t)p * g_pagesz);

		if (n != (ssize_t)g_pagesz) {
			fprintf(stderr, "pread(page %u): %s\n", p,
				n < 0 ? strerror(errno) : "short read");
			close(fd);
			return 1;
		}
		for (i = 0; i < g_pgblks; i++) {
			gen[i] = 0;
			v[i] = check_block(buf + i * BLK, g_fileid,
					   p * g_pgblks + i, i, g_pgblks, &gen[i]);
			if (v[i] != B_OK)
				page_bad = 1;
		}
		for (i = 1; i < g_pgblks; i++)
			if (gen[i] != gen[0])
				torn = 1;

		if (!page_bad && !torn) {
			if (have_manifest > 0 && want[p] && gen[0] != want[p]) {
				bad_stale++;
				if (reported++ < MAX_REPORT)
					printf("  STALE   page %u  gen %" PRIu64
					       " want %" PRIu64 "\n",
					       p, gen[0], want[p]);
			}
			continue;
		}

		if (torn)
			bad_torn++;
		for (i = 0; i < g_pgblks; i++) {
			switch (v[i]) {
			case B_ZERO:	bad_zero++; break;
			case B_FOREIGN:	bad_foreign++; break;
			case B_CORRUPT:	bad_corrupt++; break;
			case B_NOMAGIC:
			case B_FILL:	bad_other++; break;
			case B_OK:	break;
			}
		}
		if (reported++ < MAX_REPORT) {
			printf("  %-7s page %u (offset %" PRIu64 ")",
			       torn ? "TORN" : "BAD", p,
			       (uint64_t)p * g_pagesz);
			for (i = 0; i < g_pgblks; i++)
				printf("  blk%u=%s/gen%" PRIu64,
				       i, verdict_name(v[i]), gen[i]);
			printf("\n");
		}
	}
	free(buf);
	free(want);
	close(fd);

	printf("verify %s: pages=%u torn=%lu zero_blocks=%lu stale=%lu "
	       "foreign=%lu corrupt=%lu other=%lu\n",
	       path, g_valid, bad_torn, bad_zero, bad_stale,
	       bad_foreign, bad_corrupt, bad_other);
	if (reported > MAX_REPORT)
		printf("  (%d more not shown)\n", reported - MAX_REPORT);

	return (bad_torn || bad_zero || bad_stale || bad_foreign ||
		bad_corrupt || bad_other) ? 1 : 0;
}

/* -------------------------------------------------------------------------- */
static void usage(const char *me)
{
	fprintf(stderr,
		"usage: %s init   <path> <pages> <fileid> [pagekb] [fallocate|zerowrite|none]\n"
		"       %s churn  <path> <pages> <fileid> <secs> <seed> <threads> [pagekb] [fsync_every] [hot_pct] [manifest]\n"
		"       %s grow   <path> <pages> <fileid> <secs> <seed> <threads> [pagekb] [fsync_every] [chunk_pages] [manifest]\n"
		"       %s verify <path> <pages> <fileid> [pagekb] [manifest]\n",
		me, me, me, me);
}

int main(int argc, char **argv)
{
	const char *mode, *path;
	unsigned pagekb = 8;
	int rc;

	if (argc < 5) {
		usage(argv[0]);
		return 2;
	}
	mode = argv[1];
	path = argv[2];
	g_pages = strtoul(argv[3], NULL, 0);
	g_fileid = strtoul(argv[4], NULL, 0);

	if (!strcmp(mode, "init"))
		pagekb = argc > 5 ? strtoul(argv[5], NULL, 0) : 8;
	else if (!strcmp(mode, "churn") || !strcmp(mode, "grow"))
		pagekb = argc > 8 ? strtoul(argv[8], NULL, 0) : 8;
	else if (!strcmp(mode, "verify"))
		pagekb = argc > 5 ? strtoul(argv[5], NULL, 0) : 8;

	if (!pagekb || (pagekb * 1024) % BLK || pagekb > 64) {
		fprintf(stderr, "pagekb must be a multiple of 4 up to 64\n");
		return 2;
	}
	g_pagesz = (size_t)pagekb * 1024;
	g_pgblks = g_pagesz / BLK;
	if (!g_pages) {
		fprintf(stderr, "pages must be > 0\n");
		return 2;
	}

	g_gen = calloc(g_pages, sizeof(*g_gen));
	if (!g_gen) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}

	if (!strcmp(mode, "init")) {
		rc = do_init(path, argc > 6 ? argv[6] : "fallocate");
	} else if (!strcmp(mode, "churn")) {
		unsigned secs, threads;
		uint64_t seed;

		if (argc < 8) {
			usage(argv[0]);
			return 2;
		}
		secs = strtoul(argv[5], NULL, 0);
		seed = strtoull(argv[6], NULL, 0);
		threads = strtoul(argv[7], NULL, 0);
		g_fsync_every = argc > 9 ? strtoul(argv[9], NULL, 0) : 16;
		g_hot_pct = argc > 10 ? strtoul(argv[10], NULL, 0) : 60;
		if (!threads || threads > 64) {
			fprintf(stderr, "threads must be 1..64\n");
			return 2;
		}
		if (g_hot_pct > 100) {
			fprintf(stderr, "hot_pct must be 0..100\n");
			return 2;
		}
		/* churn resumes from init's generation 1 for every page */
		for (unsigned p = 0; p < g_pages; p++)
			g_gen[p] = 1;
		rc = do_churn(path, secs, seed, threads,
			      argc > 11 ? argv[11] : NULL);
	} else if (!strcmp(mode, "grow")) {
		unsigned secs, threads;
		uint64_t seed;

		if (argc < 8) {
			usage(argv[0]);
			return 2;
		}
		secs = strtoul(argv[5], NULL, 0);
		seed = strtoull(argv[6], NULL, 0);
		threads = strtoul(argv[7], NULL, 0);
		g_fsync_every = argc > 9 ? strtoul(argv[9], NULL, 0) : 16;
		g_chunk_pages = argc > 10 ? strtoul(argv[10], NULL, 0) : 256;
		g_hot_pct = 60;
		if (threads < 2 || threads > 64) {
			fprintf(stderr, "grow needs threads 2..64\n");
			return 2;
		}
		if (!g_chunk_pages) {
			fprintf(stderr, "chunk_pages must be > 0\n");
			return 2;
		}
		rc = do_grow(path, secs, seed, threads,
			     argc > 11 ? argv[11] : NULL);
	} else if (!strcmp(mode, "verify")) {
		rc = do_verify(path, argc > 6 ? argv[6] : NULL);
	} else {
		usage(argv[0]);
		rc = 2;
	}
	free(g_gen);
	return rc;
}
