/* SPDX-License-Identifier: GPL-2.0
 *
 * torner atoms -- follow every application atomic write through the log, and
 * plan the crash states that could break each one.  See include/atoms.h.
 */
#include "atoms.h"
#include "torner.h"
#include "log_writes.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXSPU	TORNER_MAX_SECTORS_PER_UNIT

static uint64_t full_mask(uint32_t spu)
{
	return spu >= 64 ? ~0ULL : ((1ULL << spu) - 1);
}

const char *atom_class_name(enum atom_class c)
{
	switch (c) {
	case ATOM_ONE_BIO:	return "one_bio";
	case ATOM_SPLIT_WINDOW:	return "split_window";
	case ATOM_SPLIT_FLUSH:	return "split_flush";
	case ATOM_PARTIAL:	return "partial";
	default:		return "?";
	}
}

static int hit_cmp(const void *x, const void *y)
{
	const struct ahit *a = x, *b = y;

	if (a->page != b->page)		return a->page < b->page ? -1 : 1;
	if (a->version != b->version)	return a->version < b->version ? -1 : 1;
	if (a->entry != b->entry)	return a->entry < b->entry ? -1 : 1;
	if (a->off != b->off)		return a->off < b->off ? -1 : 1;
	return 0;
}

static void add_hit(struct atoms *as, const struct ahit *h, size_t *cap)
{
	if (as->hn == *cap) {
		*cap = *cap ? *cap * 2 : 4096;
		as->h = xrealloc(as->h, *cap * sizeof(*as->h));
	}
	as->h[as->hn++] = *h;
}

/*
 * Find every copy by content, at any byte offset.  Searching only at block
 * boundaries would miss copies that a file system embeds inside its own
 * records -- a ZFS intent-log record carries the written data right after its
 * header -- and would then misreport where W first became durable.  The CRC
 * and the deterministic fill make a false match on random data impossible in
 * practice, and a torn copy (one that did not fully land) simply fails to
 * verify and is not counted.
 */
static int scan_entries(const struct rlog *l, uint64_t run_id, struct atoms *as)
{
	uint64_t mv = TORNER_SECTOR_MAGIC;
	uint8_t magic[8], *buf = NULL;
	size_t cap = 0, hcap = 0, i;

	memcpy(magic, &mv, sizeof(magic));

	for (i = 0; i < l->n; i++) {
		const struct lent *e = &l->e[i];
		uint64_t bytes = e->nr_sectors * (uint64_t)l->sectorsize, pos;

		if (!e->payload || !bytes)
			continue;
		if (e->flags & (LOG_MARK_FLAG | LOG_DISCARD_FLAG))
			continue;
		if (bytes > cap) {
			cap = bytes;
			buf = xrealloc(buf, cap);
		}
		if (pread(l->fd, buf, bytes, e->payload) != (ssize_t)bytes) {
			fprintf(stderr, "torner atoms: short payload read at entry %zu\n", i);
			free(buf);
			return -1;
		}
		as->bytes_scanned += bytes;

		pos = 0;
		while (pos + sizeof(magic) <= bytes) {
			uint8_t *p = memmem(buf + pos, bytes - pos, magic, sizeof(magic));
			struct torner_sector_hdr hdr, h;
			struct ahit hit;
			uint64_t o;

			if (!p)
				break;
			o = (uint64_t)(p - buf);
			as->candidates++;
			if (o + sizeof(hdr) > bytes) {
				as->rejected++;
				break;
			}
			memcpy(&hdr, p, sizeof(hdr));
			if (hdr.sector_size < sizeof(hdr) ||
			    hdr.sector_size > TORNER_DEF_SECTOR ||
			    o + hdr.sector_size > bytes ||
			    torner_verify_sector(p, hdr.sector_size, hdr.page_id,
						 hdr.sector_idx, run_id, &h) != TORNER_SEC_OK) {
				as->rejected++;
				pos = o + 1;
				continue;
			}
			memset(&hit, 0, sizeof(hit));
			hit.page = h.page_id;
			hit.version = h.version;
			hit.entry = i;
			hit.off = o;
			hit.sidx = h.sector_idx;
			hit.spu = h.sectors_per_unit;
			hit.ssz = h.sector_size;
			add_hit(as, &hit, &hcap);
			if (o % h.sector_size)
				as->embedded_copies++;
			pos = o + h.sector_size;
		}
	}
	free(buf);
	return 0;
}

