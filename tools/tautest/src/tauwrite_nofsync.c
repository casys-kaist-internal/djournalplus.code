// SPDX-License-Identifier: GPL-2.0
/*
 * tauwrite_nofsync - same as tauwrite, but closes without fsync.
 *
 * Negative control: nothing was promised to the application, so after a crash
 * this file may hold the new data, the old data, or nothing at all. The test
 * only checks that it does not corrupt anything else and that recovery does
 * not trip on it.
 *
 *   usage: tauwrite_nofsync <path> <size> <seed> [offset]
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

int main(int argc, char **argv)
{
	const char *path;
	size_t size;
	int seed, fd;
	off_t off;
	char *buf;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <path> <size> <seed> [offset]\n", argv[0]);
		return 2;
	}
	path = argv[1];
	size = strtoul(argv[2], NULL, 0);
	seed = atoi(argv[3]);
	off = argc > 4 ? strtoll(argv[4], NULL, 0) : 0;

	fd = open(path, O_CREAT | O_RDWR | O_TAU_UNTORN, 0644);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	buf = malloc(size);
	if (!buf) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	memset(buf, seed & 0xff, size);

	if (pwrite(fd, buf, size, off) != (ssize_t)size) {
		perror("pwrite");
		return 1;
	}
	close(fd);	/* deliberately no fsync */

	printf("NOFSYNC %s size=%zu seed=%d off=%lld\n",
	       path, size, seed, (long long)off);
	return 0;
}
