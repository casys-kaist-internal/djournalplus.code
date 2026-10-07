/* SPDX-License-Identifier: GPL-2.0
 *
 * dm-log-writes log index.  See include/logidx.h for how the log is ordered
 * and what that means for which crash states are legal.
 */
#include "logidx.h"
#include "log_writes.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void *xrealloc(void *p, size_t n)
{
	void *q = realloc(p, n);

	if (!q) {
		fprintf(stderr, "torner: out of memory\n");
		exit(1);
	}
	return q;
}

static void add_mark(struct rlog *l, uint64_t entry, const char *txt, size_t len)
{
	struct lmark mk;
	const char *tag;

	memset(&mk, 0, sizeof(mk));
	mk.entry = entry;
	mk.kind = LMARK_OTHER;

	if ((tag = memmem(txt, len, "torner:prog=", 12))) {
		mk.kind = LMARK_PROG;
		mk.slot = strtoull(tag + 12, NULL, 10);
	} else if (memmem(txt, len, "torner:begin", 12)) {
		mk.kind = LMARK_BEGIN;
		if (l->begin_entry < 0)
			l->begin_entry = (int64_t)entry;
	} else if (memmem(txt, len, "torner:end", 10)) {
		mk.kind = LMARK_END;
		l->end_entry = (int64_t)entry;
	}

	l->m = xrealloc(l->m, (l->mark_n + 1) * sizeof(*l->m));
	l->m[l->mark_n++] = mk;
}

int rlog_open(struct rlog *l, const char *path, const char *who)
{
	struct log_write_super_d sup;
	uint8_t *hdr = NULL;
	off_t pos;
	size_t i;
	int64_t lf;

	memset(l, 0, sizeof(*l));
	l->fd = -1;
	l->begin_entry = -1;
	l->end_entry = -1;

	l->fd = open(path, O_RDONLY);
	if (l->fd < 0) {
		fprintf(stderr, "%s: open %s: %s\n", who, path, strerror(errno));
		return -1;
	}
	if (read(l->fd, &sup, sizeof(sup)) != (ssize_t)sizeof(sup)) {
		fprintf(stderr, "%s: short read on log superblock\n", who);
		return -1;
	}
	if (sup.magic != WRITE_LOG_MAGIC) {
		fprintf(stderr, "%s: bad log magic 0x%" PRIx64 "\n", who, sup.magic);
		return -1;
	}
	if (sup.version != WRITE_LOG_VERSION) {
		fprintf(stderr, "%s: log version %" PRIu64 ", this build understands %"
			PRIu64 "\n", who, sup.version, (uint64_t)WRITE_LOG_VERSION);
		return -1;
	}
	l->sectorsize = sup.sectorsize;
	l->nr_entries = sup.nr_entries;
	if (!l->sectorsize || l->sectorsize % 512) {
		fprintf(stderr, "%s: bad sectorsize %u\n", who, l->sectorsize);
		return -1;
	}

	hdr = malloc(l->sectorsize);
	if (!hdr)
		return -1;
	pos = lseek(l->fd, l->sectorsize, SEEK_SET);
	if (pos < 0) {
		free(hdr);
		return -1;
	}

	l->epochs = 1;
	l->fepochs = 1;
	while (l->n < l->nr_entries) {
		struct log_write_entry_d ent;
		struct lent le;
		uint64_t bytes;
		ssize_t n;

		n = read(l->fd, hdr, l->sectorsize);
		if (n <= 0)
			break;
		if (n != (ssize_t)l->sectorsize) {
			fprintf(stderr, "%s: truncated entry header at %zu\n", who, l->n);
			break;
		}
		pos += l->sectorsize;
		memcpy(&ent, hdr, sizeof(ent));

		memset(&le, 0, sizeof(le));
		le.sector = ent.sector;
		le.nr_sectors = ent.nr_sectors;
		le.flags = ent.flags;
		le.epoch = l->epochs;
		le.fepoch = l->fepochs;

		/* A MARK keeps its string in its own entry sector, after the
		 * 32-byte header, with nr_sectors 0 (log_mark() and the
		 * metadatalen path of log_one_block()). */
		if (ent.flags & LOG_MARK_FLAG) {
			size_t off = sizeof(ent);
			size_t want = ent.data_len;

			if (want > l->sectorsize - off)
				want = l->sectorsize - off;
			add_mark(l, l->n, (const char *)hdr + off, want);
		}

		bytes = ent.nr_sectors * (uint64_t)l->sectorsize;
		/* DISCARD entries carry no payload (dm-log-writes only writes the
		 * data out when !LOG_DISCARD_FLAG). */
		if (bytes && !(ent.flags & LOG_DISCARD_FLAG)) {
			le.payload = pos;
			pos = lseek(l->fd, bytes, SEEK_CUR);
			if (pos < 0) {
				fprintf(stderr, "%s: seek: %s\n", who, strerror(errno));
				break;
			}
		}

		l->e = xrealloc(l->e, (l->n + 1) * sizeof(*l->e));
		l->e[l->n++] = le;

		if (ent.flags & (LOG_FLUSH_FLAG | LOG_FUA_FLAG))
			l->epochs++;
		if (ent.flags & LOG_FLUSH_FLAG)
			l->fepochs++;
	}
	free(hdr);

	/* A trailing barrier opens an epoch no entry lands in; count only the
	 * epochs that hold entries so a prefix enumeration has no duplicate. */
	if (l->n) {
		l->epochs = l->e[l->n - 1].epoch;
		l->fepochs = l->e[l->n - 1].fepoch;
	}

	l->lastflush = xrealloc(NULL, (l->n ? l->n : 1) * sizeof(int64_t));
	lf = -1;
	for (i = 0; i < l->n; i++) {
		if (l->e[i].flags & LOG_FLUSH_FLAG)
			lf = (int64_t)i;
		l->lastflush[i] = lf;
	}
	return 0;
}

void rlog_close(struct rlog *l)
{
	free(l->e);
	free(l->m);
	free(l->lastflush);
	if (l->fd >= 0)
		close(l->fd);
	l->e = NULL;
	l->m = NULL;
	l->lastflush = NULL;
	l->fd = -1;
}

uint64_t rlog_progress_limit(const struct rlog *l, uint64_t last)
{
	uint64_t best = 0;
	size_t i;

	for (i = 0; i < l->mark_n; i++)
		if (l->m[i].kind == LMARK_PROG && l->m[i].entry <= last &&
		    l->m[i].slot > best)
			best = l->m[i].slot;
	return best;
}

uint64_t rlog_last_entry_of_epoch(const struct rlog *l, uint64_t epoch)
{
	uint64_t last = 0;
	size_t i;

	for (i = 0; i < l->n; i++) {
		if (l->e[i].epoch > epoch)
			break;
		last = i;
	}
	return last;
}

int rlog_volatile_at(const struct rlog *l, uint64_t i, uint64_t c)
{
	const struct lent *e;

	if (i > c || c >= l->n)
		return 0;
	e = &l->e[i];
	if (!e->nr_sectors)
		return 0;			/* barriers and marks move no data */
	if (e->flags & (LOG_FUA_FLAG | LOG_FLUSH_FLAG))
		return 0;			/* durable once logged */
	return l->lastflush[c] < (int64_t)i;	/* not yet covered by a FLUSH */
}
