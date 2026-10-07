// SPDX-License-Identifier: GPL-2.0
/*
 * tauabort - write until the tau journal aborts, then check what recovery kept.
 *
 *   tauabort run <dir> <files> <pages> <secs> <ackdir>
 *       One writer per file: 8 KiB pages, each stamped (file, page, generation)
 *       with a checksum in both 4 KiB halves.  Appends and overwrites, an fsync
 *       every 4 writes.  A page is acked at the generation of the last write an
 *       fsync covered.  Stops at the first error and saves the acks to
 *       <ackdir>/ack.<n>; prints how each writer ended.
 *
 *   tauabort verify <dir> <files> <pages> <ackdir>
 *       Every page must be all zero or one whole stamp (no torn page, no
 *       foreign data), and an acked page must be at its acked generation or
 *       later.  Exit 0 when all hold.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

#define PAGE	8192
#define HALF	4096
#define MAGIC	0x7a0b0a7dU
#define BATCH	4

struct stamp {
	uint32_t magic, file, page, gen, sum;
};

static const char *dir, *ackdir;
static int nfiles, npages, secs;

static uint32_t sum32(const unsigned char *p, size_t n)
{
	uint32_t h = 2166136261u;

	while (n--)
		h = (h ^ *p++) * 16777619u;
	return h;
}

static void fill(unsigned char *buf, int file, int page, uint32_t gen)
{
	for (int h = 0; h < 2; h++) {
		unsigned char *b = buf + h * HALF;
		struct stamp st = { MAGIC, file, page, gen, 0 };

		for (int i = sizeof(st); i < HALF; i++)
			b[i] = (unsigned char)(gen * 131 + page * 7 + file + i + h);
		st.sum = sum32(b + sizeof(st), HALF - sizeof(st));
		memcpy(b, &st, sizeof(st));
	}
}

/* 0: zero page, 1: whole stamp (*gen set), -1: torn or foreign */
static int check(const unsigned char *buf, int file, int page, uint32_t *gen)
{
	struct stamp s[2];
	int zero = 1;

	for (int i = 0; i < PAGE; i++)
		if (buf[i]) {
			zero = 0;
			break;
		}
	if (zero)
		return 0;
	for (int h = 0; h < 2; h++) {
		const unsigned char *b = buf + h * HALF;

		memcpy(&s[h], b, sizeof(s[h]));
		if (s[h].magic != MAGIC || s[h].file != (uint32_t)file ||
		    s[h].page != (uint32_t)page ||
		    s[h].sum != sum32(b + sizeof(s[h]), HALF - sizeof(s[h])))
			return -1;
	}
	if (s[0].gen != s[1].gen)
		return -1;
	*gen = s[0].gen;
	return 1;
}

static void *writer(void *arg)
{
	int n = (int)(long)arg, fd, pending[BATCH], np = 0, size = 0;
	uint32_t *ack = calloc(npages, sizeof(*ack)), gen = 0;
	uint32_t pgen[BATCH];
	unsigned char *buf = aligned_alloc(4096, PAGE);
	unsigned int seed = n * 7919 + 1;
	long writes = 0, fsyncs = 0;
	const char *how = "time";
	char path[512];
	time_t end = time(NULL) + secs;
	int err = 0;

	snprintf(path, sizeof(path), "%s/f%d", dir, n);
	fd = open(path, O_CREAT | O_RDWR | O_TAU_UNTORN, 0644);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", path, strerror(errno));
		return (void *)1L;
	}
	while (time(NULL) < end) {
		int page = (size < npages && (rand_r(&seed) % 3 == 0 || size == 0)) ?
			   size : rand_r(&seed) % (size ? size : 1);

		fill(buf, n, page, ++gen);
		if (pwrite(fd, buf, PAGE, (off_t)page * PAGE) != PAGE) {
			err = errno;
			how = "write";
			break;
		}
		writes++;
		if (page == size)
			size++;
		pending[np] = page;
		pgen[np++] = gen;
		if (np == BATCH) {
			if (fsync(fd)) {
				err = errno;
				how = "fsync";
				break;
			}
			fsyncs++;
			for (int i = 0; i < np; i++)
				if (pgen[i] > ack[pending[i]])
					ack[pending[i]] = pgen[i];
			np = 0;
		}
	}
	close(fd);

	snprintf(path, sizeof(path), "%s/ack.%d", ackdir, n);
	FILE *f = fopen(path, "w");
	if (f) {
		fwrite(ack, sizeof(*ack), npages, f);
		fclose(f);
	}
	printf("writer %d: stopped at %s (%s) after %ld writes, %ld fsyncs\n",
	       n, how, err ? strerror(err) : "no error", writes, fsyncs);
	free(ack);
	free(buf);
	return (void *)(long)(err == EIO ? 0 : err ? 2 : 3);
}

