/*
 * atomicw: the §6.3 microbenchmark, one tool for every configuration.
 * Buffered I/O only; 16 KiB pages (--unit); every thread writes its own
 * region and commits it in batches of --batch N pages:
 *
 *   --mode raw  N pwrites, then fdatasync of the data file(s)
 *   --mode tau  the same with the files opened O_TAU_UNTORN
 *   --mode app  doublewrite as InnoDB does it, per thread: the N pages go
 *               to the thread's own doublewrite file (dw.<thread>, N pages,
 *               filled at setup) in one sequential write, fdatasync, then
 *               the same pages in place, fdatasync of the data file(s)
 *
 * Files: <dir>/<--file-fmt, default f%03d> (--files F, --total split
 * evenly). With F >= T thread t owns files t, t+T, ...; with F < T (T a
 * multiple of F) T/F threads share a file, each a disjoint range of it.
 *
 * Patterns:
 *   overwrite  files prepared beforehand (--prepare, or another tool with
 *              the same names); random aligned pages in the thread's region,
 *              uniform or --dist zoned (75% of the writes on the first 1%
 *              of the region, the rest on the other 99%, fio's zoned:75/1:25/99)
 *   prealloc   files recreated and fallocate(0, size)d; every page written
 *              once, in a random permutation
 *   hole       files recreated and ftruncate(size)d (sparse); same order
 *   append     files recreated empty; sequential appends, round-robin over
 *              the thread's files
 * overwrite is time based: --warmup s not counted, --duration s measured.
 * The others are size based (every page of the files written once, the
 * window is the whole run until the last thread ends); --time-based measures
 * them for --duration s instead (stopping early if a thread runs out).
 *
 * A batch counts when its commit ends inside the window, with its pages.
 * IOPS = data pages per second (doublewrite writes not counted). Latencies:
 * commit = the time that makes the batch durable and atomic (raw/tau: the
 * fdatasync; app: doublewrite write + fdatasync + in-place writes +
 * fdatasync); sync = the data-file fdatasync; write = one in-place page
 * pwrite. Percentiles from a log-linear histogram (<1.6% bucket width).
 * Device bytes: change of sectors written (field 7 of /sys/block/<dev>/stat)
 * over the window. Output: one CSV line (--csv-header prints the header);
 * --timeline writes pages per second.
 *
 * --mode tau (or --tau) refuses to run, unless --no-tau-check, if the kernel
 * accepts O_DIRECT|O_TAU_UNTORN (tau rejects it with EINVAL).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <stdarg.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

enum pattern { P_OVERWRITE, P_PREALLOC, P_HOLE, P_APPEND };
static const char *pattern_names[] = { "overwrite", "prealloc", "hole", "append" };
enum wmode { M_RAW, M_TAU, M_APP };
static const char *mode_names[] = { "raw", "tau", "app" };

/* log-linear histogram of nanoseconds: values < 128 exact, then 64 buckets
 * per power of two */
#define HBUCKETS (128 + 57 * 64)

static int hidx(uint64_t v)
{
	if (v < 128)
		return (int)v;
	int msb = 63 - __builtin_clzll(v);
	return 128 + (msb - 7) * 64 + (int)((v >> (msb - 6)) & 63);
}

static double hmid(int i)
{
	if (i < 128)
		return i;
	int msb = 7 + (i - 128) / 64, sub = (i - 128) % 64;
	double lo = (double)(1ULL << msb) + (double)sub * (double)(1ULL << (msb - 6));
	return lo + (double)(1ULL << (msb - 6)) / 2;
}

struct seg {
	int fd;
	uint64_t first;		/* first unit of the range in the file */
	uint64_t cursor;	/* append: units written */
};

struct lat {			/* one latency kind, counted in the window */
	uint64_t n, sum, max;
	uint64_t *hist;
};

