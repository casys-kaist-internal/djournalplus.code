/* SPDX-License-Identifier: GPL-2.0
 *
 * torner check -- the P1/P2 oracle, and torner tear -- its self-test.
 *
 * P1 (atomicity): every sector of an atomic unit must agree on a version, and
 * each sector's body must match the version its header claims.  No golden
 * image is involved, which is what makes this usable against a 32-thread
 * workload.
 *
 * P2 (durability): the progress log records {page_id, version} only after
 * fsync() returned, so it is a lower bound.  A file version older than the
 * logged one is a violation; newer is not.
 */
#include "torner.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DEF_MAX_VIOL	64

enum page_state {
	PAGE_ABSENT = 0,	/* nothing written here yet -- legal */
	PAGE_INTACT,
	PAGE_TORN_VERSION,	/* sectors disagree on version */
	PAGE_TORN_PARTIAL,	/* some sectors present, some still blank */
	PAGE_CORRUPT		/* magic/crc/fill/index damage */
};

struct viol {
	const char *kind;
	uint64_t page_id;
	uint64_t v_lo, v_hi;
	uint64_t want, got;
	const char *detail;
};

static int read_all(int fd, void *buf, size_t len, off_t off)
{
	uint8_t *p = buf;
	size_t done = 0;

	while (done < len) {
		ssize_t n = pread(fd, p + done, len - done, off + done);

		if (n < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (n == 0)
			break;		/* short: EOF */
		done += n;
	}
	return (int)done;
}

static int is_blank(const void *buf, size_t len)
{
	const uint8_t *p = buf;
	size_t i;

	for (i = 0; i < len; i++)
		if (p[i])
			return 0;
	return 1;
}

/*
 * Classify one atomic unit.  On PAGE_INTACT *ver receives its version.
 */
static enum page_state classify(const uint8_t *unit, uint32_t sector,
				uint32_t spu, uint64_t page_id, uint64_t run_id,
				uint64_t *ver, uint64_t *v_lo, uint64_t *v_hi,
				const char **detail)
{
	uint32_t s, n_ok = 0, n_blank = 0;
	uint64_t lo = UINT64_MAX, hi = 0;
	enum torner_sec_status bad = TORNER_SEC_OK;

	for (s = 0; s < spu; s++) {
		const uint8_t *sec = unit + (size_t)s * sector;
		struct torner_sector_hdr h;
		enum torner_sec_status st;

		if (is_blank(sec, sector)) {
			n_blank++;
			continue;
		}
		st = torner_verify_sector(sec, sector, page_id, s, run_id, &h);
		if (st != TORNER_SEC_OK) {
			if (bad == TORNER_SEC_OK)
				bad = st;
			continue;
		}
		n_ok++;
		if (h.version < lo)
			lo = h.version;
		if (h.version > hi)
			hi = h.version;
	}

	*v_lo = (lo == UINT64_MAX) ? 0 : lo;
	*v_hi = hi;

	if (bad != TORNER_SEC_OK) {
		*detail = torner_sec_status_name(bad);
		return PAGE_CORRUPT;
	}
	if (n_blank == spu)
		return PAGE_ABSENT;
	if (n_blank)
		return PAGE_TORN_PARTIAL;
	if (lo != hi)
		return PAGE_TORN_VERSION;
	*ver = hi;
	return PAGE_INTACT;
}

static const char *jstr(const char *s)
{
	return s ? s : "";
}

/*
 * Per-target verdicts.  A state from `replay --strategy atom-*` is aimed at
 * particular application writes; the global P1 flag cannot say whether THOSE
 * tore, because other writes in flight at the same crash point may tear too.
 * Each target (page, version) is judged on its own:
 *
 *   new     the page is whole at this version or later
 *   old     the page is whole at an earlier version -- the write rolled back
 *   absent  nothing of the page is on disk (write-once modes, before the write)
 *   torn    sectors disagree, a sector is missing, or a sector is damaged
 */
struct focus {
	uint64_t page;
	uint64_t version;
};

static size_t read_focus(const char *path, struct focus **out)
{
	FILE *f = fopen(path, "r");
	struct focus *v = NULL;
	size_t n = 0, cap = 0;
	unsigned long long pg, ver;
	int got;

	if (!f) {
		fprintf(stderr, "torner check: open %s: %s\n", path, strerror(errno));
		return (size_t)-1;
	}
	while ((got = fscanf(f, "%llu %llu", &pg, &ver)) == 2) {
		if (n == cap) {
			cap = cap ? cap * 2 : 64;
			v = realloc(v, cap * sizeof(*v));
			if (!v) {
				fclose(f);
				return (size_t)-1;
			}
		}
		v[n].page = pg;
		v[n].version = ver;
		n++;
	}
	fclose(f);
	*out = v;
	return n;
}

static void report_focus(int fd, uint32_t unit, uint32_t sector, uint32_t spu,
			 uint64_t npages, uint64_t run_id,
			 const struct focus *fv, size_t fn)
{
	uint8_t *u = malloc(unit);
	uint64_t n_new = 0, n_old = 0, n_abs = 0;
	size_t i, shown = 0;

	printf(",\"focus\":{\"targets\":%zu,\"torn\":[", fn);
	for (i = 0; u && i < fn; i++) {
		uint64_t ver = 0, lo = 0, hi = 0;
		const char *detail = NULL;
		enum page_state st;

		if (fv[i].page >= npages) {
			n_abs++;
			continue;
		}
		if (read_all(fd, u, unit, (off_t)fv[i].page * unit) != (int)unit) {
			n_abs++;
			continue;
		}
		st = classify(u, sector, spu, fv[i].page, run_id, &ver, &lo, &hi,
			      &detail);
		switch (st) {
		case PAGE_INTACT:
			if (ver >= fv[i].version)
				n_new++;
			else
				n_old++;
			break;
		case PAGE_ABSENT:
			n_abs++;
			break;
		default:
			printf("%s{\"page\":%" PRIu64 ",\"version\":%" PRIu64
			       ",\"kind\":\"%s\",\"version_lo\":%" PRIu64
			       ",\"version_hi\":%" PRIu64 "%s%s%s}",
			       shown++ ? "," : "", fv[i].page, fv[i].version,
			       st == PAGE_TORN_VERSION ? "version_mismatch" :
			       st == PAGE_TORN_PARTIAL ? "partial_unit" : "sector_corrupt",
			       lo, hi, detail ? ",\"detail\":\"" : "",
			       detail ? detail : "", detail ? "\"" : "");
			break;
		}
	}
	printf("],\"new\":%" PRIu64 ",\"old\":%" PRIu64 ",\"absent\":%" PRIu64 "}",
	       n_new, n_old, n_abs);
	free(u);
}

static void usage(void)
{
	fprintf(stderr,
"usage: torner check --file <path> [options]\n"
"\n"
"  --file <path>           file to judge (after recovery)\n"
"  --progress-log <path>   progress log written by `torner gen` (P2)\n"
"  --unit <bytes>          application atomic unit          [16384]\n"
"  --sector <bytes>        sector within a unit             [4096]\n"
"  --run-id <u64>          reject sectors from other runs   [0 = any]\n"
"  --batch <n>             units read per I/O               [64]\n"
"  --max-violations <n>    cap the reported list            [64]\n"
"  --progress-limit <n>    only records below slot n are binding; take it\n"
"                          from `torner replay` progress_limit    [0 = all]\n"
"  --focus-file <path>     \"page version\" per line: judge these writes one by\n"
"                          one (new / old / absent / torn), uncapped\n"
"\n"
"  metadata passed straight through to the JSONL record (see CRASH_TODO 2.4):\n"
"  --tier --config --workload --run-tag --state-id --strategy --epoch\n"
"\n"
"exit: 0 = all checked properties pass, 2 = violation found, 1 = error\n");
}

int torner_check(int argc, char **argv)
{
	const char *path = NULL, *proglog = NULL;
	const char *tier = "", *config = "", *workload = "", *run_tag = "";
	const char *state_id = "", *strategy = "";
	long long epoch = -1;
	uint32_t unit = TORNER_DEF_UNIT, sector = TORNER_DEF_SECTOR, spu;
	uint64_t run_id = 0, batch = 64, max_viol = DEF_MAX_VIOL;
	uint64_t prog_limit = 0;	/* 0 = no bound */
	const char *focus_path = NULL;
	struct focus *fv = NULL;
	size_t fn = 0;
	uint64_t prog_considered = 0, prog_skipped = 0;
	uint64_t pages_seen = 0, pages_intact = 0, pages_absent = 0;
	uint64_t n_p1 = 0, n_p2 = 0, nviol = 0;
	uint64_t *filever = NULL;
	uint8_t *filestate = NULL;
	uint64_t npages = 0, p;
	struct viol *viols = NULL;
	int fd = -1, pfd = -1, i, rc = 1;
	int p1_pass = 1, p2_checked = 0, p2_pass = 1;
	uint8_t *buf = NULL;
	off_t fsize;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

#define NEEDV() do { if (!v) { usage(); return 1; } i++; } while (0)
		if (!strcmp(a, "--file"))              { NEEDV(); path = v; }
		else if (!strcmp(a, "--progress-log")) { NEEDV(); proglog = v; }
		else if (!strcmp(a, "--unit"))         { NEEDV(); unit = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--sector"))       { NEEDV(); sector = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--run-id"))       { NEEDV(); run_id = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--batch"))        { NEEDV(); batch = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--max-violations")) { NEEDV(); max_viol = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--progress-limit")) { NEEDV(); prog_limit = strtoull(v, NULL, 0); }
		else if (!strcmp(a, "--focus-file")) { NEEDV(); focus_path = v; }
		else if (!strcmp(a, "--tier"))         { NEEDV(); tier = v; }
		else if (!strcmp(a, "--config"))       { NEEDV(); config = v; }
		else if (!strcmp(a, "--workload"))     { NEEDV(); workload = v; }
		else if (!strcmp(a, "--run-tag"))      { NEEDV(); run_tag = v; }
		else if (!strcmp(a, "--state-id"))     { NEEDV(); state_id = v; }
		else if (!strcmp(a, "--strategy"))     { NEEDV(); strategy = v; }
		else if (!strcmp(a, "--epoch"))        { NEEDV(); epoch = strtoll(v, NULL, 0); }
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { usage(); return 0; }
		else {
			fprintf(stderr, "torner check: unknown option '%s'\n", a);
			usage();
			return 1;
		}
#undef NEEDV
	}

	if (!path) {
		fprintf(stderr, "torner check: --file is required\n");
		usage();
		return 1;
	}
	if (sector < sizeof(struct torner_sector_hdr) || sector > TORNER_DEF_SECTOR ||
	    !unit || unit % sector) {
		fprintf(stderr, "torner check: bad --unit/--sector geometry\n");
		return 1;
	}
	spu = unit / sector;
	if (!batch)
		batch = 1;

	torner_crc32_init();

	if (focus_path) {
		fn = read_focus(focus_path, &fv);
		if (fn == (size_t)-1)
			return 1;
	}

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "torner check: open %s: %s\n", path, strerror(errno));
		free(fv);
		return 1;
	}
	fsize = lseek(fd, 0, SEEK_END);
	if (fsize < 0) {
		fprintf(stderr, "torner check: lseek: %s\n", strerror(errno));
		goto out;
	}
	npages = (uint64_t)fsize / unit;	/* a trailing partial unit is itself torn */

	viols = calloc(max_viol ? max_viol : 1, sizeof(*viols));
	filever = calloc(npages ? npages : 1, sizeof(uint64_t));
	filestate = calloc(npages ? npages : 1, 1);
	buf = malloc((size_t)batch * unit);
	if (!viols || !filever || !filestate || !buf) {
		fprintf(stderr, "torner check: out of memory\n");
		goto out;
	}

	/* ---- P1 ---- */
	for (p = 0; p < npages; ) {
		uint64_t n = (npages - p < batch) ? (npages - p) : batch;
		int got = read_all(fd, buf, (size_t)n * unit, (off_t)p * unit);
		uint64_t k;

		if (got < 0) {
			fprintf(stderr, "torner check: read: %s\n", strerror(errno));
			goto out;
		}
		n = (uint64_t)got / unit;
		if (!n)
			break;

		for (k = 0; k < n; k++) {
			uint64_t pid = p + k;
			uint64_t ver = 0, lo = 0, hi = 0;
			const char *detail = NULL;
			enum page_state st;

			st = classify(buf + (size_t)k * unit, sector, spu, pid,
				      run_id, &ver, &lo, &hi, &detail);
			filestate[pid] = (uint8_t)st;
			pages_seen++;

			switch (st) {
			case PAGE_INTACT:
				filever[pid] = ver;
				pages_intact++;
				break;
			case PAGE_ABSENT:
				pages_absent++;
				break;
			default:
				p1_pass = 0;
				n_p1++;
				if (nviol < max_viol) {
					viols[nviol].kind =
						(st == PAGE_TORN_VERSION) ? "p1_version_mismatch" :
						(st == PAGE_TORN_PARTIAL) ? "p1_partial_unit" :
									    "p1_sector_corrupt";
					viols[nviol].page_id = pid;
					viols[nviol].v_lo = lo;
					viols[nviol].v_hi = hi;
					viols[nviol].detail = detail;
					nviol++;
				}
				break;
			}
		}
		p += n;
	}

	/* ---- P2 ---- */
	if (proglog) {
		struct torner_prog_rec r;
		off_t psize, off;

		pfd = open(proglog, O_RDONLY);
		if (pfd < 0) {
			fprintf(stderr, "torner check: open %s: %s\n",
				proglog, strerror(errno));
			goto out;
		}
		psize = lseek(pfd, 0, SEEK_END);
		if (psize < 0) {
			fprintf(stderr, "torner check: lseek log: %s\n", strerror(errno));
			goto out;
		}
		p2_checked = 1;

		/*
		 * Slots are claimed atomically but completed out of order, so
		 * the log has holes.  Scan every slot; records that fail
		 * verification are unwritten or lost, and losing a record is
		 * not a violation -- only the log outrunning the file is.
		 */
		for (off = 0; off + TORNER_PROG_RECSZ <= psize; off += TORNER_PROG_RECSZ) {
			/*
			 * A replayed state is only answerable for records that
			 * were already durable at the crash point.  The bound
			 * comes from the last progress mark in the replayed
			 * prefix (torner replay reports it as progress_limit).
			 * Without it the progress log, which lives outside the
			 * stack and survives whole, would make every write past
			 * the cut look like a lost durable write.
			 */
			if (prog_limit &&
			    (uint64_t)(off / TORNER_PROG_RECSZ) >= prog_limit) {
				prog_skipped++;
				continue;
			}
			if (read_all(pfd, &r, sizeof(r), off) != (int)sizeof(r))
				break;
			if (torner_verify_prog(&r, run_id))
				continue;
			prog_considered++;

			if (r.page_id >= npages ||
			    filestate[r.page_id] != PAGE_INTACT ||
			    filever[r.page_id] < r.version) {
				p2_pass = 0;
				n_p2++;
				if (nviol < max_viol) {
					viols[nviol].kind = "p2_lost_durable_write";
					viols[nviol].page_id = r.page_id;
					viols[nviol].want = r.version;
					viols[nviol].got =
						(r.page_id < npages) ? filever[r.page_id] : 0;
					viols[nviol].detail =
						(r.page_id >= npages) ? "beyond_eof" :
						(filestate[r.page_id] != PAGE_INTACT) ?
							"page_not_intact" : "stale_version";
					nviol++;
				}
			}
		}
	}

	/* ---- report (CRASH_TODO 2.4 schema) ---- */
	{
		/*
		 * The schema's run_id is a harness-chosen label; --run-id is the
		 * u64 stamped into the data.  Fall back to the latter so the
		 * field is never empty and always identifies the run.
		 */
		char tagbuf[32];

		if (!*run_tag) {
			snprintf(tagbuf, sizeof(tagbuf), "%" PRIu64, run_id);
			run_tag = tagbuf;
		}
		printf("{\"tier\":\"%s\",\"config\":\"%s\",\"workload\":\"%s\""
		       ",\"run_id\":\"%s\",\"state_id\":\"%s\",\"strategy\":\"%s\"",
		       jstr(tier), jstr(config), jstr(workload),
		       jstr(run_tag), jstr(state_id), jstr(strategy));
	}
	if (epoch >= 0)
		printf(",\"epoch\":%lld", epoch);
	printf(",\"oracle\":{\"p1\":\"%s\",\"p2\":\"%s\",\"p3\":\"n/a\",\"p4\":\"n/a\"}",
	       p1_pass ? "pass" : "fail",
	       !p2_checked ? "n/a" : (p2_pass ? "pass" : "fail"));
	printf(",\"stats\":{\"pages\":%" PRIu64 ",\"intact\":%" PRIu64
	       ",\"absent\":%" PRIu64 ",\"p1_violations\":%" PRIu64
	       ",\"p2_violations\":%" PRIu64
	       ",\"progress_considered\":%" PRIu64
	       ",\"progress_beyond_limit\":%" PRIu64
	       ",\"progress_limit\":%" PRIu64 "}",
	       pages_seen, pages_intact, pages_absent, n_p1, n_p2,
	       prog_considered, prog_skipped, prog_limit);

	printf(",\"violations\":[");
	for (p = 0; p < nviol; p++) {
		printf("%s{\"kind\":\"%s\",\"page_id\":%" PRIu64,
		       p ? "," : "", viols[p].kind, viols[p].page_id);
		if (viols[p].v_hi)
			printf(",\"version_lo\":%" PRIu64 ",\"version_hi\":%" PRIu64,
			       viols[p].v_lo, viols[p].v_hi);
		if (viols[p].want)
			printf(",\"want_version\":%" PRIu64 ",\"got_version\":%" PRIu64,
			       viols[p].want, viols[p].got);
		if (viols[p].detail)
			printf(",\"detail\":\"%s\"", viols[p].detail);
		printf("}");
	}
	printf("]");
	if (nviol < n_p1 + n_p2)
		printf(",\"violations_truncated\":%" PRIu64, n_p1 + n_p2 - nviol);
	if (focus_path)
		report_focus(fd, unit, sector, spu, npages, run_id, fv, fn);
	printf("}\n");

	rc = (p1_pass && p2_pass) ? 0 : 2;

