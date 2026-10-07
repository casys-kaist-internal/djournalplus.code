/* SPDX-License-Identifier: GPL-2.0
 *
 * torner replay -- T2b, crash-state construction from a dm-log-writes log.
 *
 * xfstests' replay-log only does prefixes.  Exploring the crash-state space
 * needs arbitrary subsets of an epoch, so this reimplements replay around a
 * declarative state spec.
 *
 * The spec is both the identifier of a state and the recipe for rebuilding it:
 * the same spec against the same log must produce a byte-identical target
 * (CRASH_TODO §4.7).  That is what lets a violation in the JSONL be handed to a
 * reviewer as something they can reconstruct, rather than a number.
 *
 * The target is written in place and is NOT truncated or zeroed first: the
 * harness gives us a copy of the base image (the device as it was before the
 * workload began), and replay lays log entries on top of it.
 */
#include "torner.h"
#include "log_writes.h"
#include "logidx.h"
#include "atoms.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/falloc.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct spec {
	int	 has_epoch_max;
	uint64_t epoch_max;
	int	 has_entry_max;
	uint64_t entry_max;
	uint64_t *drop;
	size_t	 drop_n;
	int	 has_reverse;
	uint64_t reverse_epoch;
	/*
	 * Sub-entry persistence: entry @partial_idx lands only in part, its
	 * first @partial_sectors sectors.  See the torn-entry strategy.
	 */
	int	 has_partial;
	uint64_t partial_idx;
	uint64_t partial_sectors;
};

/* ------------------------------------------------------------------- spec */

static int parse_u64_list(const char *s, uint64_t **out, size_t *n)
{
	const char *p = s;

	*out = NULL;
	*n = 0;
	if (*p != '[')
		return -1;
	p++;
	while (*p && *p != ']') {
		char *end;
		uint64_t v = strtoull(p, &end, 0);

		if (end == p)
			return -1;
		*out = xrealloc(*out, (*n + 1) * sizeof(uint64_t));
		(*out)[(*n)++] = v;
		p = end;
		if (*p == ',')
			p++;
	}
	return (*p == ']') ? 0 : -1;
}

/*
 * Grammar (comma separated, brackets may contain commas):
 *   epoch<=N      keep entries in epochs 1..N
 *   entry<=N      keep entries with index <= N
 *   drop=[i,j,..] exclude these entry indices
 *   reverse=N     apply epoch N's entries in reverse index order
 *   partial=[i:k] entry i lands only in part: its first k sectors
 */
static int spec_parse(struct spec *sp, const char *s)
{
	const char *p = s;

	memset(sp, 0, sizeof(*sp));
	while (*p) {
		while (*p == ',' || *p == ' ')
			p++;
		if (!*p)
			break;
		if (!strncmp(p, "epoch<=", 7)) {
			char *end;

			p += 7;
			sp->epoch_max = strtoull(p, &end, 0);
			if (end == p)
				return -1;
			sp->has_epoch_max = 1;
			p = end;
		} else if (!strncmp(p, "entry<=", 7)) {
			char *end;

			p += 7;
			sp->entry_max = strtoull(p, &end, 0);
			if (end == p)
				return -1;
			sp->has_entry_max = 1;
			p = end;
		} else if (!strncmp(p, "drop=", 5)) {
			const char *close;

			p += 5;
			close = strchr(p, ']');
			if (!close)
				return -1;
			if (parse_u64_list(p, &sp->drop, &sp->drop_n))
				return -1;
			p = close + 1;
		} else if (!strncmp(p, "partial=", 8)) {
			char *end;

			p += 8;
			if (*p != '[')
				return -1;
			p++;
			sp->partial_idx = strtoull(p, &end, 0);
			if (end == p || *end != ':')
				return -1;
			p = end + 1;
			sp->partial_sectors = strtoull(p, &end, 0);
			if (end == p || *end != ']')
				return -1;
			sp->has_partial = 1;
			p = end + 1;
		} else if (!strncmp(p, "reverse=", 8)) {
			char *end;

			p += 8;
			sp->reverse_epoch = strtoull(p, &end, 0);
			if (end == p)
				return -1;
			sp->has_reverse = 1;
			p = end;
		} else {
			fprintf(stderr, "torner replay: bad spec clause at '%s'\n", p);
			return -1;
		}
	}
	return 0;
}

