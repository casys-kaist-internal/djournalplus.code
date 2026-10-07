/* SPDX-License-Identifier: GPL-2.0
 *
 * Torner -- crash-atomicity test suite for tauJournal.
 *
 * On-disk formats shared by `torner gen` (writer) and `torner check` (oracle).
 *
 * The whole point of these formats is that a recovered file can be judged on
 * its own, with no golden image to diff against.  Every sector says which
 * atomic unit it belongs to and which version of that unit it holds, so P1
 * (atomicity) reduces to "do the sectors of one unit agree on a version?".
 * That is what lets the workload run 32 threads concurrently -- a diff-based
 * oracle would need a deterministic single-threaded workload to compare to.
 */
#ifndef TORNER_H
#define TORNER_H

#include <stdint.h>
#include <stddef.h>

/* "TORNSEC1" / "TORNPRG1", little-endian on disk. */
#define TORNER_SECTOR_MAGIC	0x3143455344524f54ULL
#define TORNER_PROG_MAGIC	0x3147525044524f54ULL

#define TORNER_DEF_UNIT		16384	/* application atomic unit */
#define TORNER_DEF_SECTOR	4096	/* sector of that unit */
#define TORNER_PROG_RECSZ	512	/* one progress record = one device sector */

#define TORNER_MAX_SECTORS_PER_UNIT	64

/*
 * Header at the front of every sector of an atomic unit.  Exactly 64 bytes;
 * the rest of the sector is a deterministic fill derived from
 * (page_id, version, sector_idx) -- see torner_fill().
 *
 * Carrying the fill as well as the version matters: a header sector that
 * picked up the new version while its body stayed old is a sub-sector tear,
 * and version comparison alone would call that unit clean.
 */
struct torner_sector_hdr {
	uint64_t magic;
	uint64_t page_id;		/* atomic unit index within the file */
	uint64_t version;		/* 1-based, monotonic per page_id */
	uint64_t seq;			/* global write sequence, for debugging */
	uint32_t tid;			/* writer thread that produced it */
	uint32_t sector_idx;		/* 0 .. sectors_per_unit-1 */
	uint32_t sectors_per_unit;
	uint32_t sector_size;
	uint32_t crc32;			/* over the whole sector, this field = 0 */
	uint32_t pad;
	uint64_t run_id;		/* distinguishes a stale previous run */
};

/*
 * One entry in the progress log, appended after fsync() returns.  Padded to a
 * full device sector so each record lands atomically on the media.
 *
 * The progress log is a *lower bound* on what is durable: crashing between
 * fsync() returning and this append losing the record is fine.  The violation
 * direction is one-way -- the log claiming a version the file does not have.
 */
struct torner_prog_rec {
	uint64_t magic;
	uint64_t page_id;
	uint64_t version;
	uint64_t seq;
	uint64_t run_id;
	uint32_t tid;
	uint32_t crc32;			/* over the whole record, this field = 0 */
	uint8_t  pad[TORNER_PROG_RECSZ - 48];
};

enum torner_mode {
	TORNER_MODE_OVERWRITE = 0,	/* written extents, pure in-place rewrite */
	TORNER_MODE_APPEND,		/* i_size growth            (Data-Inode) */
	TORNER_MODE_ALLOC,		/* fallocate'd, unwritten->written conversion */
	TORNER_MODE_DELALLOC,		/* sparse, delayed allocation at writeback */
	TORNER_MODE_MIXED,
	TORNER_MODE__COUNT
};

const char *torner_mode_name(enum torner_mode m);
int torner_mode_parse(const char *s, enum torner_mode *out);

/* crc32 (IEEE 802.3, reflected, poly 0xEDB88320) */
void     torner_crc32_init(void);
uint32_t torner_crc32(const void *buf, size_t len);

/*
 * Deterministic body fill for one sector.  `out` receives
 * (sector_size - sizeof(struct torner_sector_hdr)) bytes.
 */
void torner_fill(uint64_t page_id, uint64_t version, uint32_t sector_idx,
		 uint64_t run_id, void *out, size_t len);

/* Build a complete sector (header + fill + crc) into `sec`. */
void torner_build_sector(void *sec, uint32_t sector_size,
			 uint64_t page_id, uint64_t version,
			 uint32_t sector_idx, uint32_t sectors_per_unit,
			 uint64_t seq, uint32_t tid, uint64_t run_id);

enum torner_sec_status {
	TORNER_SEC_OK = 0,
	TORNER_SEC_BAD_MAGIC,
	TORNER_SEC_BAD_CRC,
	TORNER_SEC_BAD_GEOM,	/* sector_size / sectors_per_unit disagree */
	TORNER_SEC_BAD_IDX,	/* sector_idx or page_id not where it should be */
	TORNER_SEC_BAD_RUN,	/* belongs to a different run_id */
	TORNER_SEC_BAD_FILL	/* header consistent but body is another version */
};

const char *torner_sec_status_name(enum torner_sec_status s);

/*
 * Validate one sector found at (page_id, sector_idx).  On TORNER_SEC_OK the
 * parsed header is copied to *hdr.  Pass run_id = 0 to skip the run check.
 */
enum torner_sec_status torner_verify_sector(const void *sec, uint32_t sector_size,
					    uint64_t page_id, uint32_t sector_idx,
					    uint64_t run_id,
					    struct torner_sector_hdr *hdr);

void torner_build_prog(struct torner_prog_rec *r, uint64_t page_id,
		       uint64_t version, uint64_t seq, uint64_t run_id,
		       uint32_t tid);
int  torner_verify_prog(const struct torner_prog_rec *r, uint64_t run_id);

/* subcommands */
int torner_gen(int argc, char **argv);
int torner_check(int argc, char **argv);

#endif /* TORNER_H */
