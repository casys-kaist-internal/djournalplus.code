// SPDX-License-Identifier: GPL-2.0
/*
 * tauappend - append records to a file and report throughput and latency.
 *
 * Appending is the shape a write-ahead log has, and it is the one that pushes
 * tau hardest: every record lands in blocks that did not exist yet, so the
 * delayed-allocation path and the commit-time allocation that follows it are
 * on the critical path of the fsync.
 *
 *   usage: tauappend <path> <record-bytes> <count> <fsync-every> <0|1 tau>
 *
 *   fsync-every 1 = fsync after every record (WAL-like)
 *               N = batch N records per fsync
 *               0 = never fsync (buffered only, closed at the end)
 *   tau         1 = open with O_TAU_UNTORN so taujournal owns the file
 *
 * Prints: MB/s, records/s, and p50/p99/max fsync (or write) latency.
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

static int cmp_u64(const void *a, const void *b)
{
	unsigned long long x = *(const unsigned long long *)a;
	unsigned long long y = *(const unsigned long long *)b;
	return (x > y) - (x < y);
}

static unsigned long long now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (unsigned long long)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

int main(int argc, char **argv)
{
	const char *path;
	size_t rec;
	long count, every;
	int use_tau, fd, flags;
	char *buf;
	unsigned long long *lat, start, t0, total_ns;
	long nlat = 0, i;
	double secs, mb;

	if (argc < 6) {
		fprintf(stderr,
			"usage: %s <path> <record-bytes> <count> <fsync-every> <0|1 tau>\n",
			argv[0]);
		return 2;
	}
	path = argv[1];
	rec = strtoul(argv[2], NULL, 0);
	count = strtol(argv[3], NULL, 0);
	every = strtol(argv[4], NULL, 0);
	use_tau = atoi(argv[5]);

	flags = O_CREAT | O_WRONLY | O_APPEND | O_TRUNC;
	if (use_tau)
		flags |= O_TAU_UNTORN;

	fd = open(path, flags, 0644);
	if (fd < 0) {
		perror("open");
		return 1;
	}

	buf = malloc(rec);
	lat = malloc(sizeof(*lat) * (count + 1));
	if (!buf || !lat) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	memset(buf, 0x5a, rec);

	start = now_ns();
	for (i = 0; i < count; i++) {
		t0 = now_ns();
		if (write(fd, buf, rec) != (ssize_t)rec) {
			perror("write");
			return 1;
		}
		if (every > 0 && ((i + 1) % every) == 0) {
			if (fdatasync(fd)) {
				perror("fdatasync");
				return 1;
			}
		}
		/* Latency of the durable unit: a batch when batching, else the
		 * write+fsync pair. Without fsync it is just the write. */
		if (every <= 0 || ((i + 1) % every) == 0)
			lat[nlat++] = now_ns() - t0;
	}
	if (every == 0 && fdatasync(fd)) {	/* one flush so the data is on disk */
		perror("fdatasync");
		return 1;
	}
	total_ns = now_ns() - start;
	close(fd);

	secs = total_ns / 1e9;
	mb = (double)rec * count / (1024 * 1024);
	qsort(lat, nlat, sizeof(*lat), cmp_u64);

	printf("%.1f MB/s  %.0f rec/s  p50=%.3fms p99=%.3fms max=%.3fms\n",
	       mb / secs, count / secs,
	       nlat ? lat[nlat / 2] / 1e6 : 0.0,
	       nlat ? lat[(long)(nlat * 0.99)] / 1e6 : 0.0,
	       nlat ? lat[nlat - 1] / 1e6 : 0.0);
	return 0;
}