static int spec_dropped(const struct spec *sp, uint64_t idx)
{
	size_t i;

	for (i = 0; i < sp->drop_n; i++)
		if (sp->drop[i] == idx)
			return 1;
	return 0;
}

static int spec_included(const struct spec *sp, const struct lent *e, uint64_t idx)
{
	if (sp->has_epoch_max && e->epoch > sp->epoch_max)
		return 0;
	if (sp->has_entry_max && idx > sp->entry_max)
		return 0;
	if (spec_dropped(sp, idx))
		return 0;
	return 1;
}

/* Last log entry a state can contain.  The progress-log bound is taken here:
 * an entry<=N state must not inherit the watermark of the whole log. */
static uint64_t spec_last_entry(const struct spec *sp, const struct rlog *l)
{
	uint64_t last = l->n ? l->n - 1 : 0;

	if (sp->has_epoch_max) {
		uint64_t e = rlog_last_entry_of_epoch(l, sp->epoch_max);

		if (e < last)
			last = e;
	}
	if (sp->has_entry_max && sp->entry_max < last)
		last = sp->entry_max;
	return last;
}

/*
 * State id: a stable digest of the spec and the log it applies to.  Two runs
 * of the same spec against the same log must produce the same id, and a
 * different log must not collide silently.
 */
static void state_id(char *out, size_t outsz, const char *spec,
		     const struct rlog *l)
{
	uint32_t a = torner_crc32(spec, strlen(spec));
	char tmp[64];
	uint32_t b;

	snprintf(tmp, sizeof(tmp), "%" PRIu64 ":%u", l->nr_entries, l->sectorsize);
	b = torner_crc32(tmp, strlen(tmp));
	snprintf(out, outsz, "%08x%08x", b, a);
}

/* ------------------------------------------------------------------ apply */

static int write_all(int fd, const void *buf, size_t len, off_t off)
{
	const uint8_t *p = buf;

	while (len) {
		ssize_t n = pwrite(fd, p, len, off);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			return -1;
		p += n;
		off += n;
		len -= n;
	}
	return 0;
}

/*
 * Emulate a discard.
 *
 * Punching a hole first is not an optimisation, it is what keeps the whole
 * harness viable: mkfs discards the entire device, so writing literal zeros
 * over that range makes every state image fully allocated -- 2 GiB each, eight
 * in flight, and the scratch disk is gone.  The symptom is not a disk-full
 * error either; it is every replay stalling in uninterruptible I/O.
 *
 * Falls back to writing zeros when the target cannot punch (a block device,
 * or a filesystem without FALLOC_FL_PUNCH_HOLE).
 */
static int zero_range(int fd, off_t off, uint64_t len, uint8_t *scratch,
		      size_t scratch_sz)
{
	if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
		      off, (off_t)len) == 0)
		return 0;

	memset(scratch, 0, scratch_sz);
	while (len) {
		size_t chunk = len > scratch_sz ? scratch_sz : (size_t)len;

		if (write_all(fd, scratch, chunk, off))
			return -1;
		off += chunk;
		len -= chunk;
	}
	return 0;
}