uint32_t atom_groups(const struct atoms *as, const struct atom *a,
		     uint64_t *g, uint64_t *gmask, uint32_t max)
{
	uint64_t first[MAXSPU];
	uint32_t k = 0, s;
	size_t x;

	for (s = 0; s < MAXSPU; s++)
		first[s] = UINT64_MAX;
	/* hits are sorted by entry within the atom, so the first one wins */
	for (x = a->h_lo; x < a->h_hi; x++) {
		s = as->h[x].sidx;
		if (s < MAXSPU && first[s] == UINT64_MAX)
			first[s] = as->h[x].entry;
	}
	for (s = 0; s < MAXSPU; s++) {
		uint32_t j, pos;

		if (first[s] == UINT64_MAX)
			continue;
		for (j = 0; j < k; j++)
			if (g[j] == first[s])
				break;
		if (j < k) {
			gmask[j] |= 1ULL << s;
			continue;
		}
		if (k == max)
			continue;
		/* insertion, keeping g ascending */
		for (pos = k; pos > 0 && g[pos - 1] > first[s]; pos--) {
			g[pos] = g[pos - 1];
			gmask[pos] = gmask[pos - 1];
		}
		g[pos] = first[s];
		gmask[pos] = 1ULL << s;
		k++;
	}
	return k;
}

static void build_atoms(const struct rlog *l, struct atoms *as)
{
	size_t i = 0, cap = 0, n;

	while (i < as->hn) {
		struct atom a;
		uint64_t g[MAXSPU], gm[MAXSPU], first[MAXSPU];
		uint64_t prev_entry = UINT64_MAX;
		uint32_t s, gi, gj;
		size_t j = i, x;

		while (j < as->hn && as->h[j].page == as->h[i].page &&
		       as->h[j].version == as->h[i].version)
			j++;

		memset(&a, 0, sizeof(a));
		a.page = as->h[i].page;
		a.version = as->h[i].version;
		a.spu = as->h[i].spu;
		a.ssz = as->h[i].ssz;
		a.h_lo = i;
		a.h_hi = j;
		a.next_ver = UINT64_MAX;
		a.workload = a.version >= 1;

		for (s = 0; s < MAXSPU; s++)
			first[s] = UINT64_MAX;
		for (x = i; x < j; x++) {
			const struct ahit *h = &as->h[x];

			if (h->sidx < MAXSPU) {
				a.seen |= 1ULL << h->sidx;
				if (first[h->sidx] == UINT64_MAX) {
					first[h->sidx] = h->entry;
					if (h->off % h->ssz)
						a.embedded = 1;
				}
			}
			if (h->entry != prev_entry) {
				a.nentries++;
				prev_entry = h->entry;
			}
		}
		a.last_copy = as->h[j - 1].entry;

		a.k = atom_groups(as, &a, g, gm, MAXSPU);
		a.g_first = a.k ? g[0] : 0;
		a.g_last = a.k ? g[a.k - 1] : 0;

		if ((a.seen & full_mask(a.spu)) != full_mask(a.spu))
			a.cls = ATOM_PARTIAL;
		else if (a.k <= 1)
			a.cls = ATOM_ONE_BIO;
		else if (l->lastflush[a.g_last] > (int64_t)a.g_first)
			a.cls = ATOM_SPLIT_FLUSH;
		else
			a.cls = ATOM_SPLIT_WINDOW;

		for (gj = 1; gj < a.k && !a.reorderable; gj++)
			for (gi = 0; gi < gj; gi++)
				if (rlog_volatile_at(l, g[gi], g[gj])) {
					a.reorderable = 1;
					break;
				}

		if (as->an == cap) {
			cap = cap ? cap * 2 : 1024;
			as->a = xrealloc(as->a, cap * sizeof(*as->a));
		}
		as->a[as->an++] = a;
		i = j;
	}

	/* where the next version of the same page first lands: past that
	 * point a crash is about the next write, not this one */
	for (n = 0; n + 1 < as->an; n++)
		if (as->a[n + 1].page == as->a[n].page &&
		    as->a[n + 1].version == as->a[n].version + 1)
			as->a[n].next_ver = as->a[n + 1].g_first;
}

int atoms_scan(const struct rlog *l, uint64_t run_id, struct atoms *as)
{
	memset(as, 0, sizeof(*as));
	torner_crc32_init();
	if (scan_entries(l, run_id, as))
		return -1;
	if (as->hn)
		qsort(as->h, as->hn, sizeof(*as->h), hit_cmp);
	build_atoms(l, as);
	return 0;
}

void atoms_free(struct atoms *as)
{
	free(as->h);
	free(as->a);
	memset(as, 0, sizeof(*as));
}

