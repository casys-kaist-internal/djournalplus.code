// SPDX-License-Identifier: GPL-2.0
/*
 * tauwrite - write a byte pattern to a tau-activated file and fsync it.
 *
 * The file is opened with O_TAU_UNTORN so taujournal takes ownership of it.
 * Every block written here is expected to survive a crash: after recovery the
 * file must read back as the exact pattern this wrote.
 *
 *   usage: tauwrite <path> <size> <seed> [offset]
 *
 *   seed is the byte value the region is filled with (0-255), so the expected
 *   content after recovery is simply <size> copies of <seed> at <offset>.
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
	if (fsync(fd)) {
		perror("fsync");
		return 1;
	}
	close(fd);

	printf("OK %s size=%zu seed=%d off=%lld\n",
	       path, size, seed, (long long)off);
	return 0;
}