static int apply_one(struct rlog *l, int tfd, const struct lent *e,
		     uint8_t **buf, size_t *bufsz, uint64_t *applied,
		     uint64_t limit_sectors)
{
	uint64_t nsec = e->nr_sectors;
	uint64_t bytes;
	off_t target_off = (off_t)(e->sector * (uint64_t)l->sectorsize);

	/* sub-entry persistence: only the leading part of this write landed */
	if (limit_sectors && limit_sectors < nsec)
		nsec = limit_sectors;
	bytes = nsec * (uint64_t)l->sectorsize;

	if (!bytes)
		return 0;			/* pure barrier */

	if (e->flags & LOG_DISCARD_FLAG) {
		/* dm-log-writes logs no data for discards; emulate by zeroing,
		 * which is what xfstests' replay-log falls back to. */
		if (*bufsz < 1 << 20) {
			*bufsz = 1 << 20;
			*buf = xrealloc(*buf, *bufsz);
		}
		if (zero_range(tfd, target_off, bytes, *buf, *bufsz))
			return -1;
		(*applied)++;
		return 0;
	}

	if (!e->payload)
		return 0;
	if (bytes > *bufsz) {
		*bufsz = bytes;
		*buf = xrealloc(*buf, *bufsz);
	}
	if (pread(l->fd, *buf, bytes, e->payload) != (ssize_t)bytes) {
		fprintf(stderr, "torner replay: short payload read\n");
		return -1;
	}
	if (write_all(tfd, *buf, bytes, target_off)) {
		fprintf(stderr, "torner replay: write target: %s\n", strerror(errno));
		return -1;
	}
	(*applied)++;
	return 0;
}

static int do_apply(struct rlog *l, const char *target, const struct spec *sp,
		    const char *specstr, uint64_t *applied_out)
{
	uint8_t *buf = NULL;
	size_t bufsz = 0;
	uint64_t applied = 0;
	size_t i;
	int tfd, rc = -1;

	tfd = open(target, O_WRONLY);
	if (tfd < 0) {
		fprintf(stderr, "torner replay: open %s: %s\n", target, strerror(errno));
		return -1;
	}

	for (i = 0; i < l->n; ) {
		/*
		 * Reverse only reorders within the named epoch; entries outside
		 * it keep log order, so the rest of the state is unchanged and
		 * the two states differ by exactly the thing under test.
		 */
		if (sp->has_reverse && l->e[i].epoch == sp->reverse_epoch) {
			size_t start = i, end = i;
			size_t k;

			while (end < l->n && l->e[end].epoch == sp->reverse_epoch)
				end++;
			for (k = end; k-- > start; ) {
				if (!spec_included(sp, &l->e[k], k))
					continue;
				if (apply_one(l, tfd, &l->e[k], &buf, &bufsz, &applied,
					      (sp->has_partial && sp->partial_idx == k)
					      ? sp->partial_sectors : 0))
					goto out;
			}
			i = end;
			continue;
		}
		if (spec_included(sp, &l->e[i], i)) {
			if (apply_one(l, tfd, &l->e[i], &buf, &bufsz, &applied,
				      (sp->has_partial && sp->partial_idx == i)
				      ? sp->partial_sectors : 0))
				goto out;
		}
		i++;
	}

	if (fsync(tfd)) {
		fprintf(stderr, "torner replay: fsync target: %s\n", strerror(errno));
		goto out;
	}
	rc = 0;
	*applied_out = applied;
out:
	free(buf);
	close(tfd);
	(void)specstr;
	return rc;
}

/* -------------------------------------------------------------- enumerate */

static void emit_state(const char *strategy, uint64_t epoch, const char *spec,
		       const struct rlog *l)
{
	char sid[32];

	state_id(sid, sizeof(sid), spec, l);
	printf("{\"strategy\":\"%s\",\"epoch\":%" PRIu64
	       ",\"state_id\":\"%s\",\"state_spec\":\"%s\""
	       ",\"progress_limit\":%" PRIu64 "}\n",
	       strategy, epoch, sid, spec,
	       rlog_progress_limit(l, rlog_last_entry_of_epoch(l, epoch)));
}

/* atom-* states carry the application writes they are aimed at, so the
 * harness can ask the oracle about exactly those and attribute a tear. */