/*
 * A write's shape, as one string: its class, how many pieces it first reached
 * the device in, how many log entries carry it in all, how many FLUSHes lie
 * between its first and last piece, and whether it is embedded or
 * reorderable.  Counts are capped so the space stays small.  The set of these
 * a workload produces is the fuzzer's coverage signal -- nothing in it is
 * specific to a file system.
 */
#define SIGLEN 64

static void atom_sig(const struct rlog *l, const struct atom *a, char *out)
{
	uint64_t fg = a->k ? l->e[a->g_last].fepoch - l->e[a->g_first].fepoch : 0;

	snprintf(out, SIGLEN, "%s/k%u/n%u/f%u%s%s", atom_class_name(a->cls),
		 a->k < 8 ? a->k : 8, a->nentries < 8 ? a->nentries : 8,
		 (unsigned)(fg < 3 ? fg : 3), a->embedded ? "/emb" : "",
		 a->reorderable ? "/R" : "");
}

static int sig_cmp(const void *x, const void *y)
{
	return strcmp(x, y);
}

/* ------------------------------------------------------------- planning */

static int str_cmp(const void *x, const void *y)
{
	return strcmp(*(const char *const *)x, *(const char *const *)y);
}

/* --signatures: plan only for writes of these shapes (the fuzzer passes the
 * ones a new input just produced) */
static int sig_selected(const struct rlog *l, const struct plan_opts *o,
			const struct atom *a)
{
	char sig[SIGLEN];
	const char *key = sig;

	if (!o->nsigs)
		return 1;
	atom_sig(l, a, sig);
	return bsearch(&key, o->sigs, o->nsigs, sizeof(*o->sigs), str_cmp) != NULL;
}

/*
 * A candidate is one (state, write) pair: the state `spec`, crashing after
 * entry `crash`, is aimed at write `atom`.  Identical states aimed at several
 * writes are merged when they are emitted.
 */
struct cand {
	uint64_t crash;
	uint32_t atom;
	char	*spec;
};

struct candv {
	struct cand *v;
	size_t n, cap;
};

static void cand_add(struct candv *cv, uint64_t crash, uint32_t atom,
		     const char *spec)
{
	struct cand *c;

	if (cv->n == cv->cap) {
		cv->cap = cv->cap ? cv->cap * 2 : 1024;
		cv->v = xrealloc(cv->v, cv->cap * sizeof(*cv->v));
	}
	c = &cv->v[cv->n++];
	c->crash = crash;
	c->atom = atom;
	c->spec = xrealloc(NULL, strlen(spec) + 1);
	strcpy(c->spec, spec);
}

static void cand_free(struct candv *cv)
{
	size_t i;

	for (i = 0; i < cv->n; i++)
		free(cv->v[i].spec);
	free(cv->v);
	memset(cv, 0, sizeof(*cv));
}

static int cand_cmp(const void *x, const void *y)
{
	const struct cand *a = x, *b = y;
	int r;

	if (a->crash != b->crash)
		return a->crash < b->crash ? -1 : 1;
	r = strcmp(a->spec, b->spec);
	if (r)
		return r;
	if (a->atom != b->atom)
		return a->atom < b->atom ? -1 : 1;
	return 0;
}

/* barrier entries: every FLUSH, and every FUA write (commit records) */
static size_t barrier_list(const struct rlog *l, uint64_t **out)
{
	uint64_t *b = NULL;
	size_t n = 0, cap = 0, i;

	for (i = 0; i < l->n; i++) {
		if (!(l->e[i].flags & (LOG_FLUSH_FLAG | LOG_FUA_FLAG)))
			continue;
		if (n == cap) {
			cap = cap ? cap * 2 : 1024;
			b = xrealloc(b, cap * sizeof(*b));
		}
		b[n++] = i;
	}
	*out = b;
	return n;
}

static size_t lower_bound(const uint64_t *v, size_t n, uint64_t x)
{
	size_t lo = 0, hi = n;

	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;

		if (v[mid] < x)
			lo = mid + 1;
		else
			hi = mid;
	}
	return lo;
}

/*
 * Distinct log entries carrying any copy of @a, ascending -- the hits are
 * sorted by entry within a write.  @e must have room for a->nentries.
 */
static uint32_t atom_entries(const struct atoms *as, const struct atom *a,
			     uint64_t *e)
{
	uint32_t n = 0;
	size_t x;

	for (x = a->h_lo; x < a->h_hi; x++)
		if (!n || e[n - 1] != as->h[x].entry)
			e[n++] = as->h[x].entry;
	return n;
}

