// SPDX-License-Identifier: GPL-2.0
/*
 * taukill - a write SIGKILLed part way must leave the file all old or all new.
 *
 * Every 4 KiB block of a write carries the write's generation and its block
 * index, so a file read back after the writer died shows whether the write
 * stopped half way.
 *
 *   taukill prep  <path> <size>       size bytes of gen 0, fsync'd
 *   taukill race  <path> <size>       pwrite gen 1, 2, ... over [0, size) until killed
 *   taukill uffd  <path> <size>       pwrite gen 1 from a buffer whose first page is
 *                                     there and the rest behind a userfaultfd that never
 *                                     answers; prints BLOCKED once the kernel waits on it
 *   taukill check <path> <size>       UNIFORM gen=G (exit 0) or TORN (exit 1)
 *   taukill bench <path> <size> <span> <count>
 *                                     ns per pwrite of size bytes, rotating over span
 *                                     bytes of the file (no fsync): the write path's cost
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

#define BS 4096
#define MAGIC 0x74616b696c6cULL	/* "takill" */

struct stamp {
	uint64_t magic;
	uint64_t gen;
	uint64_t blk;
};

static void fill(char *buf, size_t size, uint64_t gen)
{
	for (size_t b = 0; b < size / BS; b++) {
		struct stamp s = { MAGIC, gen, b };
		char *p = buf + b * BS;

		memset(p, (int)(gen & 0xff), BS);
		memcpy(p, &s, sizeof(s));
	}
}

static int open_tau(const char *path, int flags)
{
	int fd = open(path, flags | O_TAU_UNTORN, 0644);

	if (fd < 0) {
		perror(path);
		exit(2);
	}
	return fd;
}

static int do_prep(const char *path, size_t size)
{
	char *buf = aligned_alloc(BS, size);
	int fd = open_tau(path, O_CREAT | O_TRUNC | O_RDWR);

	fill(buf, size, 0);
	if (pwrite(fd, buf, size, 0) != (ssize_t)size || fsync(fd)) {
		perror("prep");
		return 2;
	}
	return 0;
}

static int do_race(const char *path, size_t size)
{
	char *buf = aligned_alloc(BS, size);
	int fd = open_tau(path, O_RDWR);

	mlock(buf, size);
	for (uint64_t gen = 1;; gen++) {
		fill(buf, size, gen);
		if (pwrite(fd, buf, size, 0) != (ssize_t)size) {
			perror("race pwrite");
			return 2;
		}
	}
}

static void *uffd_wait(void *arg)
{
	int uffd = (int)(long)arg;
	struct pollfd p = { .fd = uffd, .events = POLLIN };
	struct uffd_msg msg;

	/* the kernel waits on the first missing page: say so, never answer */
	if (poll(&p, 1, -1) == 1 && read(uffd, &msg, sizeof(msg)) == sizeof(msg) &&
	    msg.event == UFFD_EVENT_PAGEFAULT) {
		printf("BLOCKED at +%llu\n",
		       (unsigned long long)(msg.arg.pagefault.address & ~(BS - 1ULL)));
		fflush(stdout);
	}
	pause();
	return NULL;
}

static int do_uffd(const char *path, size_t size)
{
	struct uffdio_api api = { .api = UFFD_API };
	struct uffdio_register reg;
	pthread_t t;
	char *buf;
	int fd = open_tau(path, O_RDWR);
	int uffd = syscall(SYS_userfaultfd, O_CLOEXEC);
	ssize_t n;

	if (uffd < 0 || ioctl(uffd, UFFDIO_API, &api)) {
		perror("userfaultfd (needs root or vm.unprivileged_userfaultfd)");
		return 2;
	}
	buf = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (buf == MAP_FAILED) {
		perror("mmap");
		return 2;
	}
	/* first page there with gen 1; the others missing, behind the uffd */
	fill(buf, BS, 1);
	reg.range.start = (unsigned long)buf + BS;
	reg.range.len = size - BS;
	reg.mode = UFFDIO_REGISTER_MODE_MISSING;
	if (ioctl(uffd, UFFDIO_REGISTER, &reg)) {
		perror("UFFDIO_REGISTER");
		return 2;
	}
	pthread_create(&t, NULL, uffd_wait, (void *)(long)uffd);
	n = pwrite(fd, buf, size, 0);
	printf("pwrite returned %zd (errno %d)\n", n, n < 0 ? errno : 0);
	return 3;
}

static int do_check(const char *path, size_t size)
{
	char *buf = aligned_alloc(BS, size);
	int fd = open(path, O_RDONLY);
	uint64_t g0 = UINT64_MAX;
	size_t bad = 0, other = 0;

	if (fd < 0 || pread(fd, buf, size, 0) != (ssize_t)size) {
		perror("check read");
		return 2;
	}
	for (size_t b = 0; b < size / BS; b++) {
		struct stamp s;
		const unsigned char *p = (unsigned char *)buf + b * BS;
		size_t i;

		memcpy(&s, p, sizeof(s));
		for (i = sizeof(s); i < BS && p[i] == (s.gen & 0xff); i++)
			;
		if (s.magic != MAGIC || s.blk != b || i != BS) {
			if (!bad++)
				printf("  block %zu: not a whole stamped block\n", b);
			continue;
		}
		if (g0 == UINT64_MAX)
			g0 = s.gen;
		else if (s.gen != g0 && !other++)
			printf("  block %zu: gen %llu, block 0 gen %llu\n", b,
			       (unsigned long long)s.gen, (unsigned long long)g0);
	}
	if (bad || other) {
		printf("TORN: %zu blocks of another gen, %zu bad\n", other, bad);
		return 1;
	}
	printf("UNIFORM gen=%llu\n", (unsigned long long)g0);
	return 0;
}

static int do_bench(const char *path, size_t size, size_t span, long count)
{
	char *buf = aligned_alloc(BS, size);
	int fd = open_tau(path, O_CREAT | O_RDWR);
	struct timespec a, b;
	size_t slots = span / size;

	fill(buf, size, 7);
	for (size_t o = 0; o < span; o += size)	/* the file exists, cached */
		if (pwrite(fd, buf, size, o) != (ssize_t)size)
			return 2;
	clock_gettime(CLOCK_MONOTONIC, &a);
	for (long i = 0; i < count; i++)
		if (pwrite(fd, buf, size, (off_t)((i * 7919) % slots) * size) != (ssize_t)size) {
			perror("bench pwrite");
			return 2;
		}
	clock_gettime(CLOCK_MONOTONIC, &b);
	printf("BENCH size=%zu ns/write=%.0f\n", size,
	       ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / count);
	return 0;
}

int main(int argc, char **argv)
{
	size_t size;

	if (argc < 4)
		goto usage;
	size = strtoul(argv[3], NULL, 0);
	if (!size || size % BS)
		goto usage;
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (!strcmp(argv[1], "prep"))
		return do_prep(argv[2], size);
	if (!strcmp(argv[1], "race"))
		return do_race(argv[2], size);
	if (!strcmp(argv[1], "uffd"))
		return do_uffd(argv[2], size);
	if (!strcmp(argv[1], "check"))
		return do_check(argv[2], size);
	if (!strcmp(argv[1], "bench") && argc >= 6)
		return do_bench(argv[2], size, strtoul(argv[4], NULL, 0), atol(argv[5]));
usage:
	fprintf(stderr, "usage: %s prep|race|uffd|check <path> <size, 4 KiB multiple> | bench <path> <size> <span> <count>\n", argv[0]);
	return 2;
}
