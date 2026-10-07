// SPDX-License-Identifier: GPL-2.0
/*
 * pgscan - offline torn-page scan of PostgreSQL relation files.
 *
 * PostgreSQL only validates a page when it reads one, so a silently corrupted
 * page can sit on disk indefinitely -- the 2026-08-25 report surfaced only
 * because a query happened to touch block 748637.  This walks every page of
 * every relation instead, with the filesystem unmounted-and-remounted and no
 * crash involved, so anything it finds was lost in steady state.
 *
 * The signature it is built around is the one that was actually observed: an
 * 8 KiB page in which exactly one 4 KiB filesystem block is all zeroes and the
 * other holds real data.  PostgreSQL extends relations with fallocate() (see
 * mdzeroextend), so a block that never received its data reads as zeroes --
 * which makes "half zero, half data" the on-disk fingerprint of a lost 4 KiB
 * write, not of a half-old/half-new tear.
 *
 * A page that is entirely zero is NOT an error: that is just relation space
 * that was extended and not yet filled.
 *
 *   usage: pgscan [-q] <file-or-directory> ...
 *
 * Directories are walked recursively, skipping the names that are not heap or
 * index data (pg_wal, pg_xact, and the _fsm/_vm forks, which have their own
 * layouts).  Exit status is 1 if anything was found.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* PostgreSQL's own page checksum, lifted from src/include/storage/checksum_impl.h.
 * With data_checksums on, this catches damage the zero-half fingerprint cannot:
 * a page whose header survived and whose tuple area did not. */
#define N_SUMS		32
#define FNV_PRIME	16777619u

#define BLCKSZ		8192u
#define FSBLK		4096u
#define PAGEHDR		24u
#define LAYOUT_VERSION	4
#define MAX_REPORT	40

/* PageHeaderData, first 24 bytes of every heap/index page. */
struct pghdr {
	uint64_t pd_lsn;
	uint16_t pd_checksum;
	uint16_t pd_flags;
	uint16_t pd_lower;
	uint16_t pd_upper;
	uint16_t pd_special;
	uint16_t pd_pagesize_version;
	uint32_t pd_prune_xid;
};

static const uint32_t checksumBaseOffsets[N_SUMS] = {
	0x5B1F36E9, 0xB8525960, 0x02AB50AA, 0x1DE66D2A,
	0x79FF467A, 0x9BB9F8A3, 0x217E7CD2, 0x83E13D2C,
	0xF8D4474F, 0xE39EB970, 0x42C6AE16, 0x993216FA,
	0x7B093B5D, 0x98DAFF3C, 0xF718902A, 0x0B1C9CDB,
	0xE58F764B, 0x187636BC, 0x5D7B3BB1, 0xE73DE7DE,
	0x92BEC979, 0xCCA6C0B2, 0x304A0979, 0x85AA43D4,
	0x783125BB, 0x6CA8EAA2, 0xE407EAC6, 0x4B5CFC3E,
	0x9FBF8C76, 0x15CA20BE, 0xF2CA9FD3, 0x959BD756
};

#define CHECKSUM_COMP(checksum, value) \
do { \
	uint32_t __tmp = (checksum) ^ (value); \
	(checksum) = __tmp * FNV_PRIME ^ (__tmp >> 17); \
} while (0)

static uint16_t pg_checksum_page(const unsigned char *page, uint32_t blkno)
{
	union {
		unsigned char bytes[BLCKSZ];
		uint32_t data[BLCKSZ / (sizeof(uint32_t) * N_SUMS)][N_SUMS];
	} cp;
	uint32_t sums[N_SUMS];
	uint32_t result = 0, i, j;

	memcpy(cp.bytes, page, BLCKSZ);
	cp.bytes[8] = 0;		/* pd_checksum is excluded from its own sum */
	cp.bytes[9] = 0;

	memcpy(sums, checksumBaseOffsets, sizeof(checksumBaseOffsets));
	for (i = 0; i < BLCKSZ / (sizeof(uint32_t) * N_SUMS); i++)
		for (j = 0; j < N_SUMS; j++)
			CHECKSUM_COMP(sums[j], cp.data[i][j]);
	for (i = 0; i < 2; i++)
		for (j = 0; j < N_SUMS; j++)
			CHECKSUM_COMP(sums[j], 0);
	for (i = 0; i < N_SUMS; i++)
		result ^= sums[i];

	result ^= blkno;
	return (uint16_t)((result % 65535) + 1);
}