struct thr {
	int id;
	struct seg *segs;
	int nsegs;
	uint64_t seg_units;	/* units per segment (all equal) */
	uint64_t nunits;	/* nsegs * seg_units */
	uint32_t *perm;		/* prealloc/hole */
	uint64_t next;		/* prealloc/hole/append: pages issued */
	uint64_t rng;
	char *buf;		/* --batch pages: the doublewrite image, page i in slot i */
	int dwfd;
	int *bfd;		/* targets of the batch */
	uint64_t *boff, *bwlat;
	int *dirty;		/* segments written in the batch */
	uint64_t pages, batches;
	struct lat commit, sync, write;
	uint64_t *tl;		/* pages per second since start, whole run */
	uint64_t finish;	/* size based: when the thread ran out */
	pthread_t tid;
	char pad[64];
};

static struct {
	const char *dir, *dev, *hist_path, *tl_path, *label, *fmt;
	enum pattern pattern;
	enum wmode mode;
	int threads, files, warmup, duration, tau_check, use_fsync, prepare, zoned, time_based, batch;
	uint64_t total, unit, file_size, file_units, seed;
} o = {
	.threads = 1, .files = 64, .warmup = 10, .duration = 180, .tau_check = 1, .batch = 64,
	.total = 128ULL << 30, .unit = 16384, .seed = 1, .label = "", .fmt = "f%03d",
};

static _Atomic uint64_t m_start = UINT64_MAX, m_end = UINT64_MAX, exhaust_ns = UINT64_MAX;
static _Atomic int stop_flag;
static uint64_t t_start;
static pthread_barrier_t barrier;

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint64_t splitmix64(uint64_t *x)
{
	uint64_t z = (*x += 0x9E3779B97F4A7C15ULL);
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

static uint64_t xs64(uint64_t *s)
{
	uint64_t x = *s;
	x ^= x >> 12;
	x ^= x << 25;
	x ^= x >> 27;
	*s = x;
	return x * 0x2545F4914F6CDD1DULL;
}

static uint64_t below(uint64_t *s, uint64_t n)
{
	return (uint64_t)(((unsigned __int128)xs64(s) * n) >> 64);
}

static void die(const char *fmt, ...) __attribute__((format(printf, 1, 2), noreturn));
static void die(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "atomicw: ");
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	exit(1);
}

static uint64_t parse_size(const char *s)
{
	char *end;
	double v = strtod(s, &end);
	switch (*end) {
	case 'k': case 'K': v *= 1024; break;
	case 'm': case 'M': v *= 1024 * 1024; break;
	case 'g': case 'G': v *= 1024.0 * 1024 * 1024; break;
	case 't': case 'T': v *= 1024.0 * 1024 * 1024 * 1024; break;
	case '\0': break;
	default: die("bad size %s", s);
	}
	return (uint64_t)v;
}

static void file_path(char *p, size_t n, int f)
{
	char name[256];
	snprintf(name, sizeof(name), o.fmt, f);
	snprintf(p, n, "%s/%s", o.dir, name);
}

static int open_flags(void)
{
	return O_RDWR | (o.mode == M_TAU ? O_TAU_UNTORN : 0);
}

/* device stat fields (1-based): 5 writes, 7 sectors written, 16 flushes */
static int read_devstat(uint64_t v[17])
{
	char p[256];
	memset(v, 0, 17 * sizeof(v[0]));
	if (!o.dev)
		return -1;
	snprintf(p, sizeof(p), "/sys/block/%s/stat", o.dev);
	FILE *f = fopen(p, "r");
	if (!f)
		return -1;
	for (int i = 0; i < 17; i++)
		if (fscanf(f, "%" SCNu64, &v[i]) != 1)
			break;
	fclose(f);
	return 0;
}

static void fill_random(char *b, size_t n, uint64_t seed)
{
	uint64_t s = seed | 1;
	for (size_t i = 0; i + 8 <= n; i += 8) {
		uint64_t x = xs64(&s);
		memcpy(b + i, &x, 8);
	}
}