/*
 * atom-order: crash points between the log entries that carry W.
 *
 * Between every two of them, the crash right before the later one -- the most
 * that can be durable without it.  That covers the pieces of W's first write,
 * where a file system without atomic writes tears, and every later copy: a
 * journal copy and its checkpoint, a log record and the in-place write it is
 * replayed into, where recovery has to put things right.  Then every barrier
 * from W's first copy to the one after its last: recovery decides what is
 * visible at commit points, and a W can be fully on the device yet still come
 * back torn if recovery replays one of its transactions and not the other.
 *
 * A write carried by a single entry has no such crash point; only atom-tear
 * reaches it.
 */
static void plan_order(const struct rlog *l, const struct atoms *as,
		       const struct plan_opts *o, struct candv *cv, uint64_t *elig)
{
	uint64_t *bl = NULL, *e = NULL;
	size_t nb = barrier_list(l, &bl), ai, ecap = 0;
	char spec[96];

	for (ai = 0; ai < as->an; ai++) {
		const struct atom *a = &as->a[ai];
		uint64_t L;
		size_t lo, hi, step, bi;
		uint32_t n, x;

		if (!a->workload || (a->nentries < 2 && a->cls != ATOM_PARTIAL) ||
		    !sig_selected(l, o, a))
			continue;
		(*elig)++;
		if (a->nentries > ecap) {
			ecap = a->nentries;
			e = xrealloc(e, ecap * sizeof(*e));
		}
		n = atom_entries(as, a, e);

		for (x = 1; x < n; x++) {
			snprintf(spec, sizeof(spec), "entry<=%" PRIu64, e[x] - 1);
			cand_add(cv, e[x] - 1, (uint32_t)ai, spec);
		}
		if (a->cls == ATOM_PARTIAL) {
			snprintf(spec, sizeof(spec), "entry<=%" PRIu64, a->g_last);
			cand_add(cv, a->g_last, (uint32_t)ai, spec);
		}

		L = a->last_copy;
		bi = lower_bound(bl, nb, a->last_copy + 1);
		if (bi < nb)
			L = bl[bi];
		if (a->next_ver != UINT64_MAX && a->next_ver > 0 && L >= a->next_ver)
			L = a->next_ver - 1;

		lo = lower_bound(bl, nb, a->g_first);
		hi = lower_bound(bl, nb, L + 1);
		if (hi <= lo)
			continue;
		step = 1;
		if (o->per_atom_barriers && hi - lo > o->per_atom_barriers)
			step = (hi - lo + o->per_atom_barriers - 1) / o->per_atom_barriers;
		for (bi = lo; bi < hi; bi += step) {
			snprintf(spec, sizeof(spec), "entry<=%" PRIu64, bl[bi]);
			cand_add(cv, bl[bi], (uint32_t)ai, spec);
		}
		/* always keep the last barrier of the region */
		if ((hi - 1 - lo) % step) {
			snprintf(spec, sizeof(spec), "entry<=%" PRIu64, bl[hi - 1]);
			cand_add(cv, bl[hi - 1], (uint32_t)ai, spec);
		}
	}
	free(e);
	free(bl);
}

/*
 * atom-reorder: a later entry carrying W is on the device and an earlier one
 * is not.  Only entries the volatile cache could still lose are dropped --
 * plain writes after the last FLUSH -- so every state is one a real cache can
 * produce.  As with atom-order, every copy of W counts, not only its first.
 */
static void plan_reorder(const struct rlog *l, const struct atoms *as,
			 const struct plan_opts *o, struct candv *cv,
			 uint64_t *elig)
{
	uint64_t *e = NULL, *d = NULL;
	char *spec = NULL;
	size_t ai, ecap = 0, scap = 0;

	for (ai = 0; ai < as->an; ai++) {
		const struct atom *a = &as->a[ai];
		uint32_t n, i, j;
		int any = 0;

		if (!a->workload || a->nentries < 2 || !sig_selected(l, o, a))
			continue;
		if (a->nentries > ecap) {
			ecap = a->nentries;
			e = xrealloc(e, ecap * sizeof(*e));
			d = xrealloc(d, ecap * sizeof(*d));
			scap = 64 + ecap * 24;	/* a drop list can name them all */
			spec = xrealloc(spec, scap);
		}
		n = atom_entries(as, a, e);

		for (j = 1; j < n; j++) {
			uint32_t nd = 0, x;
			size_t pos;

			for (i = 0; i < j; i++)
				if (rlog_volatile_at(l, e[i], e[j]))
					d[nd++] = e[i];
			for (x = 0; x < nd; x++) {
				snprintf(spec, scap, "entry<=%" PRIu64 ",drop=[%" PRIu64 "]",
					 e[j], d[x]);
				cand_add(cv, e[j], (uint32_t)ai, spec);
			}
			any |= nd > 0;
			if (nd < 2)
				continue;
			pos = (size_t)snprintf(spec, scap, "entry<=%" PRIu64 ",drop=[", e[j]);
			for (x = 0; x < nd; x++)
				pos += (size_t)snprintf(spec + pos, scap - pos, "%s%" PRIu64,
							x ? "," : "", d[x]);
			snprintf(spec + pos, scap - pos, "]");
			cand_add(cv, e[j], (uint32_t)ai, spec);
		}
		*elig += any;
	}
	free(spec);
	free(d);
	free(e);
}

