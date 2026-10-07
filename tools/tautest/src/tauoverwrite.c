// SPDX-License-Identifier: GPL-2.0
/*
 * tauoverwrite - rewrite blocks that already exist, and report what it costs.
 *
 * This is the case tau's undo-redo hybrid is built for. The first dirty of a
 * block goes through the journal, but once it is anchored a rewrite goes
 * straight to its original location and only a small revoke tag is journaled.
 * So unlike an append, a steady stream of overwrites should approach the same
 * device write volume as a plain filesystem.
 *
 *   tauoverwrite setup <path> <file-bytes> <tau>
 *       create and fill the file, then fsync. Run this before measuring so the
 *       journaled first-write is not counted.
 *
 *   tauoverwrite run <path> <file-bytes> <io-bytes> <count> <fsync-every>
 *                    <seq|rand> <tau>
 *       rewrite <count> regions of <io-bytes>, sequentially wrapping or at
 *       random offsets, fsyncing every <fsync-every> writes (0 = only at end).
 *
 * <tau> 1 opens with O_TAU_UNTORN so taujournal owns the file.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

static unsigned long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long long)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static int cmp_u64(const void *a, const void *b)
{
	unsigned long long x = *(const unsigned long long *)a;
	unsigned long long y = *(const unsigned long long *)b;
	return (x > y) - (x < y);
}

static int open_file(const char *path, int use_tau, int create)
{
	int flags = O_WRONLY | (create ? (O_CREAT | O_TRUNC) : 0);

	if (use_tau)
		flags |= O_TAU_UNTORN;
	return open(path, flags, 0644);
}

static int do_setup(char **argv)
{
	const char *path = argv[2];
	size_t size = strtoul(argv[3], NULL, 0);
	int use_tau = atoi(argv[4]);
	size_t chunk = 1024 * 1024, done = 0;
	char *buf;
	int fd;

	fd = open_file(path, use_tau, 1);
	if (fd < 0) { perror("open"); return 1; }
	buf = malloc(chunk);
	if (!buf) { fprintf(stderr, "out of memory\n"); return 1; }
	memset(buf, 0x11, chunk);

	while (done < size) {
		size_t n = size - done < chunk ? size - done : chunk;

		if (pwrite(fd, buf, n, done) != (ssize_t)n) { perror("pwrite"); return 1; }
		done += n;
	}
	if (fsync(fd)) { perror("fsync"); return 1; }
	close(fd);
	printf("setup %s %zu bytes\n", path, size);
	return 0;
}

static int do_run(char **argv)
{
	const char *path = argv[2];
	size_t fsize = strtoul(argv[3], NULL, 0);
	size_t iosize = strtoul(argv[4], NULL, 0);
	long count = strtol(argv[5], NULL, 0);
	long every = strtol(argv[6], NULL, 0);
	int rand_mode = strcmp(argv[7], "rand") == 0;
	int use_tau = atoi(argv[8]);
	unsigned long long *lat, start, t0, total;
	long nlat = 0, i, nslots;
	char *buf;
	double secs, mb;
	int fd;

	if (iosize > fsize) { fprintf(stderr, "io larger than file\n"); return 2; }
	nslots = fsize / iosize;

	fd = open_file(path, use_tau, 0);
	if (fd < 0) { perror("open"); return 1; }
	buf = malloc(iosize);
	lat = malloc(sizeof(*lat) * (count + 1));
	if (!buf || !lat) { fprintf(stderr, "out of memory\n"); return 1; }
	memset(buf, 0x22, iosize);
	/* TAU_SEED: per-process seed so N concurrent runs do not hit the same offsets */
	srandom(getenv("TAU_SEED") ? (unsigned)atol(getenv("TAU_SEED")) : 12345);

	start = now_ns();
	for (i = 0; i < count; i++) {
		off_t off = (rand_mode ? (random() % nslots) : (i % nslots)) * (off_t)iosize;

		t0 = now_ns();
		if (pwrite(fd, buf, iosize, off) != (ssize_t)iosize) { perror("pwrite"); return 1; }
		if (every > 0 && ((i + 1) % every) == 0) {
			if (fdatasync(fd)) { perror("fdatasync"); return 1; }
		}
		if (every <= 0 || ((i + 1) % every) == 0)
			lat[nlat++] = now_ns() - t0;
	}
	if (every == 0 && fdatasync(fd)) { perror("fdatasync"); return 1; }
	total = now_ns() - start;
	close(fd);

	secs = total / 1e9;
	mb = (double)iosize * count / (1024 * 1024);
	qsort(lat, nlat, sizeof(*lat), cmp_u64);
	printf("%.1f MB/s  %.0f ops/s  p50=%.3fms p99=%.3fms max=%.3fms\n",
	       mb / secs, count / secs,
	       nlat ? lat[nlat / 2] / 1e6 : 0.0,
	       nlat ? lat[(long)(nlat * 0.99)] / 1e6 : 0.0,
	       nlat ? lat[nlat - 1] / 1e6 : 0.0);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc >= 5 && strcmp(argv[1], "setup") == 0)
		return do_setup(argv);
	if (argc >= 9 && strcmp(argv[1], "run") == 0)
		return do_run(argv);

	fprintf(stderr,
		"usage: %s setup <path> <file-bytes> <tau>\n"
		"       %s run <path> <file-bytes> <io-bytes> <count> <fsync-every> <seq|rand> <tau>\n",
		argv[0], argv[0]);
	return 2;
}
