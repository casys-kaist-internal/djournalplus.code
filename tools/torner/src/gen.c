/* SPDX-License-Identifier: GPL-2.0
 *
 * torner gen -- the synthetic workload.
 *
 * Writes application atomic units (default 16 KiB) as a single pwrite() each,
 * fsync()s per policy, and appends {page_id, version} to a progress log on a
 * separate device *after* fsync returns.
 *
 * Page ownership is partitioned across threads (page_id % threads == tid) so
 * that the version of a page is only ever advanced by one thread.  Without
 * that, two writers racing on one page would make "the sectors disagree"
 * ambiguous between a tear and a legal interleaving -- and the P1 oracle would
 * be unusable.  APPEND is the exception; see below.
 *
 * Interference.  Whether an application write reaches the device in one piece
 * depends as much on what ELSE is happening as on the write itself: a commit
 * the write did not ask for -- another file's fsync(), a sync(), writeback
 * catching a unit halfway through its copy -- is what divides it.  The
 * --sync-ms, --other-fsync-ms and --writeback-ms knobs run that activity on
 * the side, with plain POSIX calls, so the same knobs mean the same thing on
 * every file system.  They are the input surface the fuzzer explores.
 */
#include "torner.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef O_DIRECT
#define O_DIRECT	040000
#endif

/*
 * Per-file opt-in to tauJournal.  Defined by the tau kernel in
 * include/uapi/asm-generic/fcntl.h; userspace headers do not carry it, so
 * repeat the value here rather than failing to build off-tree.
 *
 * Without this (or the tjournal_all mount option) a `-o tjournal` mount still
 * journals nothing: tau engages per file, and the run ends with
 * "[tau_commit_all] But no transaction to commit" in dmesg.
 */
#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN	040000000
#endif

struct gen_cfg {
	const char *path;
	const char *proglog;
	uint32_t unit;
	uint32_t sector;
	uint32_t threads;
	enum torner_mode mode;
	uint32_t duration;		/* seconds; 0 = until pages exhausted */
	uint64_t pages;
	uint64_t fsync_every;		/* 0 = never */
	uint64_t run_id;
	uint64_t seed;
	const char *mark_dev;		/* dm device to mark, or NULL */
	uint64_t mark_every;		/* writes between marks (0 = off) */
	int untorn;			/* open the target with O_TAU_UNTORN */
	int direct;			/* open the target with O_DIRECT */
	int use_fdatasync;		/* fdatasync() instead of fsync() */
	uint32_t sync_ms;		/* interferer: sync() every n ms */
	uint32_t other_fsync_ms;	/* interferer: write + fsync a sibling */
	uint32_t writeback_ms;		/* interferer: start writeback of target */
	int prog_direct;
	int quiet;
};

struct gen_shared {
	struct gen_cfg cfg;
	int fd;
	int progfd;
	uint32_t spu;			/* sectors per unit */
	atomic_ullong seq;		/* global write sequence */
	atomic_ullong prog_slot;	/* progress log record slot */
	atomic_ullong next_page;	/* APPEND mode: monotonic page claim */
	atomic_ullong writes;
	atomic_ullong fsyncs;
	atomic_ullong marks;
	atomic_ullong next_mark;	/* seq at which to emit the next mark */
	atomic_int stop;
	struct timespec t0;
};

/*
 * Stamp the current progress-log position into the dm-log-writes stream.
 *
 * Without this the progress log cannot be lined up with a crash state: replay
 * cuts the workload at some epoch, but the progress log lives on a separate
 * device and still holds records from the whole run, so every write after the
 * cut looks like a lost durable write.  A mark says "at this point in the log,
 * the progress log had reached slot N", which bounds the set of records a
 * replayed state is answerable for.
 *
 * Slots are claimed only after fsync() returned, so the value is a safe bound:
 * every slot below it corresponds to data that really was durable here.
 *
 * CRASH_TODO 4.2 warns against marking per fsync -- the fork/exec would sink
 * the workload.  --mark-every keeps it to one per K writes.
 */