/*
 * atom-tear: the write in flight at the crash lands only up to an atomic-unit
 * boundary of the device.  Cuts are placed at device atom boundaries strictly
 * inside W's span within that write, so each state leaves W partly new.  With
 * all copies (the default) this also tears a journal checkpoint or a
 * relocation of W, which is where a journal's recovery has to put things right.
 */
static uint64_t tear_cuts(const struct rlog *l, const struct atoms *as,
			  const struct atom *a, const struct plan_opts *o,
			  struct candv *cv, uint32_t ai)
{
	uint64_t n = 0, fe[MAXSPU];
	size_t x, y;
	uint32_t s;
	char spec[96];

	/* first-appearance entry of each sector, to honour first_copy_only */
	for (s = 0; s < MAXSPU; s++)
		fe[s] = UINT64_MAX;
	for (x = a->h_lo; x < a->h_hi; x++)
		if (as->h[x].sidx < MAXSPU && fe[as->h[x].sidx] == UINT64_MAX)
			fe[as->h[x].sidx] = as->h[x].entry;

	for (x = a->h_lo; x < a->h_hi; x = y) {
		uint64_t j = as->h[x].entry, S, bytes, o1, oend, L, r;
		uint32_t m = 0;
		int is_first = 0;

		for (y = x; y < a->h_hi && as->h[y].entry == j; y++) {
			m++;
			if (as->h[y].sidx < MAXSPU && fe[as->h[y].sidx] == j)
				is_first = 1;
		}
		if (m < 2)
			continue;
		if (o->first_copy_only && !is_first)
			continue;

		S = l->e[j].sector * (uint64_t)l->sectorsize;
		bytes = l->e[j].nr_sectors * (uint64_t)l->sectorsize;
		o1 = as->h[x].off;
		oend = as->h[y - 1].off + as->h[y - 1].ssz;

		r = (S + o1) % o->atom_bytes;
		L = o1 + (o->atom_bytes - r);
		for (; L < oend && L < bytes; L += o->atom_bytes) {
			if (L % l->sectorsize)
				continue;
			n++;
			snprintf(spec, sizeof(spec), "entry<=%" PRIu64 ",partial=[%"
				 PRIu64 ":%" PRIu64 "]", j, j, L / l->sectorsize);
			cand_add(cv, j, ai, spec);
		}
	}
	return n;
}

static void plan_tear(const struct rlog *l, const struct atoms *as,
		      const struct plan_opts *o, struct candv *cv, uint64_t *elig)
{
	size_t ai;

	for (ai = 0; ai < as->an; ai++)
		if (as->a[ai].workload && sig_selected(l, o, &as->a[ai]) &&
		    tear_cuts(l, as, &as->a[ai], o, cv, (uint32_t)ai))
			(*elig)++;
}

static int u64_cmp(const void *x, const void *y)
{
	uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;

	return a < b ? -1 : a > b;
}

/* --prefer-split order: the shapes most likely to tear first */
static int shape_rank(enum atom_class c)
{
	switch (c) {
	case ATOM_SPLIT_FLUSH:	return 0;
	case ATOM_PARTIAL:	return 1;
	case ATOM_SPLIT_WINDOW:	return 2;
	default:		return 3;
	}
}

/*
 * Which writes a budget covers.  Writes are sampled whole, in a seeded random
 * order, until the states they need reach the budget: every state aimed at a
 * chosen write is examined, and a write that is not chosen is not tried at
 * all.  The result then reads "writes torn / writes tried".  Thinning states
 * instead would try one write at the cut between its pieces and another only
 * at a barrier after it, and would weight writes by how many states they
 * happen to need.
 */