static void emit_plan_state(void *ctx, const struct plan_state *ps)
{
	const struct rlog *l = ctx;
	char sid[32];
	size_t i;

	state_id(sid, sizeof(sid), ps->spec, l);
	printf("{\"strategy\":\"%s\",\"model\":\"%s\",\"epoch\":%" PRIu64
	       ",\"fepoch\":%" PRIu64 ",\"crash_entry\":%" PRIu64
	       ",\"state_id\":\"%s\",\"state_spec\":\"%s\""
	       ",\"progress_limit\":%" PRIu64 ",\"targets\":[",
	       ps->strategy, ps->model, l->e[ps->crash_entry].epoch,
	       l->e[ps->crash_entry].fepoch, ps->crash_entry, sid, ps->spec,
	       rlog_progress_limit(l, ps->crash_entry));
	for (i = 0; i < ps->ntargets; i++)
		printf("%s[%" PRIu64 ",%" PRIu64 "]", i ? "," : "",
		       ps->targets[i]->page, ps->targets[i]->version);
	/* each target's shape, so a result can be read per shape */
	printf("],\"shapes\":[");
	for (i = 0; i < ps->ntargets; i++)
		printf("%s\"%s\"", i ? "," : "",
		       atom_class_name(ps->targets[i]->cls));
	printf("]}\n");
}

static void enumerate(struct rlog *l, const char *strategy, uint64_t samples,
		      uint64_t seed, uint64_t atom_sectors, uint64_t *count)
{
	char spec[512];
	uint64_t ep;

	for (ep = 1; ep <= l->epochs; ep++) {
		size_t i, first = 0, last = 0;
		int found = 0;

		for (i = 0; i < l->n; i++) {
			if (l->e[i].epoch != ep)
				continue;
			if (!found) {
				first = i;
				found = 1;
			}
			last = i;
		}

		if (!strcmp(strategy, "prefix")) {
			snprintf(spec, sizeof(spec), "epoch<=%" PRIu64, ep);
			emit_state("prefix", ep, spec, l);
			(*count)++;
		} else if (!strcmp(strategy, "single-drop")) {
			if (!found)
				continue;
			for (i = first; i <= last; i++) {
				if (l->e[i].epoch != ep)
					continue;
				/* Dropping a barrier or a mark changes no byte on
				 * disk, so it would enumerate a duplicate of the
				 * plain prefix state. */
				if (!l->e[i].nr_sectors)
					continue;
				snprintf(spec, sizeof(spec),
					 "epoch<=%" PRIu64 ",drop=[%zu]", ep, i);
				emit_state("single-drop", ep, spec, l);
				(*count)++;
			}
		} else if (!strcmp(strategy, "reverse")) {
			if (!found)
				continue;
			snprintf(spec, sizeof(spec),
				 "epoch<=%" PRIu64 ",reverse=%" PRIu64, ep, ep);
			emit_state("reverse", ep, spec, l);
			(*count)++;
		} else if (!strcmp(strategy, "torn-entry")) {
			/*
			 * Sub-entry tearing.  A write larger than the device's
			 * atomic unit is not persisted all-or-nothing: an SSD
			 * commits 4 KiB logical blocks, so a 16 KiB bio spans
			 * four of them and a power cut can land any prefix.
			 *
			 * This is a STRONGER model than entry-subset replay,
			 * and it has to be, because at bio granularity a file
			 * system that issues an application's 16 KiB write as
			 * one bio can never be shown to tear -- the whole
			 * write is dropped or kept together.  Tearing lives
			 * below that granularity, which is exactly the gap
			 * tauJournal closes.
			 */
			if (!found)
				continue;
			for (i = first; i <= last; i++) {
				uint64_t cut;

				if (l->e[i].epoch != ep)
					continue;
				if (l->e[i].nr_sectors <= atom_sectors)
					continue;	/* already atomic */
				if (l->e[i].flags & LOG_DISCARD_FLAG)
					continue;
				for (cut = atom_sectors; cut < l->e[i].nr_sectors;
				     cut += atom_sectors) {
					snprintf(spec, sizeof(spec),
						 "epoch<=%" PRIu64 ",partial=[%zu:%"
						 PRIu64 "]", ep, i, cut);
					emit_state("torn-entry", ep, spec, l);
					(*count)++;
				}
			}
		} else if (!strcmp(strategy, "random-subset")) {
			uint64_t s;

			if (!found)
				continue;
			for (s = 0; s < samples; s++) {
				/* Seeded by (seed, epoch, sample) so the same
				 * invocation always enumerates the same states. */
				uint64_t rnd = seed ^ (ep * 0x9E3779B97F4A7C15ULL)
					     ^ (s * 0xC2B2AE3D27D4EB4FULL);
				int pos = 0, any = 0;

				pos = snprintf(spec, sizeof(spec),
					       "epoch<=%" PRIu64 ",drop=[", ep);
				for (i = first; i <= last; i++) {
					if (l->e[i].epoch != ep)
						continue;
					if (!l->e[i].nr_sectors)
						continue;	/* no-op to drop */
					if (splitmix(&rnd) & 1)
						continue;
					if (pos > (int)sizeof(spec) - 32)
						break;
					pos += snprintf(spec + pos, sizeof(spec) - pos,
							"%s%zu", any ? "," : "", i);
					any = 1;
				}
				snprintf(spec + pos, sizeof(spec) - pos, "]");
				emit_state("random-subset", ep, spec, l);
				(*count)++;
			}
		}
	}
}