static int dm_mark(const char *dev, const char *text)
{
	char cmd[512];

	snprintf(cmd, sizeof(cmd), "dmsetup message %s 0 mark %s >/dev/null 2>&1",
		 dev, text);
	return system(cmd);
}

static void emit_mark(struct gen_shared *sh)
{
	char text[64];
	unsigned long long slot = atomic_load(&sh->prog_slot);

	snprintf(text, sizeof(text), "torner:prog=%llu", slot);
	if (dm_mark(sh->cfg.mark_dev, text) == 0)
		atomic_fetch_add(&sh->marks, 1);
}

struct gen_thread {
	struct gen_shared *sh;
	uint32_t tid;
	uint64_t *ver;			/* version per owned page, index-local */
	uint64_t nowned;
	pthread_t th;
	uint64_t writes;
	uint64_t fsyncs;
	int err;
};

static double elapsed_s(const struct timespec *t0)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (now.tv_sec - t0->tv_sec) + (now.tv_nsec - t0->tv_nsec) / 1e9;
}

/* Full-write helper: pwrite() can come up short. */
static int pwrite_all(int fd, const void *buf, size_t len, off_t off)
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
 * Append one progress record.  Slots are handed out atomically so concurrent
 * writers never collide, and each record is one device sector so it lands
 * whole.
 */
static int prog_append(struct gen_shared *sh, uint64_t page_id, uint64_t version,
		       uint64_t seq, uint32_t tid, void *recbuf)
{
	struct torner_prog_rec *r = recbuf;
	uint64_t slot;

	if (sh->progfd < 0)
		return 0;

	torner_build_prog(r, page_id, version, seq, sh->cfg.run_id, tid);
	slot = atomic_fetch_add(&sh->prog_slot, 1);
	return pwrite_all(sh->progfd, r, TORNER_PROG_RECSZ,
			  (off_t)slot * TORNER_PROG_RECSZ);
}

/*
 * Stateless permutation over [0, n): stride co-prime with n scatters the
 * access pattern without materialising a shuffle array.  Used by the
 * write-once modes so block allocation is not handed a purely sequential
 * stream.
 */
static uint64_t coprime_stride(uint64_t n, uint64_t seed)
{
	uint64_t s;

	if (n < 3)
		return 1;
	s = (seed % (n - 1)) | 1;
	while (s > 1) {
		uint64_t a = n, b = s, t;

		while (b) {
			t = a % b;
			a = b;
			b = t;
		}
		if (a == 1)
			return s;
		s -= 2;
	}
	return 1;
}

static inline uint64_t splitmix(uint64_t *s)
{
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);

	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

