/*
 * tauthp -- XFS tau with THP on (host/thp-test.sh): a tau block lives on an
 * order-0 folio, other files and read-only ranges may use large ones.
 *
 *   usage: tauthp plain    <path> <mb> <fileid> <gen> [from_mb] [fsync]
 *          tauthp read     <path> <from_mb> <to_mb>
 *          tauthp mmapread <path> <stopfile>
 *          tauthp tau      <path> <mb> <fileid> <gen>
 *          tauthp verify   <path> <mb> <fileid> <even_gen> <odd_gen> <odd_gen_hi> <split_mb>
 *          tauthp ops      <path> <ref> <seed> <nops> <max_mb>
 *
 * plain writes [from_mb, mb) through a plain fd in 1 MiB writes, which the
 * page cache backs with large folios.  read reads a range back the same way.
 * mmapread faults the whole file through a read-only mapping with
 * MADV_HUGEPAGE, drops it and does it again until <stopfile> exists.  tau
 * opens with O_TAU_UNTORN -- that open activates the file -- rewrites every
 * other 8 KiB page and fsyncs.
 *
 * Every 4 KiB block carries (fileid, block, gen) and a body derived from them.
 * verify expects the even 8 KiB pages at even_gen and the odd ones at odd_gen
 * below split_mb, odd_gen_hi from there on, and names what it finds instead:
 * ZERO, FOREIGN (another file or block), STALE (another generation), CORRUPT.
 *
 * ops applies the same random writes, truncates and hole punches to <path>
 * and to <ref> (a file on another file system), drops <path>'s page cache now
 * and then, compares ranges as it goes and the whole files at the end.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

#define BLK	4096
#define WORDS	(BLK / 8)
#define PAGE_SZ	8192
#define CHUNK	(1 << 20)
#define OPS_MAX	(4 << 20)
#define MAGIC	0x7461757468703031ULL	/* "tauthp01" */

static void die(const char *what)
{
	perror(what);
	exit(2);
}

static void *xalloc(size_t len)
{
	void *p = aligned_alloc(BLK, len);

	if (!p)
		die("aligned_alloc");
	return p;
}

static uint64_t mix(uint64_t x)
{
	x += 0x9e3779b97f4a7c15ULL;
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
	x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
	return x ^ (x >> 31);
}

static uint64_t body_seed(uint64_t fileid, uint64_t blk, uint64_t gen)
{
	return (fileid << 48) ^ (blk << 8) ^ gen;
}

static void stamp(uint64_t *w, uint64_t fileid, uint64_t blk, uint64_t gen)
{
	uint64_t s = body_seed(fileid, blk, gen);
	int i;

	w[0] = MAGIC;
	w[1] = fileid;
	w[2] = blk;
	w[3] = gen;
	for (i = 4; i < WORDS; i++)
		w[i] = mix(s + i);
}

static void pwrite_all(int fd, const void *buf, size_t len, off_t off)
{
	while (len) {
		ssize_t n = pwrite(fd, buf, len, off);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			die("pwrite");
		}
		buf = (const char *)buf + n;
		len -= n;
		off += n;
	}
}

/* bytes read, short only at EOF */
static size_t pread_full(int fd, void *buf, size_t len, off_t off)
{
	size_t done = 0;

	while (done < len) {
		ssize_t n = pread(fd, (char *)buf + done, len - done, off + done);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			die("pread");
		}
		if (n == 0)
			break;
		done += n;
	}
	return done;
}

static int do_plain(int argc, char **argv)
{
	const char *path = argv[2];
	long mb = atol(argv[3]), from = argc > 6 ? atol(argv[6]) : 0, m;
	uint64_t fileid = atol(argv[4]), gen = atol(argv[5]);
	int dosync = argc > 7 && !strcmp(argv[7], "fsync");
	uint64_t *buf = xalloc(CHUNK);
	int fd, b;

	fd = open(path, O_RDWR | O_CREAT, 0644);
	if (fd < 0)
		die(path);
	for (m = from; m < mb; m++) {
		for (b = 0; b < CHUNK / BLK; b++)
			stamp(buf + b * WORDS, fileid, (uint64_t)m * (CHUNK / BLK) + b, gen);
		pwrite_all(fd, buf, CHUNK, (off_t)m * CHUNK);
	}
	if (dosync && fsync(fd))
		die("fsync");
	close(fd);
	printf("plain %s: [%ld, %ld) MiB at gen %lu%s\n", path, from, mb,
	       (unsigned long)gen, dosync ? ", fsynced" : ", left dirty");
	return 0;
}