static int sig_str_cmp(const void *x, const void *y)
{
	return strcmp(*(char *const *)x, *(char *const *)y);
}

static void usage(void)
{
	fprintf(stderr,
"usage: torner replay --log <logdev> [--enumerate | --apply]\n"
"\n"
"  --log <path>          dm-log-writes log device or image\n"
"\n"
" enumerate states:\n"
"  --enumerate           list state specs on stdout, one JSON object per line\n"
"  --strategy <s>        prefix | single-drop | reverse | random-subset |\n"
"                        torn-entry (sub-entry tearing; see --atom)\n"
"                        atom-order | atom-reorder | atom-tear: states aimed\n"
"                        at individual application writes (see torner atoms)\n"
"  --atom <bytes>        device atomic unit for torn-entry/atom-tear [4096]\n"
"  --max-states <n>      atom-*: budget.  Whole writes are sampled until\n"
"                        their states reach it (the last one may overrun\n"
"                        it); a write is tried at all its states or none\n"
"                                                               [0 = all]\n"
"  --per-atom-barriers <n>  atom-order: barrier cuts per write        [32]\n"
"  --first-copy-only     atom-tear: tear only where a write first lands\n"
"  --signatures <file>   atom-*: only writes whose shape signature (as in\n"
"                        torner atoms \"signatures\") is listed, one per line\n"
"  --prefer-split        atom-*: with --max-states, take split writes first\n"
"                        (across a FLUSH, partial, in one window, one bio),\n"
"                        at random within each -- for finding a witness;\n"
"                        read rates per shape, not overall\n"
"  --run-id <u64>        atom-*: only follow sectors from this run [0 = any]\n"
"  --samples <n>         states per epoch for random-subset            [4]\n"
"  --seed <u64>          makes random-subset enumeration reproducible  [1]\n"
"\n"
" build one state:\n"
"  --target <path>       device/image to replay onto -- a COPY of the base\n"
"                        image; it is written in place, never truncated\n"
"  --state-spec <spec>   epoch<=N, entry<=N, drop=[i,j], reverse=N,\n"
"                        partial=[entry:sectors]\n"
"\n"
"  --stat-only           report the log index and exit\n"
"\n"
"The same --state-spec against the same log always produces a byte-identical\n"
"target (CRASH_TODO 4.7).\n");
}