static void select_writes(const struct atoms *as, const struct candv *cv,
			  const size_t *gid, size_t ngroups,
			  const struct plan_opts *o, uint8_t *sel_atom,
			  uint8_t *sel_group)
{
	uint64_t *key, rnd = o->seed ? o->seed : 1, taken = 0;
	size_t *start, *perm, nw = 0, i, j;

	if (!o->max_states || ngroups <= o->max_states) {
		for (i = 0; i < cv->n; i++) {
			sel_atom[cv->v[i].atom] = 1;
			sel_group[gid[i]] = 1;
		}
		return;
	}

	/* (write, state) pairs, grouped by write */
	key = xrealloc(NULL, cv->n * sizeof(*key));
	for (i = 0; i < cv->n; i++)
		key[i] = ((uint64_t)cv->v[i].atom << 32) | (uint32_t)gid[i];
	qsort(key, cv->n, sizeof(*key), u64_cmp);

	start = xrealloc(NULL, (cv->n + 1) * sizeof(*start));
	for (i = 0; i < cv->n; i++)
		if (!i || key[i] >> 32 != key[i - 1] >> 32)
			start[nw++] = i;
	start[nw] = cv->n;

	perm = xrealloc(NULL, (nw ? nw : 1) * sizeof(*perm));
	for (i = 0; i < nw; i++)
		perm[i] = i;
	for (i = nw; i > 1; i--) {
		size_t r = splitmix(&rnd) % i, t = perm[i - 1];

		perm[i - 1] = perm[r];
		perm[r] = t;
	}
	if (o->prefer_split) {
		/* stable partition by shape, keeping the shuffle within each */
		size_t *tmp = xrealloc(NULL, (nw ? nw : 1) * sizeof(*tmp)), n = 0;
		int rank;

		for (rank = 0; rank <= 3; rank++)
			for (i = 0; i < nw; i++)
				if (shape_rank(as->a[key[start[perm[i]]] >> 32].cls) == rank)
					tmp[n++] = perm[i];
		free(perm);
		perm = tmp;
	}
	for (i = 0; i < nw && taken < o->max_states; i++) {
		size_t w = perm[i];

		sel_atom[key[start[w]] >> 32] = 1;
		for (j = start[w]; j < start[w + 1]; j++) {
			size_t g = (size_t)(key[j] & 0xffffffffu);

			if (!sel_group[g]) {
				sel_group[g] = 1;
				taken++;
			}
		}
	}
	free(perm);
	free(start);
	free(key);
}

int atoms_plan(const struct rlog *l, const struct atoms *as, const char *strategy,
	       const struct plan_opts *o, plan_emit_fn emit, void *ctx,
	       struct plan_stats *st)
{
	struct candv cv = {0};
	const char *model;
	const struct atom **tg;
	uint8_t *sel_atom, *sel_group, *hit;
	size_t i, j, ngroups = 0, *gstart, *gid, gi, na = as->an ? as->an : 1;

	memset(st, 0, sizeof(*st));
	if (!strcmp(strategy, "atom-order")) {
		model = "O";
		plan_order(l, as, o, &cv, &st->atoms_eligible);
	} else if (!strcmp(strategy, "atom-reorder")) {
		model = "R";
		plan_reorder(l, as, o, &cv, &st->atoms_eligible);
	} else if (!strcmp(strategy, "atom-tear")) {
		model = "T";
		plan_tear(l, as, o, &cv, &st->atoms_eligible);
	} else {
		return -1;
	}

	if (cv.n)
		qsort(cv.v, cv.n, sizeof(*cv.v), cand_cmp);

	/* group identical states: same crash point and same spec */
	gstart = xrealloc(NULL, (cv.n + 1) * sizeof(*gstart));
	gid = xrealloc(NULL, (cv.n ? cv.n : 1) * sizeof(*gid));
	for (i = 0; i < cv.n; i++) {
		if (!i || cv.v[i].crash != cv.v[i - 1].crash ||
		    strcmp(cv.v[i].spec, cv.v[i - 1].spec))
			gstart[ngroups++] = i;
		gid[i] = ngroups - 1;
	}
	gstart[ngroups] = cv.n;
	st->candidates = ngroups;

	sel_atom = memset(xrealloc(NULL, na), 0, na);
	hit = memset(xrealloc(NULL, na), 0, na);
	sel_group = memset(xrealloc(NULL, ngroups + 1), 0, ngroups + 1);
	tg = xrealloc(NULL, na * sizeof(*tg));
	select_writes(as, &cv, gid, ngroups, o, sel_atom, sel_group);