out:
	free(fv);
	free(viols);
	free(filever);
	free(filestate);
	free(buf);
	if (fd >= 0)
		close(fd);
	if (pfd >= 0)
		close(pfd);
	return rc;
}

/*
 * torner tear -- deliberately damage one atomic unit.
 *
 * This exists for the same reason CRASH_TODO 3.7 demands a barrier-stripped
 * debug build: an oracle that has never been seen to fire is indistinguishable
 * from one that cannot fire.  Run gen, tear a page, and check must report it.
 */
static void tear_usage(void)
{
	fprintf(stderr,
"usage: torner tear --file <path> --page <id> [--sectors <n>] [--kind <k>]\n"
"\n"
"  --kind version   rewrite the first n sectors at version+1   [default]\n"
"  --kind blank     zero the first n sectors (partial unit)\n"
"  --kind bitflip   flip one bit in the first sector's body\n"
"  --sectors <n>    how many leading sectors to damage         [1]\n");
}

int torner_tear(int argc, char **argv)
{
	const char *path = NULL, *kind = "version";
	uint32_t unit = TORNER_DEF_UNIT, sector = TORNER_DEF_SECTOR, spu, n = 1, s;
	uint64_t page = 0;
	int fd = -1, i, rc = 1, have_page = 0;
	uint8_t *buf = NULL;
	struct torner_sector_hdr h;

	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;

#define NEEDV() do { if (!v) { tear_usage(); return 1; } i++; } while (0)
		if (!strcmp(a, "--file"))         { NEEDV(); path = v; }
		else if (!strcmp(a, "--page"))    { NEEDV(); page = strtoull(v, NULL, 0); have_page = 1; }
		else if (!strcmp(a, "--sectors")) { NEEDV(); n = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--kind"))    { NEEDV(); kind = v; }
		else if (!strcmp(a, "--unit"))    { NEEDV(); unit = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "--sector"))  { NEEDV(); sector = strtoul(v, NULL, 0); }
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) { tear_usage(); return 0; }
		else { tear_usage(); return 1; }