int torner_replay(int argc, char **argv)
{
	const char *logpath = NULL, *target = NULL, *specstr = NULL;
	const char *strategy = "prefix";
	uint64_t samples = 4, seed = 1, count = 0, applied = 0;
	uint64_t atom = 4096;		/* device atomic unit, bytes */
	uint64_t max_states = 0, per_atom_barriers = 32, run_id = 0;
	int first_copy_only = 0, prefer_split = 0;
	const char *sigpath = NULL;
	char **sigs = NULL;
	size_t nsigs = 0;
	struct rlog l;
	struct spec sp;
	int i, rc = 1, do_enum = 0, stat_only = 0, is_atom;

	memset(&l, 0, sizeof(l));
	memset(&sp, 0, sizeof(sp));
	l.fd = -1;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

#define NEEDV() do { if (!v) { usage(); return 1; } i++; } while (0)
		if (!strcmp(a, "--log"))             { NEEDV(); logpath = v; }
		else if (!strcmp(a, "--target"))     { NEEDV(); target = v; }
		else if (!strcmp(a, "--state-spec")) { NEEDV(); specstr = v; }
		else if (!strcmp(a, "--strategy"))   { NEEDV(); strategy = v; }
		else if (!strcmp(a, "--samples"))    { NEEDV(); samples = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--seed"))       { NEEDV(); seed = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--atom"))       { NEEDV(); atom = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--max-states")) { NEEDV(); max_states = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--per-atom-barriers")) { NEEDV(); per_atom_barriers = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--run-id"))     { NEEDV(); run_id = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--first-copy-only")) { first_copy_only = 1; }
		else if (!strcmp(a, "--prefer-split")) { prefer_split = 1; }
		else if (!strcmp(a, "--signatures")) { NEEDV(); sigpath = v; }
		else if (!strcmp(a, "--enumerate"))  { do_enum = 1; }
		else if (!strcmp(a, "--apply"))      { /* default when --target given */ }
		else if (!strcmp(a, "--stat-only"))  { stat_only = 1; }
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
		else {
			fprintf(stderr, "torner replay: unknown option '%s'\n", a);
			usage();
			return 1;
		}