static void write_all(int fd, const char *b, size_t n, uint64_t off, const char *what)
{
	size_t done = 0;
	while (done < n) {
		ssize_t r = pwrite(fd, b + done, n - done, (off_t)(off + done));
		if (r < 0) {
			if (errno == EINTR)
				continue;
			die("%s pwrite: %s", what, strerror(errno));
		}
		done += (size_t)r;
	}
}

/* --prepare: create and fill every file sequentially (1 MiB writes, then
 * fsync), up to 16 files at a time */
struct prep_arg { int first, step; };

static void *prep_worker(void *a)
{
	struct prep_arg *pa = a;
	size_t bs = 1 << 20;
	char *buf;
	if (posix_memalign((void **)&buf, 4096, bs))
		die("posix_memalign");
	fill_random(buf, bs, o.seed + 7 + (uint64_t)pa->first);
	for (int f = pa->first; f < o.files; f += pa->step) {
		char p[4096];
		file_path(p, sizeof(p), f);
		int fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0)
			die("open %s: %s", p, strerror(errno));
		for (uint64_t off = 0; off < o.file_size; off += bs) {
			size_t n = (o.file_size - off < bs) ? (size_t)(o.file_size - off) : bs;
			write_all(fd, buf, n, off, "prepare");
		}
		if (fsync(fd))
			die("fsync %s: %s", p, strerror(errno));
		close(fd);
	}
	return NULL;
}

static void do_prepare(void)
{
	int n = o.files < 16 ? o.files : 16;
	pthread_t t[16];
	struct prep_arg a[16];
	uint64_t t0 = now_ns();
	for (int i = 0; i < n; i++) {
		a[i] = (struct prep_arg){ i, n };
		pthread_create(&t[i], NULL, prep_worker, &a[i]);
	}
	for (int i = 0; i < n; i++)
		pthread_join(t[i], NULL);
	sync();
	double s = (now_ns() - t0) / 1e9;
	printf("prepared %d files x %" PRIu64 " MiB in %.1f s (%.0f MiB/s)\n", o.files,
	       o.file_size >> 20, s, (double)o.files * (double)(o.file_size >> 20) / s);
}

/* prealloc/hole/append: fresh files every run */
static void recreate_files(void)
{
	char p[4096];
	for (int f = 0; f < 4096; f++) {	/* remove what an earlier run left */
		file_path(p, sizeof(p), f);
		if (unlink(p) && errno == ENOENT && f >= o.files)
			break;
	}
	for (int f = 0; f < o.files; f++) {
		file_path(p, sizeof(p), f);
		int fd = open(p, O_RDWR | O_CREAT | O_TRUNC | (o.mode == M_TAU ? O_TAU_UNTORN : 0), 0644);
		if (fd < 0)
			die("create %s: %s", p, strerror(errno));
		if (o.pattern == P_PREALLOC && fallocate(fd, 0, 0, (off_t)o.file_size))
			die("fallocate %s: %s", p, strerror(errno));
		if (o.pattern == P_HOLE && ftruncate(fd, (off_t)o.file_size))
			die("ftruncate %s: %s", p, strerror(errno));
		close(fd);
	}
}

static void check_files(void)
{
	char p[4096];
	struct stat st;
	for (int f = 0; f < o.files; f++) {
		file_path(p, sizeof(p), f);
		if (stat(p, &st) || (uint64_t)st.st_size < o.file_size)
			die("%s missing or under %" PRIu64 " bytes: prepare it first", p, o.file_size);
	}
}

static void tau_check(void)
{
	char p[4096];
	snprintf(p, sizeof(p), "%s/.taucheck", o.dir);
	int fd = open(p, O_RDWR | O_CREAT | O_DIRECT | O_TAU_UNTORN, 0644);
	int err = errno;
	if (fd >= 0) {
		close(fd);
		unlink(p);
		die("O_DIRECT|O_TAU_UNTORN was accepted: tau is not active on %s", o.dir);
	}
	unlink(p);
	if (err != EINVAL)
		die("tau check: open(O_DIRECT|O_TAU_UNTORN) failed with %s, not EINVAL", strerror(err));
}

