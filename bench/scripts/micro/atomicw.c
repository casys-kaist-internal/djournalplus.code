/*
 * atomicw: the §6.3 microbenchmark. Every thread repeats one 16 KiB aligned
 * pwrite() followed by fdatasync() (fsync() with --fsync) on files it alone
 * writes, so the queue depth equals the thread count. Buffered I/O only.
 *
 * Files: <dir>/f000 ... (--files F, --total bytes split evenly). With F >= T
 * thread t owns files t, t+T, t+2T, ...; with F < T (T a multiple of F), T/F
 * threads share a file and each owns a disjoint range of it.
 *
 * Patterns:
 *   overwrite  files prepared once (--prepare: sequential fill); random
 *              aligned offsets in the thread's own region, with replacement
 *   prealloc   files recreated and fallocate(0, size)d; every offset written
 *              once, in a random permutation
 *   hole       files recreated and ftruncate(size)d (sparse); same order
 *   append     files recreated empty; sequential 16 KiB appends, round-robin
 *              over the thread's files
 * prealloc/hole/append stop when the first thread runs out of offsets; the
 * measured window then ends there (reported as exhausted).
 *
 * A run: set up, sync(), --warmup seconds not counted, --duration seconds
 * measured. An op counts if its fdatasync returns inside the window.
 * Output: one CSV line (--csv-header prints the header). Latencies are of
 * fdatasync unless named otherwise; percentiles come from a log-linear
 * histogram (<1.6% bucket width). Device bytes are the change of sectors
 * written (field 7 of /sys/block/<dev>/stat) over the window.
 *
 * --tau opens the files with O_TAU_UNTORN; unless --no-tau-check, the run is
 * refused if the kernel accepts O_DIRECT|O_TAU_UNTORN (tau rejects it with
 * EINVAL, so acceptance means tau is not active).
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

struct thr {
	int id;
	struct seg *segs;
	int nsegs;
	uint64_t seg_units;	/* units per segment (all equal) */
	uint64_t nunits;	/* nsegs * seg_units */
	uint32_t *perm;		/* prealloc/hole */
	uint64_t next;		/* prealloc/hole/append: ops issued */
	uint64_t rng;
	char *buf;
	/* counted in the window */
	uint64_t ops, sum_sync, sum_write, sum_op, max_sync;
	uint64_t *hist_sync;
	uint64_t *tl;		/* ops per second since start, whole run */
	pthread_t tid;
	char pad[64];
};

static struct {
	const char *dir, *dev, *hist_path, *tl_path, *label;
	enum pattern pattern;
	int threads, files, warmup, duration, tau, tau_check, use_fsync, prepare;
	uint64_t total, unit, file_size, file_units, seed;
} o = {
	.threads = 1, .files = 64, .warmup = 10, .duration = 60, .tau_check = 1,
	.total = 128ULL << 30, .unit = 16384, .seed = 1, .label = "",
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
	snprintf(p, n, "%s/f%03d", o.dir, f);
}

static int open_flags(void)
{
	return O_RDWR | (o.tau ? O_TAU_UNTORN : 0);
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
			if (pwrite(fd, buf, n, (off_t)off) != (ssize_t)n)
				die("prepare write %s: %s", p, strerror(errno));
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
		int fd = open(p, O_RDWR | O_CREAT | O_TRUNC | (o.tau ? O_TAU_UNTORN : 0), 0644);
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
		if (stat(p, &st) || (uint64_t)st.st_size != o.file_size)
			die("%s missing or not %" PRIu64 " bytes: run --prepare first", p, o.file_size);
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
	if (posix_memalign((void **)&t->buf, 4096, o.unit))
		die("posix_memalign");
	fill_random(t->buf, o.unit, o.seed + 101 + (uint64_t)t->id);
	t->hist_sync = calloc(HBUCKETS, sizeof(uint64_t));
	t->tl = calloc((size_t)(o.warmup + o.duration + 30), sizeof(uint64_t));
}

/* next target, or -1 when the thread has written all its offsets */
static int next_target(struct thr *t, int *fd, uint64_t *off)
{
	uint64_t u = 0;
	switch (o.pattern) {
	case P_OVERWRITE:
		u = below(&t->rng, t->nunits);
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
		struct seg *s = &t->segs[t->next++ % (uint64_t)t->nsegs];
		*fd = s->fd;
		*off = (s->first + s->cursor++) * o.unit;
		return 0;
	}
	}
	struct seg *s = &t->segs[u / t->seg_units];
	*fd = s->fd;
	*off = (s->first + u % t->seg_units) * o.unit;
	return 0;
}

static void lower_end(uint64_t v)
{
	uint64_t cur = atomic_load(&m_end);
	while (v < cur && !atomic_compare_exchange_weak(&m_end, &cur, v))
		;
}