static int quiet;
static unsigned long tot_files, tot_pages, tot_allzero;
static unsigned long tot_torn, tot_badhdr;
static unsigned long tot_csum_ok, tot_csum_bad, tot_csum_off, tot_csum_skip;
static int reported;

static int all_zero(const unsigned char *p, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++)
		if (p[i])
			return 0;
	return 1;
}

/* Returns non-zero if the header cannot describe a real page. */
static int bad_header(const unsigned char *page)
{
	struct pghdr h;
	unsigned ver;

	memcpy(&h, page, sizeof(h));
	ver = h.pd_pagesize_version;
	if ((ver & 0xff00) != (BLCKSZ & 0xff00))
		return 1;
	if ((ver & 0x00ff) != LAYOUT_VERSION)
		return 1;
	if (h.pd_lower < PAGEHDR || h.pd_lower > h.pd_upper ||
	    h.pd_upper > h.pd_special || h.pd_special > BLCKSZ)
		return 1;
	return 0;
}

/* A relation segment: <relfilenode>[.<n>].  Forks (_fsm, _vm) and everything
 * outside base/ are skipped by the caller. */
static void scan_file(const char *path)
{
	unsigned char page[BLCKSZ];
	unsigned long pages = 0, allzero = 0, torn = 0, badhdr = 0;
	unsigned long csum_ok = 0, csum_bad = 0, csum_off = 0;
	unsigned long first_torn = 0;
	const char *first_half = "";
	const char *base = strrchr(path, '/');
	int fd, printed_any = 0, seg0;
	ssize_t n;

	base = base ? base + 1 : path;
	/* Only segment 0 can have its checksum verified here: for ".N" segments
	 * the block number folded into the checksum is N * RELSEG_SIZE + index,
	 * and RELSEG_SIZE is a build-time choice this tool cannot see. */
	seg0 = (strchr(base, '.') == NULL);

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
		return;
	}
	while ((n = read(fd, page, BLCKSZ)) > 0) {
		int z0, z1;

		if (n != (ssize_t)BLCKSZ) {
			fprintf(stderr, "%s: trailing %zd bytes at page %lu\n",
				path, n, pages);
			break;
		}
		z0 = all_zero(page, FSBLK);
		z1 = all_zero(page + FSBLK, FSBLK);

		if (z0 && z1) {
			allzero++;		/* extended, never filled */
		} else if (z0 || z1) {
			/* exactly one filesystem block is missing */
			if (!torn) {
				first_torn = pages;
				first_half = z0 ? "first" : "second";
			}
			torn++;
			if (reported++ < MAX_REPORT) {
				printf("  TORN    %s page %lu (offset %" PRIu64
				       ") %s half is zero\n",
				       path, pages, (uint64_t)pages * BLCKSZ,
				       z0 ? "first" : "second");
				printed_any = 1;
			}
		} else if (bad_header(page)) {
			badhdr++;
			if (reported++ < MAX_REPORT) {
				const struct pghdr *h = (const struct pghdr *)page;

				printf("  BADHDR  %s page %lu lower=%u upper=%u "
				       "special=%u ver=0x%04x\n",
				       path, pages, h->pd_lower, h->pd_upper,
				       h->pd_special, h->pd_pagesize_version);
				printed_any = 1;
			}
		} else {
			/* Header is sane; ask PostgreSQL's own checksum whether
			 * the rest of the page is. pd_checksum is 0 when the
			 * cluster was created without data_checksums. */
			struct pghdr h;

			memcpy(&h, page, sizeof(h));
			if (!h.pd_checksum) {
				csum_off++;
			} else if (!seg0) {
				/* counted globally, not per file */
			} else {
				uint16_t want = pg_checksum_page(page, (uint32_t)pages);

				if (want == h.pd_checksum) {
					csum_ok++;
				} else {
					csum_bad++;
					if (reported++ < MAX_REPORT) {
						printf("  CKSUM   %s page %lu (offset %" PRIu64
						       ") stored=0x%04x computed=0x%04x\n",
						       path, pages,
						       (uint64_t)pages * BLCKSZ,
						       h.pd_checksum, want);
						printed_any = 1;
					}
				}
			}
		}
		pages++;
	}
	close(fd);

	tot_files++;
	tot_pages += pages;
	tot_allzero += allzero;
	tot_torn += torn;
	tot_badhdr += badhdr;
	tot_csum_ok += csum_ok;
	tot_csum_bad += csum_bad;
	tot_csum_off += csum_off;
	if (!seg0)
		tot_csum_skip += pages;

	if (!quiet || torn || badhdr || csum_bad) {
		printf("%-16s pages=%-10lu allzero=%-8lu TORN=%-4lu BADHDR=%-4lu CKSUM_BAD=%lu",
		       base, pages, allzero, torn, badhdr, csum_bad);
		if (torn)
			printf("  [first at (%lu, '%s')]", first_torn, first_half);
		printf("\n");
	}
	(void)printed_any;
}