static void setup_thread(struct thr *t)
{
	char p[4096];
	int T = o.threads, F = o.files;
	if (F >= T) {
		t->nsegs = (F - t->id + T - 1) / T;
		t->segs = calloc((size_t)t->nsegs, sizeof(*t->segs));
		for (int k = 0; k < t->nsegs; k++) {
			file_path(p, sizeof(p), t->id + k * T);
			t->segs[k].fd = open(p, open_flags());
			if (t->segs[k].fd < 0)
				die("open %s: %s", p, strerror(errno));
		}
		t->seg_units = o.file_units;
	} else {
		int per = T / F;	/* threads per file */
		t->nsegs = 1;
		t->segs = calloc(1, sizeof(*t->segs));
		file_path(p, sizeof(p), t->id / per);
		t->segs[0].fd = open(p, open_flags());
		if (t->segs[0].fd < 0)
			die("open %s: %s", p, strerror(errno));
		t->seg_units = o.file_units / (uint64_t)per;
		t->segs[0].first = (uint64_t)(t->id % per) * t->seg_units;
	}
	t->nunits = (uint64_t)t->nsegs * t->seg_units;
	uint64_t sm = o.seed * 1000003ULL + (uint64_t)t->id;
	t->rng = splitmix64(&sm) | 1;
	if (o.pattern == P_PREALLOC || o.pattern == P_HOLE) {
		if (t->nunits > UINT32_MAX)
			die("too many units per thread");
		t->perm = malloc(t->nunits * sizeof(uint32_t));
		if (!t->perm)
			die("perm: out of memory");
		for (uint64_t i = 0; i < t->nunits; i++)
			t->perm[i] = (uint32_t)i;
		for (uint64_t i = t->nunits - 1; i > 0; i--) {
			uint64_t j = below(&t->rng, i + 1);
			uint32_t x = t->perm[i];
			t->perm[i] = t->perm[j];
			t->perm[j] = x;
		}
	}
	size_t bb = (size_t)o.batch * o.unit;
	if (posix_memalign((void **)&t->buf, 4096, bb))
		die("posix_memalign");
	fill_random(t->buf, bb, o.seed + 101 + (uint64_t)t->id);
	t->bfd = calloc((size_t)o.batch, sizeof(int));
	t->boff = calloc((size_t)o.batch, sizeof(uint64_t));
	t->bwlat = calloc((size_t)o.batch, sizeof(uint64_t));
	t->dirty = calloc((size_t)t->nsegs, sizeof(int));
	t->dwfd = -1;
	if (o.mode == M_APP) {	/* the doublewrite file: written over in place every batch */
		snprintf(p, sizeof(p), "%s/dw.%d", o.dir, t->id);
		t->dwfd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (t->dwfd < 0)
			die("open %s: %s", p, strerror(errno));
		write_all(t->dwfd, t->buf, bb, 0, "doublewrite setup");
		if (fsync(t->dwfd))
			die("fsync %s: %s", p, strerror(errno));
	}
	t->commit.hist = calloc(HBUCKETS, sizeof(uint64_t));
	t->sync.hist = calloc(HBUCKETS, sizeof(uint64_t));
	t->write.hist = calloc(HBUCKETS, sizeof(uint64_t));
	t->tl = calloc((size_t)(o.warmup + o.duration + 30) + 20000, sizeof(uint64_t));
}

/* next target, or -1 when the thread has written all its pages */
static int next_target(struct thr *t, int *seg, uint64_t *off)
{
	uint64_t u = 0;
	switch (o.pattern) {
	case P_OVERWRITE:
		if (o.zoned) {	/* fio zoned:75/1:25/99 */
			uint64_t hot = t->nunits / 100 ? t->nunits / 100 : 1;
			u = below(&t->rng, 100) < 75 ? below(&t->rng, hot)
						    : hot + below(&t->rng, t->nunits - hot);
		} else {
			u = below(&t->rng, t->nunits);
		}
		break;
	case P_PREALLOC:
	case P_HOLE:
		if (t->next >= t->nunits)
			return -1;
		u = t->perm[t->next++];
		break;
	case P_APPEND: {
		if (t->next >= t->nunits)
			return -1;
		int k = (int)(t->next++ % (uint64_t)t->nsegs);
		struct seg *s = &t->segs[k];
		*seg = k;
		*off = (s->first + s->cursor++) * o.unit;
		return 0;
	}
	}
	int k = (int)(u / t->seg_units);
	*seg = k;
	*off = (t->segs[k].first + u % t->seg_units) * o.unit;
	return 0;
}