	for (gi = 0; gi < ngroups; gi++) {
		struct plan_state ps;
		size_t nt = 0;

		if (!sel_group[gi])
			continue;
		for (j = gstart[gi]; j < gstart[gi + 1]; j++) {
			uint32_t a = cv.v[j].atom;

			/* a state shared with a write the budget left out
			 * speaks only for the chosen ones: the other one is
			 * not being tried whole */
			if (!sel_atom[a])
				continue;
			if (j > gstart[gi] && a == cv.v[j - 1].atom)
				continue;
			tg[nt++] = &as->a[a];
			if (!hit[a]) {
				hit[a] = 1;
				st->atoms_targeted++;
			}
		}
		memset(&ps, 0, sizeof(ps));
		ps.strategy = strategy;
		ps.model = model;
		ps.crash_entry = cv.v[gstart[gi]].crash;
		ps.spec = cv.v[gstart[gi]].spec;
		ps.targets = tg;
		ps.ntargets = nt;
		emit(ctx, &ps);
		st->emitted++;
	}

	free(tg);
	free(hit);
	free(sel_group);
	free(sel_atom);
	free(gid);
	free(gstart);
	cand_free(&cv);
	return 0;
}

/* ------------------------------------------------------------ subcommand */

static void usage(void)
{
	fprintf(stderr,
"usage: torner atoms --log <logdev> [options]\n"
"\n"
"Follow every application atomic write through a dm-log-writes log and say\n"
"how it reached the device -- in one bio, or in pieces -- without knowing\n"
"anything about the file system.\n"
"\n"
"  --log <path>        dm-log-writes log\n"
"  --run-id <u64>      only count sectors from this run           [0 = any]\n"
"  --examples <n>      split writes to describe in detail         [8]\n"
"  --atom <bytes>      device atomic unit, for the atom-tear plan  [4096]\n"
"  --config, --workload  labels copied into the report, for torner-report\n"
"\n"
"exit: 0 on success (a report, not a verdict), 1 on error\n");
}

static void count_only(void *ctx, const struct plan_state *st)
{
	(void)ctx;
	(void)st;
}

static void print_groups(const struct rlog *l, const struct atoms *as,
			 const struct atom *a)
{
	uint64_t g[MAXSPU], gm[MAXSPU];
	uint32_t k = atom_groups(as, a, g, gm, MAXSPU), i;

	printf("[");
	for (i = 0; i < k; i++)
		printf("%s{\"entry\":%" PRIu64 ",\"fepoch\":%" PRIu64
		       ",\"sectors\":\"0x%" PRIx64 "\"%s}",
		       i ? "," : "", g[i], l->e[g[i]].fepoch, gm[i],
		       (l->e[g[i]].flags & LOG_FUA_FLAG) ? ",\"fua\":true" : "");
	printf("]");
}