#undef NEEDV
	}

	if (!logpath) {
		fprintf(stderr, "torner replay: --log is required\n");
		usage();
		return 1;
	}
	if (!strcmp(strategy, "targeted")) {
		/*
		 * Needs commit blocks and their data blocks identified in the
		 * log, which is loginv's job.  Refuse rather than quietly
		 * enumerating something weaker under the same name.
		 */
		fprintf(stderr, "torner replay: strategy 'targeted' is not implemented"
			" (needs journal block identification from loginv)\n");
		return 1;
	}
	is_atom = !strncmp(strategy, "atom-", 5);
	if (do_enum && strcmp(strategy, "prefix") && strcmp(strategy, "single-drop") &&
	    strcmp(strategy, "reverse") && strcmp(strategy, "random-subset") &&
	    strcmp(strategy, "torn-entry") && strcmp(strategy, "atom-order") &&
	    strcmp(strategy, "atom-reorder") && strcmp(strategy, "atom-tear")) {
		fprintf(stderr, "torner replay: unknown strategy '%s'\n", strategy);
		return 1;
	}

	torner_crc32_init();

	if (rlog_open(&l, logpath, "torner replay"))
		goto out;

	if (stat_only) {
		size_t k, nprog = 0;

		for (k = 0; k < l.mark_n; k++)
			nprog += l.m[k].kind == LMARK_PROG;
		printf("{\"tool\":\"torner-replay\",\"entries\":%zu,\"epochs\":%" PRIu64
		       ",\"fepochs\":%" PRIu64 ",\"sectorsize\":%u"
		       ",\"declared_entries\":%" PRIu64 ",\"marks\":%zu"
		       ",\"begin_entry\":%" PRId64 "}\n",
		       l.n, l.epochs, l.fepochs, l.sectorsize, l.nr_entries, nprog,
		       l.begin_entry);
		rc = 0;
		goto out;
	}

	if (do_enum && is_atom) {
		struct atoms as;
		struct plan_opts po;
		struct plan_stats ps;

		if (atom == 0 || atom % l.sectorsize) {
			fprintf(stderr, "torner replay: --atom must be a multiple of the"
				" log sector size (%u)\n", l.sectorsize);
			goto out;
		}
		if (sigpath) {
			FILE *f = fopen(sigpath, "r");
			char line[256];

			if (!f) {
				fprintf(stderr, "torner replay: open %s: %s\n",
					sigpath, strerror(errno));
				goto out;
			}
			while (fgets(line, sizeof(line), f)) {
				line[strcspn(line, "\r\n")] = 0;
				if (!*line)
					continue;
				sigs = xrealloc(sigs, (nsigs + 1) * sizeof(*sigs));
				sigs[nsigs] = xrealloc(NULL, strlen(line) + 1);
				strcpy(sigs[nsigs++], line);
			}
			fclose(f);
			qsort(sigs, nsigs, sizeof(*sigs), sig_str_cmp);
			if (!nsigs) {
				/* an empty list selects nothing, not everything */
				fprintf(stderr, "torner replay: 0 states (%s: no"
					" signatures listed in %s)\n", strategy, sigpath);
				rc = 0;
				goto out;
			}
		}
		if (atoms_scan(&l, run_id, &as))
			goto out;
		memset(&po, 0, sizeof(po));
		po.max_states = max_states;
		po.seed = seed;
		po.atom_bytes = atom;
		po.per_atom_barriers = (uint32_t)per_atom_barriers;
		po.first_copy_only = first_copy_only;
		po.prefer_split = prefer_split;
		po.sigs = (const char *const *)sigs;
		po.nsigs = nsigs;
		atoms_plan(&l, &as, strategy, &po, emit_plan_state, &l, &ps);
		/*
		 * Coverage goes to stderr with the counts that make a clean run
		 * interpretable: how many application writes the strategy could
		 * reach, how many the emitted states actually aim at.
		 */
		fprintf(stderr, "torner replay: %" PRIu64 " states (%s: %" PRIu64
			" candidates; %" PRIu64 " of %" PRIu64 " eligible writes"
			" targeted)\n", ps.emitted, strategy, ps.candidates,
			ps.atoms_targeted, ps.atoms_eligible);
		atoms_free(&as);
		rc = 0;
		goto out;
	}

	if (do_enum) {
		enumerate(&l, strategy, samples, seed,
			  atom / l.sectorsize ? atom / l.sectorsize : 1, &count);
		fprintf(stderr, "torner replay: %" PRIu64 " states (%s, %" PRIu64
			" epochs)\n", count, strategy, l.epochs);
		rc = 0;
		goto out;
	}

	if (!target || !specstr) {
		fprintf(stderr, "torner replay: --target and --state-spec are required"
			" (or use --enumerate)\n");
		usage();
		goto out;
	}
	if (spec_parse(&sp, specstr)) {
		fprintf(stderr, "torner replay: cannot parse state spec '%s'\n", specstr);
		goto out;
	}
	if (do_apply(&l, target, &sp, specstr, &applied))
		goto out;

	{
		char sid[32];

		state_id(sid, sizeof(sid), specstr, &l);
		printf("{\"tool\":\"torner-replay\",\"state_id\":\"%s\""
		       ",\"state_spec\":\"%s\",\"entries_applied\":%" PRIu64
		       ",\"entries_total\":%zu,\"epochs\":%" PRIu64
		       ",\"progress_limit\":%" PRIu64 "}\n",
		       sid, specstr, applied, l.n, l.epochs,
		       rlog_progress_limit(&l, spec_last_entry(&sp, &l)));
	}
	free(sp.drop);
	rc = 0;

out:
	while (nsigs)
		free(sigs[--nsigs]);
	free(sigs);
	rlog_close(&l);
	return rc;
}
