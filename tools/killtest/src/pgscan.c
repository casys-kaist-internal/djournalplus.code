// SPDX-License-Identifier: GPL-2.0
//
// pgscan -- killtest's PostgreSQL page scan of a data directory as the crash
// left it, before recovery touches it.  pg_checksums --check does the same
// but refuses a cluster that was not shut down cleanly, so this is its
// check (skipped files, block numbering, new pages), built on PostgreSQL's
// own checksum code (storage/checksum_impl.h).  A page whose checksum does
// not match was written in part: with full_page_writes off nothing else
// leaves one on disk.
//
//   pgscan PGDATA
//
// prints "BAD file=... block=..." for every such page and "SHORT ..." for a
// file that ends inside a block, then a "files=... blocks=... bad_pages=...
// short=... errors=..." line.  Exit status 0 when there is neither.
//
// Built against the source tree's headers (bench/postgresql/src/include),
// with nothing of PostgreSQL's to link.

#include "postgres_fe.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "common/file_utils.h"
#include "storage/bufpage.h"
#include "storage/checksum.h"
#include "storage/checksum_impl.h"

// port.h points these at libpgport's versions; the C library's will do
#undef printf
#undef fprintf
#undef snprintf
#undef strerror

static long files, blocks, bad, shortfiles, errors;

// pg_checksums' skip list
static bool skipfile(const char *fn)
{
	static const char *const skip[] = { "pg_control", "pg_filenode.map",
					    "PG_VERSION", NULL };
	int i;

	if (strncmp(fn, "pg_internal.init", 16) == 0)
		return true;
	for (i = 0; skip[i]; i++)
		if (strcmp(fn, skip[i]) == 0)
			return true;
	return false;
}

static void scan_file(const char *path, const char *rel, int segno)
{
	PGIOAlignedBlock buf;
	PageHeader header = (PageHeader) buf.data;
	BlockNumber blkno;
	int f = open(path, O_RDONLY);

	if (f < 0) {
		printf("ERROR open %s: %s\n", rel, strerror(errno));
		errors++;
		return;
	}
	files++;
	for (blkno = 0;; blkno++) {
		ssize_t r = read(f, buf.data, BLCKSZ);
		uint16 csum;

		if (r == 0)
			break;
		if (r < 0) {
			printf("ERROR read %s block %u: %s\n", rel, blkno,
			       strerror(errno));
			errors++;
			break;
		}
		if (r != BLCKSZ) {
			printf("SHORT file=%s block=%u bytes=%zd\n", rel, blkno, r);
			shortfiles++;
			break;
		}
		blocks++;
		// new pages have no checksum yet
		if (PageIsNew(buf.data))
			continue;
		csum = pg_checksum_page(buf.data, blkno + segno * RELSEG_SIZE);
		if (csum != header->pd_checksum) {
			bad++;
			printf("BAD file=%s block=%u calculated=%04X stored=%04X"
			       " lsn=%X/%X\n", rel, blkno, csum, header->pd_checksum,
			       header->pd_lsn.xlogid, header->pd_lsn.xrecoff);
		}
	}
	close(f);
}

// global/ and base/<db>/ hold the relation files: <filenode>[_<fork>][.<seg>]
static void scan_dir(const char *datadir, const char *sub, int depth)
{
	char path[MAXPGPATH], fn[MAXPGPATH], rel[MAXPGPATH];
	struct dirent *de;
	struct stat st;
	DIR *dir;

	snprintf(path, sizeof(path), "%s/%s", datadir, sub);
	if (!(dir = opendir(path))) {
		printf("ERROR opendir %s: %s\n", sub, strerror(errno));
		errors++;
		return;
	}
	while ((de = readdir(dir)) != NULL) {
		const char *dot;

		if (de->d_name[0] == '.' ||
		    strncmp(de->d_name, PG_TEMP_FILE_PREFIX,
			    strlen(PG_TEMP_FILE_PREFIX)) == 0)
			continue;
		snprintf(fn, sizeof(fn), "%s/%s", path, de->d_name);
		snprintf(rel, sizeof(rel), "%s/%s", sub, de->d_name);
		if (lstat(fn, &st) < 0)
			continue;
		if (S_ISDIR(st.st_mode) && depth > 0) {
			scan_dir(datadir, rel, depth - 1);
		} else if (S_ISREG(st.st_mode) && !skipfile(de->d_name)) {
			dot = strchr(de->d_name, '.');
			scan_file(fn, rel, dot ? atoi(dot + 1) : 0);
		}
	}
	closedir(dir);
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s PGDATA\n", argv[0]);
		return 2;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	scan_dir(argv[1], "global", 0);
	scan_dir(argv[1], "base", 1);
	printf("files=%ld blocks=%ld bad_pages=%ld short=%ld errors=%ld\n", files,
	       blocks, bad, shortfiles, errors);
	return bad || shortfiles || errors;
}