static void *worker(void *arg)
{
	struct thr *t = arg;
	uint64_t seq = 0;
	size_t tl_len = (size_t)(o.warmup + o.duration + 30);
	pthread_barrier_wait(&barrier);
	while (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) {
		int fd;
		uint64_t off;
		if (next_target(t, &fd, &off) < 0) {
			uint64_t e = now_ns(), cur = UINT64_MAX;
			atomic_compare_exchange_strong(&exhaust_ns, &cur, e);
			lower_end(e);
			break;
		}
		seq++;
		memcpy(t->buf, &seq, sizeof(seq));
		uint64_t a = now_ns();
		size_t done = 0;
		while (done < o.unit) {
			ssize_t n = pwrite(fd, t->buf + done, o.unit - done, (off_t)(off + done));
			if (n < 0) {
				if (errno == EINTR)
					continue;
				die("pwrite: %s", strerror(errno));
			}
			done += (size_t)n;
		}
		uint64_t b = now_ns();
		if ((o.use_fsync ? fsync(fd) : fdatasync(fd)) != 0)
			die("%s: %s", o.use_fsync ? "fsync" : "fdatasync", strerror(errno));
		uint64_t c = now_ns();
		size_t sec = (size_t)((c - t_start) / 1000000000ULL);
		if (sec < tl_len)
			t->tl[sec]++;
		if (c >= atomic_load_explicit(&m_start, memory_order_relaxed) &&
		    c < atomic_load_explicit(&m_end, memory_order_relaxed)) {
			uint64_t s = c - b;
			t->ops++;
			t->sum_sync += s;
			t->sum_write += b - a;
			t->sum_op += c - a;
			if (s > t->max_sync)
				t->max_sync = s;
			t->hist_sync[hidx(s)]++;
		}
	}
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
		"usage: atomicw --dir DIR --pattern overwrite|prealloc|hole|append [--threads T]\n"
		"  [--files 64] [--total 128G] [--unit 16384] [--warmup 10] [--duration 60]\n"
		"  [--seed 1] [--dev nvme0c0n1] [--fsync] [--tau] [--no-tau-check]\n"
		"  [--hist FILE] [--timeline FILE] [--label TEXT] [--prepare] [--csv-header]\n");
	exit(2);
}

static const char *csv_header =
	"pattern,threads,files,unit,ops,duration_s,iops,lat_mean_us,lat_p50_us,lat_p99_us,"
	"lat_p999_us,lat_max_us,write_mean_us,op_mean_us,dev_bytes_per_op,dev_writes_per_op,"
	"dev_flushes_per_op,exhausted,notes";