static int verify(void)
{
	unsigned char *buf = aligned_alloc(4096, PAGE);
	uint32_t *ack = calloc(npages, sizeof(*ack));
	long torn = 0, stale = 0, zero_acked = 0, ok = 0;

	for (int n = 0; n < nfiles; n++) {
		char path[512];
		FILE *f;
		int fd;

		memset(ack, 0, npages * sizeof(*ack));
		snprintf(path, sizeof(path), "%s/ack.%d", ackdir, n);
		f = fopen(path, "r");
		if (f) {
			if (fread(ack, sizeof(*ack), npages, f) != (size_t)npages)
				fprintf(stderr, "short ack file %s\n", path);
			fclose(f);
		}
		snprintf(path, sizeof(path), "%s/f%d", dir, n);
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			fprintf(stderr, "open %s: %s\n", path, strerror(errno));
			return 1;
		}
		for (int p = 0; p < npages; p++) {
			ssize_t r = pread(fd, buf, PAGE, (off_t)p * PAGE);
			uint32_t gen = 0;
			int c;

			if (r <= 0) {
				if (ack[p]) {
					printf("f%d page %d: acked gen %u but past EOF\n", n, p, ack[p]);
					zero_acked++;
				}
				continue;
			}
			if (r < PAGE)
				memset(buf + r, 0, PAGE - r);
			c = check(buf, n, p, &gen);
			if (c < 0) {
				printf("f%d page %d: torn or foreign\n", n, p);
				torn++;
			} else if (c == 0 && ack[p]) {
				printf("f%d page %d: acked gen %u, reads zero\n", n, p, ack[p]);
				zero_acked++;
			} else if (c > 0 && gen < ack[p]) {
				printf("f%d page %d: gen %u older than acked %u\n", n, p, gen, ack[p]);
				stale++;
			} else
				ok++;
		}
		close(fd);
	}
	printf("verify: ok %ld, torn %ld, stale %ld, acked-but-zero %ld\n",
	       ok, torn, stale, zero_acked);
	return torn || stale || zero_acked;
}

int main(int argc, char **argv)
{
	if (argc < 6) {
		fprintf(stderr, "usage: %s run <dir> <files> <pages> <secs> <ackdir>\n"
			"       %s verify <dir> <files> <pages> <ackdir>\n", argv[0], argv[0]);
		return 2;
	}
	dir = argv[2];
	nfiles = atoi(argv[3]);
	npages = atoi(argv[4]);
	if (!strcmp(argv[1], "verify")) {
		ackdir = argv[5];
		return verify();
	}
	if (argc < 7)
		return 2;
	secs = atoi(argv[5]);
	ackdir = argv[6];

	pthread_t t[nfiles];
	int rc = 0;

	for (long n = 0; n < nfiles; n++)
		pthread_create(&t[n], NULL, writer, (void *)n);
	for (int n = 0; n < nfiles; n++) {
		void *r;

		pthread_join(t[n], &r);
		if ((long)r > rc)
			rc = (int)(long)r;
	}
	/* 0: every writer stopped on EIO; 3: some ran out the clock */
	return rc;
}