int torner_atoms(int argc, char **argv)
{
	static const char *const strategies[] = {
		"atom-order", "atom-reorder", "atom-tear"
	};
	const char *logpath = NULL, *config = "", *workload = "";
	uint64_t run_id = 0, examples = 8, atom = 4096;
	uint64_t cls[ATOM__NCLASS] = {0}, khist[9] = {0}, chist[5] = {0};
	uint64_t setup = 0, work = 0, embedded = 0, reorder = 0, single = 0;
	uint64_t shown = 0;
	struct plan_opts po;
	struct plan_stats ps;
	struct rlog l;
	struct atoms as;
	size_t i;
	int rc = 1;

	for (i = 1; i < (size_t)argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < (size_t)argc) ? argv[i + 1] : NULL;

#define NEEDV() do { if (!v) { usage(); return 1; } i++; } while (0)
		if (!strcmp(a, "--log"))		{ NEEDV(); logpath = v; }
		else if (!strcmp(a, "--run-id"))	{ NEEDV(); run_id = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--examples"))	{ NEEDV(); examples = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--atom"))		{ NEEDV(); atom = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--config"))	{ NEEDV(); config = v; }
		else if (!strcmp(a, "--workload"))	{ NEEDV(); workload = v; }
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
		else {
			fprintf(stderr, "torner atoms: unknown option '%s'\n", a);
			usage();
			return 1;
		}
#undef NEEDV
	}
	if (!logpath) {
		usage();
		return 1;
	}

	memset(&as, 0, sizeof(as));
	if (rlog_open(&l, logpath, "torner atoms"))
		goto out_log;
	if (atom == 0 || atom % l.sectorsize) {
		fprintf(stderr, "torner atoms: --atom must be a multiple of the log"
			" sector size (%u)\n", l.sectorsize);
		goto out;
	}
	if (atoms_scan(&l, run_id, &as))
		goto out;

	for (i = 0; i < as.an; i++) {
		const struct atom *a = &as.a[i];

		if (!a->workload) {
			setup++;
			continue;
		}
		work++;
		cls[a->cls]++;
		khist[a->k < 8 ? a->k : 8]++;
		chist[a->nentries < 4 ? a->nentries : 4]++;
		embedded += a->embedded;
		reorder += a->reorderable;
		single += a->nentries == 1;
	}

	printf("{\"tool\":\"torner-atoms\",\"config\":\"%s\",\"workload\":\"%s\"",
	       config, workload);
	printf(",\"log\":{\"entries\":%zu,\"fepochs\":%" PRIu64 ",\"epochs\":%" PRIu64
	       ",\"sectorsize\":%u,\"begin_mark\":%" PRId64 "}",
	       l.n, l.fepochs, l.epochs, l.sectorsize, l.begin_entry);
	printf(",\"scan\":{\"bytes\":%" PRIu64 ",\"sector_copies\":%zu"
	       ",\"embedded_copies\":%" PRIu64 ",\"candidates\":%" PRIu64
	       ",\"rejected\":%" PRIu64 "}",
	       as.bytes_scanned, as.hn, as.embedded_copies, as.candidates,
	       as.rejected);
	printf(",\"writes\":{\"total\":%zu,\"setup\":%" PRIu64 ",\"workload\":%" PRIu64 "}",
	       as.an, setup, work);
	printf(",\"shape\":{\"one_bio\":%" PRIu64 ",\"split_window\":%" PRIu64
	       ",\"split_flush\":%" PRIu64 ",\"partial\":%" PRIu64
	       ",\"reorderable\":%" PRIu64 ",\"embedded_first_copy\":%" PRIu64
	       ",\"single_entry\":%" PRIu64,
	       cls[ATOM_ONE_BIO], cls[ATOM_SPLIT_WINDOW], cls[ATOM_SPLIT_FLUSH],
	       cls[ATOM_PARTIAL], reorder, embedded, single);
	printf(",\"pieces\":{\"1\":%" PRIu64 ",\"2\":%" PRIu64 ",\"3\":%" PRIu64
	       ",\"4\":%" PRIu64 ",\"5+\":%" PRIu64 "}",
	       khist[1], khist[2], khist[3], khist[4],
	       khist[5] + khist[6] + khist[7] + khist[8]);
	printf(",\"entries_touched\":{\"1\":%" PRIu64 ",\"2\":%" PRIu64 ",\"3\":%" PRIu64
	       ",\"4+\":%" PRIu64 "}}",
	       chist[1], chist[2], chist[3], chist[4]);

	{
		char (*sig)[SIGLEN] = xrealloc(NULL, (work ? work : 1) * SIGLEN);
		size_t ns = 0, x, run;

		for (i = 0; i < as.an; i++)
			if (as.a[i].workload)
				atom_sig(&l, &as.a[i], sig[ns++]);
		qsort(sig, ns, SIGLEN, sig_cmp);
		printf(",\"signatures\":{");
		for (x = 0; x < ns; x += run) {
			for (run = 1; x + run < ns && !strcmp(sig[x], sig[x + run]); run++)
				;
			printf("%s\"%s\":%zu", x ? "," : "", sig[x], run);
		}
		printf("}");
		free(sig);
	}

	/*
	 * What each atom-* strategy would examine: the writes it has states for,
	 * and how many distinct states that takes with no budget.  These come
	 * from the planners themselves, so they are exactly what `replay
	 * --enumerate` produces -- structural facts about this trace, not
	 * verdicts.  Whether recovery leaves a write torn is for explore.
	 */
	memset(&po, 0, sizeof(po));
	po.atom_bytes = atom;
	po.per_atom_barriers = 32;
	printf(",\"plans\":{");
	for (i = 0; i < sizeof(strategies) / sizeof(strategies[0]); i++) {
		atoms_plan(&l, &as, strategies[i], &po, count_only, NULL, &ps);
		printf("%s\"%s\":{\"writes\":%" PRIu64 ",\"states\":%" PRIu64 "}",
		       i ? "," : "", strategies[i], ps.atoms_eligible, ps.candidates);
	}
	printf("}");

	printf(",\"examples\":[");
	for (i = 0; i < as.an && shown < examples; i++) {
		const struct atom *a = &as.a[i];

		if (!a->workload || a->cls == ATOM_ONE_BIO)
			continue;
		printf("%s{\"page\":%" PRIu64 ",\"version\":%" PRIu64
		       ",\"class\":\"%s\",\"entries_touched\":%u,\"pieces\":",
		       shown ? "," : "", a->page, a->version,
		       atom_class_name(a->cls), a->nentries);
		print_groups(&l, &as, a);
		printf("}");
		shown++;
	}
	printf("]}\n");
	rc = 0;
out:
	atoms_free(&as);
out_log:
	rlog_close(&l);
	return rc;
}