static void lower_end(uint64_t v)
{
	uint64_t cur = atomic_load(&m_end);
	while (v < cur && !atomic_compare_exchange_weak(&m_end, &cur, v))
		;
}

static void lat_add(struct lat *l, uint64_t v)
{
	l->n++;
	l->sum += v;
	if (v > l->max)
		l->max = v;
	l->hist[hidx(v)]++;
}

static void do_sync(int fd)
{
	if ((o.use_fsync ? fsync(fd) : fdatasync(fd)) != 0)
		die("%s: %s", o.use_fsync ? "fsync" : "fdatasync", strerror(errno));
}

static void *worker(void *arg)
{
	struct thr *t = arg;
	uint64_t seq = 0;
	size_t tl_len = (size_t)(o.warmup + o.duration + 30) + 20000;
	int size_based = o.pattern != P_OVERWRITE && !o.time_based;
	pthread_barrier_wait(&barrier);
	while (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) {
		int k = 0, seg;
		uint64_t off;
		while (k < o.batch && next_target(t, &seg, &off) == 0) {
			t->bfd[k] = seg;
			t->boff[k] = off;
			k++;
		}
		if (k == 0) {
			uint64_t e = now_ns(), cur = UINT64_MAX;
			t->finish = e;
			if (!size_based) {
				atomic_compare_exchange_strong(&exhaust_ns, &cur, e);
				lower_end(e);
			}
			break;
		}
		for (int i = 0; i < k; i++) {	/* stamp the pages */
			seq++;
			memcpy(t->buf + (size_t)i * o.unit, &seq, sizeof(seq));
		}
		uint64_t a = now_ns();
		if (o.mode == M_APP) {
			write_all(t->dwfd, t->buf, (size_t)k * o.unit, 0, "doublewrite");
			do_sync(t->dwfd);
		}
		for (int i = 0; i < k; i++) {
			uint64_t w0 = now_ns();
			write_all(t->segs[t->bfd[i]].fd, t->buf + (size_t)i * o.unit, o.unit, t->boff[i], "page");
			t->bwlat[i] = now_ns() - w0;
			t->dirty[t->bfd[i]] = 1;
		}
		uint64_t s0 = now_ns();
		for (int j = 0; j < t->nsegs; j++)
			if (t->dirty[j]) {
				do_sync(t->segs[j].fd);
				t->dirty[j] = 0;
			}
		uint64_t c = now_ns();
		size_t sec = (size_t)((c - t_start) / 1000000000ULL);
		if (sec < tl_len)
			t->tl[sec] += (uint64_t)k;
		if (c >= atomic_load_explicit(&m_start, memory_order_relaxed) &&
		    c < atomic_load_explicit(&m_end, memory_order_relaxed)) {
			t->pages += (uint64_t)k;
			t->batches++;
			lat_add(&t->commit, o.mode == M_APP ? c - a : c - s0);
			lat_add(&t->sync, c - s0);
			for (int i = 0; i < k; i++)
				lat_add(&t->write, t->bwlat[i]);
		}
	}
	if (!t->finish)
		t->finish = now_ns();
	return NULL;
}

static void sleep_until(uint64_t target)
{
	for (;;) {
		uint64_t n = now_ns();
		if (n >= target || atomic_load(&m_end) <= n)
			return;
		uint64_t d = target - n;
		if (d > 5000000ULL)
			d = 5000000ULL;	/* wake every 5 ms to notice an exhaustion */
		struct timespec ts = { 0, (long)d };
		nanosleep(&ts, NULL);
	}
}