static void *gen_worker(void *arg)
{
	struct gen_thread *t = arg;
	struct gen_shared *sh = t->sh;
	const struct gen_cfg *c = &sh->cfg;
	uint8_t *unit = NULL, *rec = NULL;
	uint64_t pending_lo = 0, pending_n = 0;
	uint64_t *pend_page = NULL, *pend_ver = NULL, *pend_seq = NULL;
	uint64_t since_sync = 0;
	uint64_t rnd = c->seed ^ ((uint64_t)t->tid * 0x9E3779B97F4A7C15ULL);
	uint64_t stride, cursor = 0;
	int write_once = (c->mode != TORNER_MODE_OVERWRITE &&
			  c->mode != TORNER_MODE_MIXED);

	if (posix_memalign((void **)&unit, 4096, c->unit) ||
	    posix_memalign((void **)&rec, 4096, TORNER_PROG_RECSZ)) {
		t->err = ENOMEM;
		goto out;
	}

	/* Pages written since the last fsync, flushed to the progress log after. */
	pend_page = calloc(c->fsync_every ? c->fsync_every : 1, sizeof(uint64_t));
	pend_ver  = calloc(c->fsync_every ? c->fsync_every : 1, sizeof(uint64_t));
	pend_seq  = calloc(c->fsync_every ? c->fsync_every : 1, sizeof(uint64_t));
	if (!pend_page || !pend_ver || !pend_seq) {
		t->err = ENOMEM;
		goto out;
	}
	(void)pending_lo;

	stride = coprime_stride(t->nowned ? t->nowned : 1, rnd | 1);

	while (!atomic_load(&sh->stop)) {
		uint64_t page, ver, seq, idx;
		uint32_t s;

		if (c->mode == TORNER_MODE_APPEND) {
			/*
			 * Pages are claimed from one monotonic counter, so the
			 * file grows and every claim is unique -- ownership by
			 * modulus would leave holes and stop being an append.
			 * Each page is written exactly once, hence version 1.
			 */
			page = atomic_fetch_add(&sh->next_page, 1);
			if (page >= c->pages)
				break;
			ver = 1;
		} else if (write_once) {
			if (cursor >= t->nowned)
				break;
			idx = (cursor * stride) % t->nowned;
			cursor++;
			page = idx * c->threads + t->tid;
			if (page >= c->pages)
				continue;
			ver = 1;
		} else {
			if (!t->nowned)
				break;
			idx = splitmix(&rnd) % t->nowned;
			page = idx * c->threads + t->tid;
			if (page >= c->pages)
				continue;
			ver = ++t->ver[idx];
		}

		seq = atomic_fetch_add(&sh->seq, 1);

		for (s = 0; s < sh->spu; s++)
			torner_build_sector(unit + (size_t)s * c->sector,
					    c->sector, page, ver, s, sh->spu,
					    seq, t->tid, c->run_id);

		/* One atomic unit == one pwrite().  This is the thing under test. */
		if (pwrite_all(sh->fd, unit, c->unit, (off_t)page * c->unit)) {
			t->err = errno;
			break;
		}
		t->writes++;

		if (c->fsync_every) {
			pend_page[pending_n] = page;
			pend_ver[pending_n] = ver;
			pend_seq[pending_n] = seq;
			pending_n++;
			since_sync++;

			if (since_sync >= c->fsync_every) {
				uint64_t i;

				if (c->use_fdatasync ? fdatasync(sh->fd)
						     : fsync(sh->fd)) {
					t->err = errno;
					break;
				}
				t->fsyncs++;

				/*
				 * Only now is the data durable, so only now may
				 * the progress log claim it.  Losing records
				 * appended after this point is harmless: the log
				 * is a lower bound on what must survive.
				 */
				for (i = 0; i < pending_n; i++) {
					if (prog_append(sh, pend_page[i],
							pend_ver[i], pend_seq[i],
							t->tid, rec)) {
						t->err = errno;
						break;
					}
				}
				pending_n = 0;
				since_sync = 0;
				if (t->err)
					break;

				if (c->mark_every && c->mark_dev) {
					uint64_t due = atomic_load(&sh->next_mark);

					if (seq >= due &&
					    atomic_compare_exchange_strong(
						    &sh->next_mark, &due,
						    due + c->mark_every))
						emit_mark(sh);
				}
			}
		}

		/* every write: with interference one write can take a while */
		if (c->duration && elapsed_s(&sh->t0) >= (double)c->duration)
			break;
	}

out:
	atomic_fetch_add(&sh->writes, t->writes);
	atomic_fetch_add(&sh->fsyncs, t->fsyncs);
	free(unit);
	free(rec);
	free(pend_page);
	free(pend_ver);
	free(pend_seq);
	return NULL;
}

/* ------------------------------------------------------------ interference */

enum interf_kind { IF_SYNC = 0, IF_OTHER_FSYNC, IF_WRITEBACK, IF__N };

static const char *const interf_name[IF__N] = {
	"sync", "other_fsync", "writeback"
};

struct interferer {
	struct gen_shared *sh;
	enum interf_kind kind;
	uint32_t period_ms;
	pthread_t th;
	int started;
	uint64_t count;
	int err;
};

static void sleep_ms(uint32_t ms)
{
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };

	while (nanosleep(&ts, &ts) && errno == EINTR)
		;
}