#undef NEEDV
	}
	if (!path || !have_page) {
		tear_usage();
		return 1;
	}
	if (!unit || unit % sector) {
		fprintf(stderr, "torner tear: bad geometry\n");
		return 1;
	}
	spu = unit / sector;
	if (!n || n > spu)
		n = 1;

	torner_crc32_init();

	fd = open(path, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "torner tear: open %s: %s\n", path, strerror(errno));
		return 1;
	}
	buf = malloc(unit);
	if (!buf)
		goto out;
	if (read_all(fd, buf, unit, (off_t)page * unit) != (int)unit) {
		fprintf(stderr, "torner tear: short read at page %" PRIu64 "\n", page);
		goto out;
	}
	memcpy(&h, buf, sizeof(h));
	if (h.magic != TORNER_SECTOR_MAGIC) {
		fprintf(stderr, "torner tear: page %" PRIu64 " has no torner sector\n",
			page);
		goto out;
	}

	for (s = 0; s < n; s++) {
		uint8_t *sec = buf + (size_t)s * sector;

		if (!strcmp(kind, "blank")) {
			memset(sec, 0, sector);
		} else if (!strcmp(kind, "bitflip")) {
			sec[sizeof(h) + 7] ^= 0x10;
		} else {
			torner_build_sector(sec, sector, page, h.version + 1, s,
					    spu, h.seq, h.tid, h.run_id);
		}
	}

	if (pwrite(fd, buf, unit, (off_t)page * unit) != (ssize_t)unit) {
		fprintf(stderr, "torner tear: write: %s\n", strerror(errno));
		goto out;
	}
	if (fsync(fd)) {
		fprintf(stderr, "torner tear: fsync: %s\n", strerror(errno));
		goto out;
	}
	printf("torn page %" PRIu64 ": %u leading sector(s), kind=%s\n", page, n, kind);
	rc = 0;
out:
	free(buf);
	if (fd >= 0)
		close(fd);
	return rc;
}
