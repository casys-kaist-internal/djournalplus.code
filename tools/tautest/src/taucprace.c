// SPDX-License-Identifier: GPL-2.0
/*
 * taucprace - build the exact state the checkpoint in-place flush relies on,
 * then sit in it so a power cut lands inside the window.
 *
 * tau_do_checkpoint() flushes a buffer that a still-uncommitted transaction
 * owns straight to its home block (checkpoint.c, the buffer_taudirty branch).
 * It marks the buffer VM-dirty WITHOUT the folio lock, so generic writeback
 * can tear that in-place copy too.  The code argues this is safe because the
 * older committed copy is still in the journal and this path does not stamp a
 * revoke, so recovery replays the old version over whatever tore.
 *
 * That argument ignores a revoke recorded EARLIER.  Build one:
 *
 *   gen A  write + fsync   -> journaled, then anchored
 *   gen B  write + fsync   -> rewrite of an anchored block: revoke recorded,
 *                             the in-place copy becomes authoritative
 *   gen C  write, NO fsync -> re-journaled into a transaction that never
 *                             commits; checkpoint may flush it in place
 *
 * Crash here. Recovery must not replay A (B's revoke says so), C was never
 * acked, so the file must read as all-B or all-C. Anything mixed means an
 * fsync-acked generation was torn - the guarantee tau exists to provide.
 *
 *   usage: taucprace <path> <size> <hold-seconds> [armed-marker]
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

#define GEN_A 0x41
#define GEN_B 0x42
#define GEN_C 0x43

static int write_gen(int fd, unsigned char *buf, size_t size, int byte, int sync)
{
	memset(buf, byte, size);
	if (pwrite(fd, buf, size, 0) != (ssize_t)size) {
		perror("pwrite");
		return -1;
	}
	if (sync && fsync(fd)) {
		perror("fsync");
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	unsigned char *buf;
	const char *path;
	size_t size;
	int fd, hold;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <path> <size> <hold-seconds>\n", argv[0]);
		return 2;
	}
	path = argv[1];
	size = strtoul(argv[2], NULL, 0);
	hold = atoi(argv[3]);

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

	if (write_gen(fd, buf, size, GEN_A, 1))	/* journaled, becomes anchored */
		return 1;
	if (write_gen(fd, buf, size, GEN_B, 1))	/* revoke recorded for these blocks */
		return 1;
	if (write_gen(fd, buf, size, GEN_C, 0))	/* re-journaled, never committed */
		return 1;

	/* Tell the host the state it wants to crash into actually exists. A
	 * fixed delay cannot do this: crash too early and the file is still
	 * zeroes, too late and C has already been committed by the background
	 * commit, so the rollback path never runs. Marker lives outside the
	 * test filesystem and is fsynced, so the power cut cannot eat it. */
	if (argc >= 5) {
		int m = open(argv[4], O_CREAT | O_WRONLY | O_TRUNC, 0644);

		if (m >= 0) {
			if (write(m, "armed\n", 6) != 6)
				perror("marker write");
			fsync(m);
			close(m);
		} else
			perror("marker open");
	}

	printf("CPRACE armed %s size=%zu (A=%#x B=%#x C=%#x)\n",
	       path, size, GEN_A, GEN_B, GEN_C);
	fflush(stdout);

	/* Stay alive and keep the page cache dirty so the checkpoint daemon has
	 * something to flush in place when the journal fills behind us. */
	sleep(hold);
	close(fd);
	return 0;
}