static int skip_name(const char *name)
{
	size_t len = strlen(name);

	if (!strcmp(name, ".") || !strcmp(name, ".."))
		return 1;
	/* Other forks have their own page layouts; only the main fork is what
	 * PostgreSQL opens with O_TAU_ATOMIC (md.c), so only it is journaled. */
	if (len > 4 && !strcmp(name + len - 4, "_fsm"))
		return 1;
	if (len > 3 && !strcmp(name + len - 3, "_vm"))
		return 1;
	if (len > 4 && !strcmp(name + len - 4, "_init"))
		return 1;
	if (!strcmp(name, "pg_wal") || !strcmp(name, "pg_xact") ||
	    !strcmp(name, "pg_subtrans") || !strcmp(name, "pg_multixact") ||
	    !strcmp(name, "pg_tblspc") || !strcmp(name, "pg_stat") ||
	    !strcmp(name, "pg_stat_tmp") || !strcmp(name, "pg_logical") ||
	    !strcmp(name, "pg_replslot") || !strcmp(name, "pg_notify") ||
	    !strcmp(name, "pg_serial") || !strcmp(name, "pg_snapshots") ||
	    !strcmp(name, "pg_twophase") || !strcmp(name, "pg_dynshmem"))
		return 1;
	return 0;
}

static void scan_path(const char *path, unsigned long minsize)
{
	struct stat st;

	if (lstat(path, &st)) {
		fprintf(stderr, "stat(%s): %s\n", path, strerror(errno));
		return;
	}
	if (S_ISDIR(st.st_mode)) {
		DIR *d = opendir(path);
		struct dirent *e;

		if (!d) {
			fprintf(stderr, "opendir(%s): %s\n", path, strerror(errno));
			return;
		}
		while ((e = readdir(d))) {
			char sub[4096];

			if (skip_name(e->d_name))
				continue;
			snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name);
			scan_path(sub, minsize);
		}
		closedir(d);
		return;
	}
	if (!S_ISREG(st.st_mode) || st.st_size == 0)
		return;
	if (st.st_size % BLCKSZ)
		return;			/* not a relation segment */
	if ((unsigned long)st.st_size < minsize)
		return;			/* catalogs and other small fry */
	scan_file(path);
}

int main(int argc, char **argv)
{
	/* Default floor keeps the system catalogs out of the listing; the
	 * interesting relations are the sysbench tables and their indexes. */
	unsigned long minsize = 16UL * 1024 * 1024;
	int i, first = 1;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-q")) {
			quiet = 1;
			continue;
		}
		if (!strcmp(argv[i], "-m") && i + 1 < argc) {
			minsize = strtoul(argv[++i], NULL, 0) * 1024 * 1024;
			continue;
		}
		first = 0;
		scan_path(argv[i], minsize);
	}
	if (first) {
		fprintf(stderr,
			"usage: %s [-q] [-m <min MiB>] <file-or-directory> ...\n",
			argv[0]);
		return 2;
	}

	printf("SCANNED %lu files, %lu pages (%.1f GiB), allzero=%lu\n",
	       tot_files, tot_pages,
	       (double)tot_pages * BLCKSZ / (1024.0 * 1024 * 1024), tot_allzero);
	printf("checksums: %lu verified, %lu BAD, %lu not enabled, %lu unverifiable (.N segments)\n",
	       tot_csum_ok, tot_csum_bad, tot_csum_off, tot_csum_skip);
	if (!tot_csum_ok && !tot_csum_bad)
		printf("  (no page checksums to check -- initdb without -k?)\n");
	printf("TOTAL TORN PAGES: %lu   BAD HEADERS: %lu   BAD CHECKSUMS: %lu\n",
	       tot_torn, tot_badhdr, tot_csum_bad);
	if (reported > MAX_REPORT)
		printf("(%d more not shown)\n", reported - MAX_REPORT);

	return (tot_torn || tot_badhdr || tot_csum_bad) ? 1 : 0;
}