static void *interfere(void *arg)
{
	struct interferer *it = arg;
	struct gen_shared *sh = it->sh;
	uint8_t *buf = NULL;
	uint64_t n = 0;
	char path[4096];
	int ofd = -1;

	if (it->kind == IF_OTHER_FSYNC) {
		/* same file system, different file: its commits are not ours */
		snprintf(path, sizeof(path), "%s.other", sh->cfg.path);
		ofd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (ofd < 0 || posix_memalign((void **)&buf, 4096, 4096)) {
			it->err = ofd < 0 ? errno : ENOMEM;
			goto out;
		}
		memset(buf, 0x5a, 4096);
	}

	while (!atomic_load(&sh->stop)) {
		switch (it->kind) {
		case IF_SYNC:
			sync();
			break;
		case IF_OTHER_FSYNC:
			if (pwrite_all(ofd, buf, 4096, (off_t)(n % 256) * 4096) ||
			    fsync(ofd)) {
				it->err = errno;
				goto out;
			}
			break;
		case IF_WRITEBACK:
			/* whatever is dirty in the target goes to the device now,
			 * including a unit whose pwrite() is still copying in */
			if (sync_file_range(sh->fd, 0, 0, SYNC_FILE_RANGE_WRITE)) {
				it->err = errno;
				goto out;
			}
			break;
		default:
			goto out;
		}
		n++;
		sleep_ms(it->period_ms);
	}
out:
	it->count = n;
	if (ofd >= 0)
		close(ofd);
	free(buf);
	return NULL;
}

static int setup_file(struct gen_shared *sh)
{
	const struct gen_cfg *c = &sh->cfg;
	off_t total = (off_t)c->pages * c->unit;
	int flags = O_RDWR | O_CREAT;

	if (c->untorn)
		flags |= O_TAU_UNTORN;
	if (c->direct)
		flags |= O_DIRECT;

	sh->fd = open(c->path, flags, 0644);
	if (sh->fd < 0) {
		fprintf(stderr, "torner gen: open %s: %s\n", c->path, strerror(errno));
		return -1;
	}

	if (ftruncate(sh->fd, 0)) {
		fprintf(stderr, "torner gen: truncate: %s\n", strerror(errno));
		return -1;
	}

	switch (c->mode) {
	case TORNER_MODE_APPEND:
		/* starts empty; i_size grows as pages are claimed */
		break;
	case TORNER_MODE_DELALLOC:
		/* sparse: allocation is delayed to writeback */
		if (ftruncate(sh->fd, total))
			goto etrunc;
		break;
	case TORNER_MODE_ALLOC:
		/* unwritten extents: the write converts them */
		if (fallocate(sh->fd, 0, 0, total)) {
			fprintf(stderr, "torner gen: fallocate: %s\n",
				strerror(errno));
			return -1;
		}
		break;
	case TORNER_MODE_OVERWRITE:
	case TORNER_MODE_MIXED:
	default: {
		/*
		 * Lay down version 0 everywhere first, so the steady-state
		 * workload is a pure in-place rewrite of allocated, written
		 * extents with no allocation in the path.
		 */
		uint8_t *unit;
		uint64_t p;
		uint32_t s;

		if (fallocate(sh->fd, 0, 0, total)) {
			fprintf(stderr, "torner gen: fallocate: %s\n",
				strerror(errno));
			return -1;
		}
		if (posix_memalign((void **)&unit, 4096, c->unit))
			return -1;
		for (p = 0; p < c->pages; p++) {
			for (s = 0; s < sh->spu; s++)
				torner_build_sector(unit + (size_t)s * c->sector,
						    c->sector, p, 0, s, sh->spu,
						    0, 0, c->run_id);
			if (pwrite_all(sh->fd, unit, c->unit, (off_t)p * c->unit)) {
				fprintf(stderr, "torner gen: prefill: %s\n",
					strerror(errno));
				free(unit);
				return -1;
			}
		}
		free(unit);
		if (fsync(sh->fd)) {
			fprintf(stderr, "torner gen: prefill fsync: %s\n",
				strerror(errno));
			return -1;
		}
		break;
	}
	}
	return 0;

etrunc:
	fprintf(stderr, "torner gen: truncate: %s\n", strerror(errno));
	return -1;
}

