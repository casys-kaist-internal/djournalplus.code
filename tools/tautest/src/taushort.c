// SPDX-License-Identifier: GPL-2.0
/*
 * taushort - a write whose source buffer faults partway.
 *
 * The page after the first <head> bytes of the source is PROT_NONE, so the
 * kernel's copy stops there: a short copy into a block the page cache has
 * not read.  The rest of that block must keep the file's old data.
 *
 *   usage: taushort <path> <offset> <head> <seed>
 *
 * Exits 0 if pwrite() wrote exactly <head> bytes, and fsyncs either way.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

int main(int argc, char **argv)
{
	long pg = sysconf(_SC_PAGESIZE);
	size_t head;
	off_t off;
	ssize_t n;
	char *buf;
	int fd;

	if (argc < 5) {
		fprintf(stderr, "usage: %s <path> <offset> <head> <seed>\n", argv[0]);
		return 2;
	}
	off = strtoll(argv[2], NULL, 0);
	head = strtoul(argv[3], NULL, 0);
	if (head == 0 || head >= (size_t)pg) {
		fprintf(stderr, "head must be in (0, %ld)\n", pg);
		return 2;
	}

	buf = mmap(NULL, 2 * pg, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (buf == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	memset(buf, atoi(argv[4]) & 0xff, pg);
	if (mprotect(buf + pg, pg, PROT_NONE)) {
		perror("mprotect");
		return 1;
	}

	fd = open(argv[1], O_RDWR | O_TAU_UNTORN);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	n = pwrite(fd, buf + pg - head, pg, off);
	printf("pwrite returned %zd (want %zu)\n", n, head);
	if (fsync(fd)) {
		perror("fsync");
		return 1;
	}
	close(fd);
	return n == (ssize_t)head ? 0 : 1;
}