static void usage(void)
{
	fprintf(stderr,
		"usage: atomicw --dir DIR --pattern overwrite|prealloc|hole|append [--mode raw|tau|app]\n"
		"  [--threads T] [--files F] [--file-fmt f%%03d] [--total 128G] [--unit 16384]\n"
		"  [--batch 64] [--dist uniform|zoned] [--warmup 10] [--duration 180] [--time-based]\n"
		"  [--seed 1] [--dev nvme0c0n1] [--fsync] [--no-tau-check]\n"
		"  [--hist FILE] [--timeline FILE] [--label TEXT] [--prepare] [--csv-header]\n");
	exit(2);
}

static const char *csv_header =
	"wmode,pattern,threads,files,batch,unit,dist,run,pages,batches,duration_s,iops,"
	"commit_mean_us,commit_p99_us,commit_p999_us,commit_max_us,sync_mean_us,sync_p99_us,"
	"write_p999_us,write_max_us,dev_bytes_per_page,dev_flushes_per_batch,exhausted,notes";

static double pctl(uint64_t *hist, uint64_t n, double q)
{
	uint64_t want = (uint64_t)(q * (double)n), acc = 0;
	for (int b = 0; b < HBUCKETS; b++) {
		acc += hist[b];
		if (acc > want)
			return hmid(b);
	}
	return 0;
}

static void lat_merge(struct lat *dst, const struct lat *src)
{
	dst->n += src->n;
	dst->sum += src->sum;
	if (src->max > dst->max)
		dst->max = src->max;
	for (int b = 0; b < HBUCKETS; b++)
		dst->hist[b] += src->hist[b];
}