static void usage(void)
{
	fprintf(stderr,
"usage: torner gen --file <path> [options]\n"
"\n"
"  --file <path>           target file (on the file system under test)\n"
"  --progress-log <path>   progress log device/file -- MUST NOT live on the\n"
"                          stack under test (see torner(7) P2)\n"
"  --unit <bytes>          application atomic unit          [16384]\n"
"  --sector <bytes>        sector within a unit             [4096]\n"
"  --threads <n>           writer threads                   [4]\n"
"  --mode <m>              overwrite|append|alloc|delalloc|mixed [overwrite]\n"
"  --duration <s>          stop after s seconds (0 = until pages exhausted) [60]\n"
"  --pages <n>             atomic units in the file         [65536 = 1 GiB]\n"
"  --fsync-every <k>       fsync every k writes (0 = never) [1]\n"
"  --run-id <u64>          stamped into every sector        [time-derived]\n"
"  --seed <u64>            PRNG seed for access order       [1]\n"
"  --untorn                open the target with O_TAU_UNTORN, so tauJournal\n"
"                          actually engages (or mount -o tjournal_all)\n"
"  --direct                open the target with O_DIRECT\n"
"  --fdatasync             fdatasync() instead of fsync()\n"
"\n"
"  interference, run on the side while the writers work (0 = off):\n"
"  --sync-ms <n>           sync() every n ms\n"
"  --other-fsync-ms <n>    write + fsync() a sibling file every n ms\n"
"  --writeback-ms <n>      sync_file_range(WRITE) the target every n ms\n"
"\n"
"  --mark-dev <dm>         dm-log-writes device to stamp progress marks into;\n"
"                          without it a replayed state cannot bound P2\n"
"  --mark-every <k>        writes between marks                   [512]\n"
"  --progress-direct       open the progress log O_DIRECT (raw device)\n"
"  --quiet\n");
}

int torner_gen(int argc, char **argv)
{
	struct gen_shared sh;
	struct gen_thread *ts = NULL;
	struct interferer itf[IF__N];
	struct gen_cfg *c = &sh.cfg;
	int i, rc = 1, start_failed = 0;
	uint32_t t;
	double secs;

	memset(&sh, 0, sizeof(sh));
	memset(itf, 0, sizeof(itf));
	sh.fd = -1;
	sh.progfd = -1;
	c->unit = TORNER_DEF_UNIT;
	c->sector = TORNER_DEF_SECTOR;
	c->threads = 4;
	c->mode = TORNER_MODE_OVERWRITE;
	c->duration = 60;
	c->pages = 65536;
	c->fsync_every = 1;
	c->seed = 1;
	c->mark_every = 512;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

#define NEEDV() do { if (!v) { usage(); return 1; } i++; } while (0)
		if (!strcmp(a, "--file"))              { NEEDV(); c->path = v; }
		else if (!strcmp(a, "--progress-log")) { NEEDV(); c->proglog = v; }
		else if (!strcmp(a, "--unit"))         { NEEDV(); c->unit = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--sector"))       { NEEDV(); c->sector = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--threads"))      { NEEDV(); c->threads = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--duration"))     { NEEDV(); c->duration = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--pages"))        { NEEDV(); c->pages = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--fsync-every"))  { NEEDV(); c->fsync_every = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--run-id"))       { NEEDV(); c->run_id = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--seed"))         { NEEDV(); c->seed = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--mark-dev"))     { NEEDV(); c->mark_dev = v; }
		else if (!strcmp(a, "--mark-every"))   { NEEDV(); c->mark_every = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--untorn"))       { c->untorn = 1; }
		else if (!strcmp(a, "--direct"))       { c->direct = 1; }
		else if (!strcmp(a, "--fdatasync"))    { c->use_fdatasync = 1; }
		else if (!strcmp(a, "--sync-ms"))      { NEEDV(); c->sync_ms = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--other-fsync-ms")) { NEEDV(); c->other_fsync_ms = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--writeback-ms")) { NEEDV(); c->writeback_ms = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--progress-direct")) { c->prog_direct = 1; }
		else if (!strcmp(a, "--quiet"))        { c->quiet = 1; }
		else if (!strcmp(a, "--mode")) {
			NEEDV();
			if (torner_mode_parse(v, &c->mode)) {
				fprintf(stderr, "torner gen: bad mode '%s'\n", v);
				return 1;
			}
		} else if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
			usage();
			return 0;
		} else {
			fprintf(stderr, "torner gen: unknown option '%s'\n", a);
			usage();
			return 1;
		}