static int do_read(char **argv)
{
	const char *path = argv[2];
	long from = atol(argv[3]), to = atol(argv[4]), m;
	char *buf = xalloc(CHUNK);
	int fd;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		die(path);
	for (m = from; m < to; m++)
		pread_full(fd, buf, CHUNK, (off_t)m * CHUNK);
	close(fd);
	printf("read %s: [%ld, %ld) MiB\n", path, from, to);
	return 0;
}

static int do_mmapread(char **argv)
{
	const char *path = argv[2], *stop = argv[3];
	volatile unsigned long sum = 0;
	struct stat st;
	long passes = 0;
	off_t o;
	int fd;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		die(path);
	if (fstat(fd, &st))
		die("fstat");
	while (access(stop, F_OK)) {
		char *p = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);

		if (p == MAP_FAILED)
			die("mmap");
		madvise(p, st.st_size, MADV_HUGEPAGE);
		for (o = 0; o < st.st_size; o += BLK)
			sum += p[o];
		munmap(p, st.st_size);
		posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
		passes++;
	}
	close(fd);
	printf("mmapread %s: %ld passes\n", path, passes);
	return 0;
}

static int do_tau(char **argv)
{
	const char *path = argv[2];
	long mb = atol(argv[3]), pages = mb * (CHUNK / PAGE_SZ), p;
	uint64_t fileid = atol(argv[4]), gen = atol(argv[5]);
	uint64_t *buf = xalloc(PAGE_SZ);
	int fd;

	fd = open(path, O_RDWR | O_TAU_UNTORN);
	if (fd < 0)
		die(path);
	for (p = 0; p < pages; p += 2) {
		stamp(buf, fileid, 2 * p, gen);
		stamp(buf + WORDS, fileid, 2 * p + 1, gen);
		pwrite_all(fd, buf, PAGE_SZ, (off_t)p * PAGE_SZ);
	}
	if (fsync(fd))
		die("fsync");
	close(fd);
	printf("tau %s: %ld of %ld pages at gen %lu, fsynced\n", path,
	       (pages + 1) / 2, pages, (unsigned long)gen);
	return 0;
}

static int do_verify(char **argv)
{
	const char *path = argv[2];
	long mb = atol(argv[3]);
	uint64_t fileid = atol(argv[4]), even = atol(argv[5]);
	uint64_t odd = atol(argv[6]), odd_hi = atol(argv[7]);
	uint64_t split = (uint64_t)atol(argv[8]) * (CHUNK / BLK);
	uint64_t nblk = (uint64_t)mb * (CHUNK / BLK), blk, want;
	long zero = 0, foreign = 0, stale = 0, corrupt = 0, shown = 0;
	uint64_t *buf = xalloc(CHUNK), ref[WORDS];
	struct stat st;
	int fd, b, i;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		die(path);
	if (fstat(fd, &st))
		die("fstat");
	if (st.st_size != (off_t)mb * CHUNK) {
		printf("verify %s: SIZE %lld, want %lld\n", path,
		       (long long)st.st_size, (long long)mb * CHUNK);
		return 1;
	}
	for (blk = 0; blk < nblk; blk += CHUNK / BLK) {
		if (pread_full(fd, buf, CHUNK, blk * BLK) != CHUNK)
			die("short read");
		for (b = 0; b < CHUNK / BLK; b++) {
			uint64_t *w = buf + b * WORDS, n = blk + b;
			const char *what = NULL;

			want = (n / 2) % 2 == 0 ? even : n < split ? odd : odd_hi;
			for (i = 0; i < WORDS && !w[i]; i++)
				;
			if (i == WORDS) {
				zero++;
				what = "ZERO";
			} else if (w[0] != MAGIC) {
				corrupt++;
				what = "CORRUPT";
			} else if (w[1] != fileid || w[2] != n) {
				foreign++;
				what = "FOREIGN";
			} else {
				stamp(ref, fileid, n, w[3]);
				if (memcmp(w, ref, BLK)) {
					corrupt++;
					what = "CORRUPT";
				} else if (w[3] != want) {
					stale++;
					what = "STALE";
				}
			}
			if (what && shown++ < 5)
				printf("  block %lu: %s (found file %lu block %lu gen %lu, want gen %lu)\n",
				       (unsigned long)n, what, (unsigned long)w[1],
				       (unsigned long)w[2], (unsigned long)w[3],
				       (unsigned long)want);
		}
	}
	close(fd);
	printf("verify %s: %lu blocks, zero %ld, foreign %ld, stale %ld, corrupt %ld\n",
	       path, (unsigned long)nblk, zero, foreign, stale, corrupt);
	return zero || foreign || stale || corrupt;
}

static uint64_t rs;

static uint64_t rnd(void)
{
	rs = mix(rs);
	return rs;
}

