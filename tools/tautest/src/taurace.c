// SPDX-License-Identifier: GPL-2.0
/*
 * taurace - hammer one range with a writer thread and an fsync thread.
 *
 * This is the workload that exercises write-during-commit: a rewrite that
 * lands while a commit is in flight puts the buffer in BH_TauPending, and the
 * buffer states that follow (revoke, re-journal, checkpoint coalesce) are the
 * ones that were historically broken.
 *
 * It ends with a settled write of 0x2a plus fsync, so the expected content
 * after a crash is deterministic: <size> copies of 0x2a.
 *
 *   usage: taurace <path> <size> <seconds>
 *          taurace <path> <size> settle     (the settled write alone)
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#ifndef O_TAU_UNTORN
#define O_TAU_UNTORN 040000000
#endif

#define SETTLED_BYTE 0x2a

static int fd;
static size_t size;
static volatile int stop;

static void *writer(void *arg)
{
	unsigned char *buf = malloc(size);
	unsigned int gen = 0;

	if (!buf)
		return NULL;
	while (!stop) {
		/* keep the pattern away from SETTLED_BYTE so a stale generation
		 * surviving recovery is obvious in a byte histogram */
		memset(buf, 0x80 | (gen++ & 0x3f), size);
		if (pwrite(fd, buf, size, 0) != (ssize_t)size) {
			perror("pwrite");
			break;
		}
	}
	free(buf);
	return NULL;
}

static void *syncer(void *arg)
{
	while (!stop) {
		if (fsync(fd)) {
			perror("fsync");
			break;
		}
	}
	return NULL;
}

int main(int argc, char **argv)
{
	pthread_t t_writer, t_syncer;
	unsigned char *buf;
	const char *path;
	int seconds;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <path> <size> <seconds>\n", argv[0]);
		return 2;
	}
	path = argv[1];
	size = strtoul(argv[2], NULL, 0);
	seconds = atoi(argv[3]);

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
	if (!strcmp(argv[3], "settle"))
		goto settle;

	/* establish the file first so the race runs against existing blocks */
	memset(buf, 1, size);
	if (pwrite(fd, buf, size, 0) != (ssize_t)size) {
		perror("pwrite");
		return 1;
	}
	if (fsync(fd)) {
		perror("fsync");
		return 1;
	}

	pthread_create(&t_writer, NULL, writer, NULL);
	pthread_create(&t_syncer, NULL, syncer, NULL);
	sleep(seconds);
	stop = 1;
	pthread_join(t_writer, NULL);
	pthread_join(t_syncer, NULL);

settle:
	/* settle: the last thing on disk must be this, fsync-acked */
	memset(buf, SETTLED_BYTE, size);
	if (pwrite(fd, buf, size, 0) != (ssize_t)size) {
		perror("pwrite");
		return 1;
	}
	if (fsync(fd)) {
		perror("fsync");
		return 1;
	}
	close(fd);

	printf("RACE done %s size=%zu settled=0x%02x\n", path, size, SETTLED_BYTE);
	return 0;
}