#undef NEEDV
	}

	if (!c->path) {
		fprintf(stderr, "torner gen: --file is required\n");
		usage();
		return 1;
	}
	if (c->sector < sizeof(struct torner_sector_hdr) ||
	    c->sector > TORNER_DEF_SECTOR) {
		fprintf(stderr, "torner gen: --sector must be in [%zu, %d]\n",
			sizeof(struct torner_sector_hdr), TORNER_DEF_SECTOR);
		return 1;
	}
	if (!c->unit || c->unit % c->sector) {
		fprintf(stderr, "torner gen: --unit must be a multiple of --sector\n");
		return 1;
	}
	sh.spu = c->unit / c->sector;
	if (sh.spu > TORNER_MAX_SECTORS_PER_UNIT) {
		fprintf(stderr, "torner gen: unit/sector > %d\n",
			TORNER_MAX_SECTORS_PER_UNIT);
		return 1;
	}
	if (!c->threads || !c->pages) {
		fprintf(stderr, "torner gen: --threads and --pages must be > 0\n");
		return 1;
	}
	if (!c->duration && c->mode == TORNER_MODE_OVERWRITE) {
		fprintf(stderr, "torner gen: overwrite mode needs --duration > 0\n");
		return 1;
	}
	if (!c->run_id) {
		struct timespec now;

		clock_gettime(CLOCK_REALTIME, &now);
		c->run_id = (uint64_t)now.tv_sec * 1000000000ULL + now.tv_nsec;
	}
	if (!c->proglog)
		fprintf(stderr,
			"torner gen: WARNING: no --progress-log, P2 cannot be checked\n");

	torner_crc32_init();

	if (setup_file(&sh))
		goto out;

	if (c->proglog) {
		int flags = O_WRONLY | O_CREAT | O_SYNC;

		if (c->prog_direct)
			flags |= O_DIRECT;
		sh.progfd = open(c->proglog, flags, 0644);
		if (sh.progfd < 0) {
			fprintf(stderr, "torner gen: open %s: %s\n",
				c->proglog, strerror(errno));
			goto out;
		}
	}

	ts = calloc(c->threads, sizeof(*ts));
	if (!ts)
		goto out;

	/*
	 * Bracket the workload in the log.  Everything before torner:begin is
	 * setup -- mkfs, the file's creation, the version-0 prefill -- and a
	 * crash there says nothing about the workload's atomicity.  Analysis
	 * can then separate the two exactly rather than by heuristic.
	 */
	if (c->mark_dev)
		dm_mark(c->mark_dev, "torner:begin");

	atomic_store(&sh.seq, 1);
	atomic_store(&sh.next_mark, c->mark_every);
	clock_gettime(CLOCK_MONOTONIC, &sh.t0);

	for (t = 0; t < c->threads; t++) {
		uint64_t owned = c->pages / c->threads +
				 ((c->pages % c->threads) > t ? 1 : 0);

		ts[t].sh = &sh;
		ts[t].tid = t;
		ts[t].nowned = owned;
		ts[t].ver = calloc(owned ? owned : 1, sizeof(uint64_t));
		if (!ts[t].ver)
			goto out;
	}
	{
		const uint32_t period[IF__N] = {
			c->sync_ms, c->other_fsync_ms, c->writeback_ms
		};
		int k;

		for (k = 0; k < IF__N; k++) {
			if (!period[k])
				continue;
			itf[k].sh = &sh;
			itf[k].kind = (enum interf_kind)k;
			itf[k].period_ms = period[k];
			if (pthread_create(&itf[k].th, NULL, interfere, &itf[k])) {
				fprintf(stderr, "torner gen: pthread_create: %s\n",
					strerror(errno));
				start_failed = 1;
				goto out_stop;
			}
			itf[k].started = 1;
		}
	}
	for (t = 0; t < c->threads; t++) {
		if (pthread_create(&ts[t].th, NULL, gen_worker, &ts[t])) {
			fprintf(stderr, "torner gen: pthread_create: %s\n",
				strerror(errno));
			atomic_store(&sh.stop, 1);
			start_failed = 1;
			break;
		}
	}
	/* join exactly the workers that started */
	{
		uint32_t started = t;

		for (t = 0; t < started; t++)
			pthread_join(ts[t].th, NULL);
	}