int main(int argc, char **argv)
{
	static struct option lo[] = {
		{ "dir", 1, 0, 'd' }, { "pattern", 1, 0, 'p' }, { "threads", 1, 0, 't' },
		{ "files", 1, 0, 'f' }, { "total", 1, 0, 'S' }, { "unit", 1, 0, 'u' },
		{ "warmup", 1, 0, 'w' }, { "duration", 1, 0, 'D' }, { "seed", 1, 0, 's' },
		{ "dev", 1, 0, 'v' }, { "fsync", 0, 0, 'F' }, { "tau", 0, 0, 'T' },
		{ "no-tau-check", 0, 0, 'N' }, { "hist", 1, 0, 'H' }, { "timeline", 1, 0, 'L' },
		{ "label", 1, 0, 'l' }, { "prepare", 0, 0, 'P' }, { "csv-header", 0, 0, 'C' },
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
		case 'T': o.tau = 1; break;
		case 'N': o.tau_check = 0; break;
		case 'H': o.hist_path = optarg; break;
		case 'L': o.tl_path = optarg; break;
		case 'l': o.label = optarg; break;
		case 'P': o.prepare = 1; break;
		case 'C': puts(csv_header); return 0;
		default: usage();
		}
	}
	if (!o.dir)
		usage();
	if (o.files < 1 || o.files > 4096 || o.threads < 1 || o.unit % 4096 || o.unit == 0)
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
	if (o.tau && o.tau_check)
		tau_check();

	if (o.pattern == P_OVERWRITE)
		check_files();
	else
		recreate_files();
	sync();

	struct thr *th = calloc((size_t)o.threads, sizeof(*th));
	for (int i = 0; i < o.threads; i++) {
		th[i].id = i;
		setup_thread(&th[i]);
	}
	pthread_barrier_init(&barrier, NULL, (unsigned)o.threads + 1);
	for (int i = 0; i < o.threads; i++)
		pthread_create(&th[i].tid, NULL, worker, &th[i]);

	uint64_t d0[17], d1[17];
	t_start = now_ns();
	atomic_store(&m_start, t_start + (uint64_t)o.warmup * 1000000000ULL);
	atomic_store(&m_end, t_start + (uint64_t)(o.warmup + o.duration) * 1000000000ULL);
	pthread_barrier_wait(&barrier);
	uint64_t ms = atomic_load(&m_start);
	sleep_until(ms);
	int warm_exhausted = atomic_load(&exhaust_ns) <= ms;
	int have_dev = read_devstat(d0) == 0;
	sleep_until(atomic_load(&m_end));
	read_devstat(d1);
	atomic_store(&stop_flag, 1);
	for (int i = 0; i < o.threads; i++)
		pthread_join(th[i].tid, NULL);

	uint64_t me = atomic_load(&m_end), ex = atomic_load(&exhaust_ns);
	double dur = me > ms ? (me - ms) / 1e9 : 0;
	uint64_t ops = 0, sum_sync = 0, sum_write = 0, sum_op = 0, max_sync = 0;
	uint64_t *hist = calloc(HBUCKETS, sizeof(uint64_t));
	size_t tl_len = (size_t)(o.warmup + o.duration + 30);
	uint64_t *tl = calloc(tl_len, sizeof(uint64_t));
	for (int i = 0; i < o.threads; i++) {
		ops += th[i].ops;
		sum_sync += th[i].sum_sync;
		sum_write += th[i].sum_write;
		sum_op += th[i].sum_op;
		if (th[i].max_sync > max_sync)
			max_sync = th[i].max_sync;
		for (int b = 0; b < HBUCKETS; b++)
			hist[b] += th[i].hist_sync[b];
		for (size_t s = 0; s < tl_len; s++)
			tl[s] += th[i].tl[s];
	}
	double pct[3] = { 0.50, 0.99, 0.999 }, pv[3] = { 0, 0, 0 };
	for (int k = 0; k < 3; k++) {
		uint64_t want = (uint64_t)(pct[k] * (double)ops), acc = 0;
		for (int b = 0; b < HBUCKETS; b++) {
			acc += hist[b];
			if (acc > want) {
				pv[k] = hmid(b);
				break;
			}
		}
	}
	double dev_bytes = 0, dev_writes = 0, dev_flush = 0;
	if (have_dev && ops) {
		dev_bytes = (double)(d1[6] - d0[6]) * 512.0 / (double)ops;
		dev_writes = (double)(d1[4] - d0[4]) / (double)ops;
		dev_flush = (double)(d1[15] - d0[15]) / (double)ops;
	}
	char notes[256] = "";
	if (warm_exhausted)
		snprintf(notes, sizeof(notes), "exhausted in warm-up");
	else if (ex != UINT64_MAX)
		snprintf(notes, sizeof(notes), "exhausted at %.1f s of the window", (ex - ms) / 1e9);
	if (o.use_fsync)
		strncat(notes, notes[0] ? "; fsync" : "fsync", sizeof(notes) - strlen(notes) - 1);
	if (o.tau)
		strncat(notes, notes[0] ? "; tau" : "tau", sizeof(notes) - strlen(notes) - 1);
	if (!have_dev)
		strncat(notes, notes[0] ? "; no devstat" : "no devstat", sizeof(notes) - strlen(notes) - 1);
	double n = ops ? (double)ops : 1;
	printf("%s,%d,%d,%" PRIu64 ",%" PRIu64 ",%.3f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,"
	       "%.0f,%.3f,%.4f,%d,%s\n",
	       pattern_names[o.pattern], o.threads, o.files, o.unit, ops, dur,
	       dur > 0 ? ops / dur : 0, sum_sync / n / 1e3, pv[0] / 1e3, pv[1] / 1e3, pv[2] / 1e3,
	       max_sync / 1e3, sum_write / n / 1e3, sum_op / n / 1e3, dev_bytes, dev_writes,
	       dev_flush, ex != UINT64_MAX, notes);
	if (o.hist_path) {
		FILE *f = fopen(o.hist_path, "w");
		if (f) {
			fprintf(f, "# fdatasync latency histogram (ns bucket midpoint, count)%s%s\n",
				o.label[0] ? ": " : "", o.label);
			for (int b = 0; b < HBUCKETS; b++)
				if (hist[b])
					fprintf(f, "%.0f %" PRIu64 "\n", hmid(b), hist[b]);
			fclose(f);
		}
	}
	if (o.tl_path) {
		FILE *f = fopen(o.tl_path, "w");
		if (f) {
			fprintf(f, "# second ops (warm-up %d s, window %d s)\n", o.warmup, o.duration);
			for (size_t s = 0; s < tl_len && s * 1000000000ULL < me - t_start + 1000000000ULL; s++)
				fprintf(f, "%zu %" PRIu64 "\n", s, tl[s]);
			fclose(f);
		}
	}
	return 0;
}
