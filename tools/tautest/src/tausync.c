// SPDX-License-Identifier: GPL-2.0
/*
 * tausync - write a tau file and make it durable with something other than fsync.
 *
 * fsync(2) on a tau file goes through ext4_tau_sync_file/xfs_tau_sync_file,
 * which commit the tau transaction directly. sync(2) and syncfs(2) do not:
 * they go through sync_inodes_sb(), which hands the writeback off to a bdi
 * kworker. Whether the tau transaction is committed on that path is exactly
 * what this checks.
 *
 *   usage: tausync <path> <size> <seed> <fsync|sync|syncfs|sfr|none> [delay-us]
 *
 *     fsync   fsync(fd)                     - the known-good path
 *     sync    sync(2)                       - whole system
 *     syncfs  syncfs(fd)                    - this filesystem
 *     sfr     sync_file_range(WAIT_BEFORE|WRITE|WAIT_AFTER)
 *     none    nothing                       - negative control
 *
 * The barrier returns before this exits, so anything written here must survive
 * a power cut taken immediately afterwards.
 *
 * delay-us sleeps between the write and the barrier. That is what aims at the
 * background-commit race: with tau_max_commmit_age at 0 the journald daemon
 * sweeps the finished transaction into an async commit within ~10 ms, which
 * drops master->running_tau to zero while the commit is still in flight. A
 * sync(2) landing in that window must still wait for the commit to finish.
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
	const char *path, *how;
	size_t size;
	long delay_us;
	int seed, fd, rc = 0;
	char *buf;

	if (argc < 5) {
		fprintf(stderr,
			"usage: %s <path> <size> <seed> <fsync|sync|syncfs|sfr|none> [delay-us]\n",
			argv[0]);
		return 2;
	}
	path = argv[1];
	size = strtoul(argv[2], NULL, 0);
	seed = atoi(argv[3]);
	how = argv[4];
	delay_us = argc > 5 ? strtol(argv[5], NULL, 0) : 0;

	fd = open(path, O_CREAT | O_RDWR | O_TAU_UNTORN, 0644);
	if (fd < 0) { perror("open"); return 1; }
	buf = malloc(size);
	if (!buf) { fprintf(stderr, "out of memory\n"); return 1; }
	memset(buf, seed & 0xff, size);

	if (pwrite(fd, buf, size, 0) != (ssize_t)size) { perror("pwrite"); return 1; }

	if (delay_us > 0)
		usleep(delay_us);

	if (!strcmp(how, "fsync")) {
		rc = fsync(fd);
	} else if (!strcmp(how, "sync")) {
		sync();
	} else if (!strcmp(how, "syncfs")) {
		rc = syncfs(fd);
	} else if (!strcmp(how, "sfr")) {
		rc = sync_file_range(fd, 0, 0, SYNC_FILE_RANGE_WAIT_BEFORE |
					       SYNC_FILE_RANGE_WRITE |
					       SYNC_FILE_RANGE_WAIT_AFTER);
	} else if (strcmp(how, "none")) {
		fprintf(stderr, "unknown barrier %s\n", how);
		return 2;
	}
	if (rc) { perror(how); return 1; }

	printf("%s: %zu bytes of 0x%02x, barrier=%s, delay=%ldus\n",
	       path, size, seed & 0xff, how, delay_us);
	/* deliberately no close(): a close must not be what makes it durable */
	return 0;
}