out_stop:
	/* the interference runs until the last writer is done, not beyond */
	atomic_store(&sh.stop, 1);
	for (i = 0; i < IF__N; i++)
		if (itf[i].started)
			pthread_join(itf[i].th, NULL);
	if (c->mark_dev)
		dm_mark(c->mark_dev, "torner:end");

	secs = elapsed_s(&sh.t0);
	rc = start_failed;
	for (t = 0; t < c->threads; t++) {
		if (ts[t].err) {
			fprintf(stderr, "torner gen: thread %u: %s\n",
				t, strerror(ts[t].err));
			rc = 1;
		}
	}
	for (i = 0; i < IF__N; i++) {
		if (itf[i].err) {
			fprintf(stderr, "torner gen: %s interferer: %s\n",
				interf_name[i], strerror(itf[i].err));
			rc = 1;
		}
	}

	if (!c->quiet) {
		printf("{\"tool\":\"torner-gen\",\"run_id\":%" PRIu64
		       ",\"mode\":\"%s\",\"untorn\":%s,\"threads\":%u,\"unit\":%u,\"sector\":%u"
		       ",\"pages\":%" PRIu64 ",\"fsync_every\":%" PRIu64
		       ",\"direct\":%s,\"fdatasync\":%s"
		       ",\"writes\":%llu,\"fsyncs\":%llu,\"prog_records\":%llu,\"marks\":%llu"
		       ",\"interference\":{\"sync_ms\":%u,\"syncs\":%" PRIu64
		       ",\"other_fsync_ms\":%u,\"other_fsyncs\":%" PRIu64
		       ",\"writeback_ms\":%u,\"writebacks\":%" PRIu64 "}"
		       ",\"elapsed_ms\":%.0f}\n",
		       c->run_id, torner_mode_name(c->mode),
		       c->untorn ? "true" : "false", c->threads,
		       c->unit, c->sector, c->pages, c->fsync_every,
		       c->direct ? "true" : "false",
		       c->use_fdatasync ? "true" : "false",
		       (unsigned long long)atomic_load(&sh.writes),
		       (unsigned long long)atomic_load(&sh.fsyncs),
		       (unsigned long long)atomic_load(&sh.prog_slot),
		       (unsigned long long)atomic_load(&sh.marks),
		       c->sync_ms, itf[IF_SYNC].count,
		       c->other_fsync_ms, itf[IF_OTHER_FSYNC].count,
		       c->writeback_ms, itf[IF_WRITEBACK].count,
		       secs * 1000.0);
	}

out:
	if (ts) {
		for (t = 0; t < c->threads; t++)
			free(ts[t].ver);
		free(ts);
	}
	if (sh.fd >= 0)
		close(sh.fd);
	if (sh.progfd >= 0)
		close(sh.progfd);
	return rc;
}