static size_t pick_len(void)
{
	switch (rnd() % 4) {
	case 0:
		return 1 + rnd() % 8192;		/* small, unaligned */
	case 1:
		return BLK * (1 + rnd() % 16);		/* a few blocks */
	case 2:
		return BLK * (1 + rnd() % (OPS_MAX / BLK));	/* up to 4 MiB, aligned */
	default:
		return 1 + rnd() % OPS_MAX;		/* up to 4 MiB, unaligned */
	}
}

static int same_range(int fd, int rf, off_t off, size_t len, char *a, char *b)
{
	size_t x = pread_full(fd, a, len, off), y = pread_full(rf, b, len, off);

	return x == y && !memcmp(a, b, x);
}

static int do_ops(char **argv)
{
	const char *path = argv[2], *refpath = argv[3];
	long nops = atol(argv[5]), i, nw = 0, nt = 0, np = 0, nd = 0, nr = 0;
	off_t max = (off_t)atol(argv[6]) << 20, off;
	char *buf = xalloc(OPS_MAX), *a = xalloc(OPS_MAX), *b = xalloc(OPS_MAX);
	struct stat s1, s2;
	size_t len, k;
	int fd, rf;

	rs = strtoull(argv[4], NULL, 0);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		die(path);
	rf = open(refpath, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (rf < 0)
		die(refpath);
	for (i = 0; i < nops; i++) {
		unsigned int op = rnd() % 100;

		off = rnd() % max;
		len = pick_len();
		if (off + (off_t)len > max)
			len = max - off;
		if (!len)
			continue;
		if (op < 55) {
			for (k = 0; k < len; k += 8) {
				uint64_t v = rnd();

				memcpy(buf + k, &v, len - k < 8 ? len - k : 8);
			}
			pwrite_all(fd, buf, len, off);
			pwrite_all(rf, buf, len, off);
			nw++;
		} else if (op < 65) {
			if (ftruncate(fd, off) || ftruncate(rf, off))
				die("ftruncate");
			nt++;
		} else if (op < 75) {
			if (fallocate(fd, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, off, len) ||
			    fallocate(rf, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE, off, len))
				die("punch");
			np++;
		} else if (op < 80) {
			if (fdatasync(fd))
				die("fdatasync");
			posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
			nd++;
		} else {
			if (!same_range(fd, rf, off, len, a, b)) {
				printf("ops %s: MISMATCH at op %ld, %zu bytes at %lld\n",
				       path, i, len, (long long)off);
				return 1;
			}
			nr++;
		}
	}
	if (fsync(fd) || fsync(rf))
		die("fsync");
	if (fstat(fd, &s1) || fstat(rf, &s2))
		die("fstat");
	if (s1.st_size != s2.st_size) {
		printf("ops %s: SIZE %lld, the reference %lld\n", path,
		       (long long)s1.st_size, (long long)s2.st_size);
		return 1;
	}
	for (off = 0; off < s1.st_size; off += OPS_MAX)
		if (!same_range(fd, rf, off, OPS_MAX, a, b)) {
			printf("ops %s: MISMATCH in the final compare at %lld\n",
			       path, (long long)off);
			return 1;
		}
	close(fd);
	close(rf);
	printf("ops %s: %ld writes, %ld truncates, %ld punches, %ld cache drops, %ld reads, %lld bytes -- same as the reference\n",
	       path, nw, nt, np, nd, nr, (long long)s1.st_size);
	return 0;
}

static void usage(const char *me)
{
	fprintf(stderr,
		"usage: %s plain    <path> <mb> <fileid> <gen> [from_mb] [fsync]\n"
		"       %s read     <path> <from_mb> <to_mb>\n"
		"       %s mmapread <path> <stopfile>\n"
		"       %s tau      <path> <mb> <fileid> <gen>\n"
		"       %s verify   <path> <mb> <fileid> <even_gen> <odd_gen> <odd_gen_hi> <split_mb>\n"
		"       %s ops      <path> <ref> <seed> <nops> <max_mb>\n",
		me, me, me, me, me, me);
	exit(2);
}

int main(int argc, char **argv)
{
	if (argc < 2)
		usage(argv[0]);
	if (!strcmp(argv[1], "plain") && argc >= 6)
		return do_plain(argc, argv);
	if (!strcmp(argv[1], "read") && argc == 5)
		return do_read(argv);
	if (!strcmp(argv[1], "mmapread") && argc == 4)
		return do_mmapread(argv);
	if (!strcmp(argv[1], "tau") && argc == 6)
		return do_tau(argv);
	if (!strcmp(argv[1], "verify") && argc == 9)
		return do_verify(argv);
	if (!strcmp(argv[1], "ops") && argc == 7)
		return do_ops(argv);
	usage(argv[0]);
	return 2;
}
