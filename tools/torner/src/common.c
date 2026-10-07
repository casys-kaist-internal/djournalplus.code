/* SPDX-License-Identifier: GPL-2.0
 *
 * Shared format helpers for torner gen / torner check.
 */
#include "torner.h"

#include <string.h>

static uint32_t crc_tab[256];
static int crc_ready;

void torner_crc32_init(void)
{
	uint32_t i, j, c;

	if (crc_ready)
		return;
	for (i = 0; i < 256; i++) {
		c = i;
		for (j = 0; j < 8; j++)
			c = (c & 1) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1);
		crc_tab[i] = c;
	}
	crc_ready = 1;
}

uint32_t torner_crc32(const void *buf, size_t len)
{
	const uint8_t *p = buf;
	uint32_t c = 0xFFFFFFFFU;

	while (len--)
		c = crc_tab[(c ^ *p++) & 0xFF] ^ (c >> 8);
	return c ^ 0xFFFFFFFFU;
}

static inline uint64_t splitmix64(uint64_t *s)
{
	uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);

	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
	z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
	return z ^ (z >> 31);
}

void torner_fill(uint64_t page_id, uint64_t version, uint32_t sector_idx,
		 uint64_t run_id, void *out, size_t len)
{
	uint64_t s = page_id * 0x9E3779B97F4A7C15ULL
		   ^ version * 0xC2B2AE3D27D4EB4FULL
		   ^ (uint64_t)sector_idx * 0x165667B19E3779F9ULL
		   ^ run_id * 0xD6E8FEB86659FD93ULL;
	uint8_t *p = out;
	size_t n = len;

	while (n >= 8) {
		uint64_t v = splitmix64(&s);

		memcpy(p, &v, 8);
		p += 8;
		n -= 8;
	}
	if (n) {
		uint64_t v = splitmix64(&s);

		memcpy(p, &v, n);
	}
}

const char *torner_mode_name(enum torner_mode m)
{
	switch (m) {
	case TORNER_MODE_OVERWRITE:	return "overwrite";
	case TORNER_MODE_APPEND:	return "append";
	case TORNER_MODE_ALLOC:		return "alloc";
	case TORNER_MODE_DELALLOC:	return "delalloc";
	case TORNER_MODE_MIXED:		return "mixed";
	default:			return "?";
	}
}

int torner_mode_parse(const char *s, enum torner_mode *out)
{
	enum torner_mode m;

	for (m = 0; m < TORNER_MODE__COUNT; m++) {
		if (!strcmp(s, torner_mode_name(m))) {
			*out = m;
			return 0;
		}
	}
	return -1;
}

const char *torner_sec_status_name(enum torner_sec_status s)
{
	switch (s) {
	case TORNER_SEC_OK:		return "ok";
	case TORNER_SEC_BAD_MAGIC:	return "bad_magic";
	case TORNER_SEC_BAD_CRC:	return "bad_crc";
	case TORNER_SEC_BAD_GEOM:	return "bad_geometry";
	case TORNER_SEC_BAD_IDX:	return "bad_index";
	case TORNER_SEC_BAD_RUN:	return "stale_run";
	case TORNER_SEC_BAD_FILL:	return "bad_fill";
	default:			return "?";
	}
}

void torner_build_sector(void *sec, uint32_t sector_size,
			 uint64_t page_id, uint64_t version,
			 uint32_t sector_idx, uint32_t sectors_per_unit,
			 uint64_t seq, uint32_t tid, uint64_t run_id)
{
	struct torner_sector_hdr *h = sec;
	uint8_t *body = (uint8_t *)sec + sizeof(*h);

	memset(h, 0, sizeof(*h));
	h->magic = TORNER_SECTOR_MAGIC;
	h->page_id = page_id;
	h->version = version;
	h->seq = seq;
	h->tid = tid;
	h->sector_idx = sector_idx;
	h->sectors_per_unit = sectors_per_unit;
	h->sector_size = sector_size;
	h->run_id = run_id;
	h->crc32 = 0;

	torner_fill(page_id, version, sector_idx, run_id, body,
		    sector_size - sizeof(*h));

	h->crc32 = torner_crc32(sec, sector_size);
}

enum torner_sec_status torner_verify_sector(const void *sec, uint32_t sector_size,
					    uint64_t page_id, uint32_t sector_idx,
					    uint64_t run_id,
					    struct torner_sector_hdr *out)
{
	struct torner_sector_hdr h;
	uint8_t scratch[TORNER_DEF_SECTOR];
	const uint8_t *body = (const uint8_t *)sec + sizeof(h);
	size_t bodylen = sector_size - sizeof(h);

	if (sector_size < sizeof(h) || sector_size > sizeof(scratch))
		return TORNER_SEC_BAD_GEOM;

	memcpy(&h, sec, sizeof(h));

	if (h.magic != TORNER_SECTOR_MAGIC)
		return TORNER_SEC_BAD_MAGIC;
	if (h.sector_size != sector_size ||
	    h.sectors_per_unit == 0 ||
	    h.sectors_per_unit > TORNER_MAX_SECTORS_PER_UNIT)
		return TORNER_SEC_BAD_GEOM;

	/*
	 * crc first: a bad crc means the sector itself is damaged, which is a
	 * different (and more alarming) finding than two intact sectors
	 * disagreeing on version.  Rebuild the image with crc32 = 0 and hash
	 * it in one call rather than streaming across two ranges.
	 */
	memcpy(scratch, sec, sector_size);
	((struct torner_sector_hdr *)scratch)->crc32 = 0;
	if (torner_crc32(scratch, sector_size) != h.crc32)
		return TORNER_SEC_BAD_CRC;

	if (run_id && h.run_id != run_id)
		return TORNER_SEC_BAD_RUN;
	if (h.page_id != page_id || h.sector_idx != sector_idx)
		return TORNER_SEC_BAD_IDX;

	/* Body must match the version the header claims. */
	torner_fill(h.page_id, h.version, h.sector_idx, h.run_id,
		    scratch, bodylen);
	if (memcmp(scratch, body, bodylen))
		return TORNER_SEC_BAD_FILL;

	if (out)
		*out = h;
	return TORNER_SEC_OK;
}

void torner_build_prog(struct torner_prog_rec *r, uint64_t page_id,
		       uint64_t version, uint64_t seq, uint64_t run_id,
		       uint32_t tid)
{
	memset(r, 0, sizeof(*r));
	r->magic = TORNER_PROG_MAGIC;
	r->page_id = page_id;
	r->version = version;
	r->seq = seq;
	r->run_id = run_id;
	r->tid = tid;
	r->crc32 = 0;
	r->crc32 = torner_crc32(r, sizeof(*r));
}

int torner_verify_prog(const struct torner_prog_rec *r, uint64_t run_id)
{
	struct torner_prog_rec c;
	uint32_t want;

	if (r->magic != TORNER_PROG_MAGIC)
		return -1;
	c = *r;
	want = c.crc32;
	c.crc32 = 0;
	if (torner_crc32(&c, sizeof(c)) != want)
		return -1;
	if (run_id && r->run_id != run_id)
		return -1;
	return 0;
}