int main(int argc, char **argv)
{
	static struct option lo[] = {
		{ "dir", 1, 0, 'd' }, { "pattern", 1, 0, 'p' }, { "threads", 1, 0, 't' },
		{ "files", 1, 0, 'f' }, { "total", 1, 0, 'S' }, { "unit", 1, 0, 'u' },
		{ "warmup", 1, 0, 'w' }, { "duration", 1, 0, 'D' }, { "seed", 1, 0, 's' },
		{ "dev", 1, 0, 'v' }, { "fsync", 0, 0, 'F' }, { "tau", 0, 0, 'T' },
		{ "no-tau-check", 0, 0, 'N' }, { "hist", 1, 0, 'H' }, { "timeline", 1, 0, 'L' },
		{ "label", 1, 0, 'l' }, { "prepare", 0, 0, 'P' }, { "csv-header", 0, 0, 'C' },
		{ "mode", 1, 0, 'm' }, { "batch", 1, 0, 'b' }, { "dist", 1, 0, 'z' },
		{ "time-based", 0, 0, 'B' }, { "file-fmt", 1, 0, 'n' },
		{ 0, 0, 0, 0 }
	};
	const char *pat = NULL;
	int c;
	while ((c = getopt_long(argc, argv, "", lo, NULL)) != -1) {
		switch (c) {
		case 'd': o.dir = optarg; break;
		case 'p': pat = optarg; break;
		case 't': o.threads = atoi(optarg); break;
		case 'f': o.files = atoi(optarg); break;
		case 'S': o.total = parse_size(optarg); break;
		case 'u': o.unit = parse_size(optarg); break;
		case 'w': o.warmup = atoi(optarg); break;
		case 'D': o.duration = atoi(optarg); break;
		case 's': o.seed = strtoull(optarg, NULL, 0); break;
		case 'v': o.dev = optarg; break;
		case 'F': o.use_fsync = 1; break;
		case 'T': o.mode = M_TAU; break;
		case 'N': o.tau_check = 0; break;
		case 'H': o.hist_path = optarg; break;
		case 'L': o.tl_path = optarg; break;
		case 'l': o.label = optarg; break;
		case 'P': o.prepare = 1; break;
		case 'C': puts(csv_header); return 0;
		case 'm':
			if (!strcmp(optarg, "raw")) o.mode = M_RAW;
			else if (!strcmp(optarg, "tau")) o.mode = M_TAU;
			else if (!strcmp(optarg, "app")) o.mode = M_APP;
			else usage();
			break;
		case 'b': o.batch = atoi(optarg); break;
		case 'z':
			if (!strcmp(optarg, "zoned")) o.zoned = 1;
			else if (strcmp(optarg, "uniform")) usage();
			break;
		case 'B': o.time_based = 1; break;
		case 'n': o.fmt = optarg; break;
		default: usage();
		}
	}
	if (!o.dir)
		usage();
	if (o.files < 1 || o.files > 4096 || o.threads < 1 || o.unit % 4096 || o.unit == 0 || o.batch < 1)
		usage();
	o.file_size = o.total / (uint64_t)o.files / o.unit * o.unit;
	o.file_units = o.file_size / o.unit;
	if (o.prepare) {
		do_prepare();
		return 0;
	}
	if (!pat)
		usage();
	int found = 0;
	for (int i = 0; i < 4; i++)
		if (!strcmp(pat, pattern_names[i])) {
			o.pattern = (enum pattern)i;
			found = 1;
		}
	if (!found)
		usage();
	if (o.files < o.threads && (o.threads % o.files || o.pattern == P_APPEND))
		die("with fewer files than threads, threads must be a multiple of files (not append)");
	if (o.mode == M_TAU && o.tau_check)
		tau_check();
	int size_based = o.pattern != P_OVERWRITE && !o.time_based;

	if (o.pattern == P_OVERWRITE)
		check_files();
	else
		recreate_files();

	struct thr *th = calloc((size_t)o.threads, sizeof(*th));
	for (int i = 0; i < o.threads; i++) {
		th[i].id = i;
		setup_thread(&th[i]);
	}
	sync();
	pthread_barrier_init(&barrier, NULL, (unsigned)o.threads + 1);
	for (int i = 0; i < o.threads; i++)
		pthread_create(&th[i].tid, NULL, worker, &th[i]);

	uint64_t d0[17], d1[17];
	int have_dev, warm_exhausted = 0;
	t_start = now_ns();
	if (size_based) {
		atomic_store(&m_start, t_start);
		have_dev = read_devstat(d0) == 0;
		pthread_barrier_wait(&barrier);
		for (int i = 0; i < o.threads; i++)
			pthread_join(th[i].tid, NULL);
		read_devstat(d1);
		uint64_t last = t_start;
		for (int i = 0; i < o.threads; i++)
			if (th[i].finish > last)
				last = th[i].finish;
		atomic_store(&m_end, last);
	} else {
		atomic_store(&m_start, t_start + (uint64_t)o.warmup * 1000000000ULL);
		atomic_store(&m_end, t_start + (uint64_t)(o.warmup + o.duration) * 1000000000ULL);
		pthread_barrier_wait(&barrier);
		uint64_t ms = atomic_load(&m_start);
		sleep_until(ms);
		warm_exhausted = atomic_load(&exhaust_ns) <= ms;
		have_dev = read_devstat(d0) == 0;
		sleep_until(atomic_load(&m_end));
		read_devstat(d1);
		atomic_store(&stop_flag, 1);
		for (int i = 0; i < o.threads; i++)
			pthread_join(th[i].tid, NULL);
	}

	uint64_t ms = atomic_load(&m_start), me = atomic_load(&m_end), ex = atomic_load(&exhaust_ns);
	double dur = me > ms ? (me - ms) / 1e9 : 0;
	uint64_t pages = 0, batches = 0;
	struct lat lc = { 0 }, ls = { 0 }, lw = { 0 };
	lc.hist = calloc(HBUCKETS, sizeof(uint64_t));
	ls.hist = calloc(HBUCKETS, sizeof(uint64_t));
	lw.hist = calloc(HBUCKETS, sizeof(uint64_t));
	size_t tl_len = (size_t)(o.warmup + o.duration + 30) + 20000;
	uint64_t *tl = calloc(tl_len, sizeof(uint64_t));
	for (int i = 0; i < o.threads; i++) {
		pages += th[i].pages;
		batches += th[i].batches;
		lat_merge(&lc, &th[i].commit);
		lat_merge(&ls, &th[i].sync);
		lat_merge(&lw, &th[i].write);
		for (size_t s = 0; s < tl_len; s++)
			tl[s] += th[i].tl[s];
	}
	double dev_bytes = 0, dev_flush = 0;
	if (have_dev && pages) {
		dev_bytes = (double)(d1[6] - d0[6]) * 512.0 / (double)pages;
		dev_flush = batches ? (double)(d1[15] - d0[15]) / (double)batches : 0;
	}
	char notes[256] = "";
	if (warm_exhausted)
		snprintf(notes, sizeof(notes), "exhausted in warm-up");
	else if (ex != UINT64_MAX)
		snprintf(notes, sizeof(notes), "exhausted at %.1f s of the window", (ex - ms) / 1e9);
	if (size_based) {
		uint64_t want = 0;
		for (int i = 0; i < o.threads; i++)
			want += th[i].nunits;
		if (pages != want)
			snprintf(notes + strlen(notes), sizeof(notes) - strlen(notes),
				 "%spages %" PRIu64 " of %" PRIu64, notes[0] ? "; " : "", pages, want);
	}
	if (o.use_fsync)
		strncat(notes, notes[0] ? "; fsync" : "fsync", sizeof(notes) - strlen(notes) - 1);
	if (!have_dev)
		strncat(notes, notes[0] ? "; no devstat" : "no devstat", sizeof(notes) - strlen(notes) - 1);
	double nb = lc.n ? (double)lc.n : 1;
	printf("%s,%s,%d,%d,%d,%" PRIu64 ",%s,%s,%" PRIu64 ",%" PRIu64 ",%.3f,%.1f,"
	       "%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.0f,%.3f,%d,%s\n",
	       mode_names[o.mode], pattern_names[o.pattern], o.threads, o.files, o.batch, o.unit,
	       o.zoned ? "zoned:75/1:25/99" : "uniform", size_based ? "size" : "time",
	       pages, batches, dur, dur > 0 ? pages / dur : 0,
	       lc.sum / nb / 1e3, pctl(lc.hist, lc.n, 0.99) / 1e3, pctl(lc.hist, lc.n, 0.999) / 1e3,
	       lc.max / 1e3, ls.sum / nb / 1e3, pctl(ls.hist, ls.n, 0.99) / 1e3,
	       pctl(lw.hist, lw.n, 0.999) / 1e3, lw.max / 1e3, dev_bytes, dev_flush,
	       ex != UINT64_MAX, notes);
	if (o.hist_path) {
		FILE *f = fopen(o.hist_path, "w");
		if (f) {
			fprintf(f, "# latency histograms (kind, ns bucket midpoint, count)%s%s\n",
				o.label[0] ? ": " : "", o.label);
			struct lat *all[3] = { &lc, &ls, &lw };
			const char *nm[3] = { "commit", "sync", "write" };
			for (int k = 0; k < 3; k++)
				for (int b = 0; b < HBUCKETS; b++)
					if (all[k]->hist[b])
						fprintf(f, "%s %.0f %" PRIu64 "\n", nm[k], hmid(b), all[k]->hist[b]);
			fclose(f);
		}
	}
	if (o.tl_path) {
		FILE *f = fopen(o.tl_path, "w");
		if (f) {
			fprintf(f, "# second pages (warm-up %d s, window %s)\n", size_based ? 0 : o.warmup,
				size_based ? "whole run" : "duration");
			uint64_t endt = me - t_start;
			for (size_t s = 0; s < tl_len && s * 1000000000ULL < endt + 200000000ULL; s++)
				fprintf(f, "%zu %" PRIu64 "\n", s, tl[s]);
			fclose(f);
		}
	}
	return 0;
}
