/* SPDX-License-Identifier: GPL-2.0
 *
 * tauJournal on-disk constants, transcribed from the kernel source.
 *
 * CRASH_TODO §9 forbids copying these from prose or guessing them, so every
 * value below cites the file it came from.  When the kernel changes, re-derive
 * -- do not patch by inspection.
 *
 *   include/linux/tau_journal.h   magic, block types, geometry, superblock,
 *                                 segment map, block/revoke tags
 *   fs/taujournal/tau.h           descriptor/commit/revoke headers, tag flags
 *   fs/taujournal/commit.c        tag placement (tags start at sizeof(hdr))
 *   fs/taujournal/recovery.c      how recovery walks a transaction
 *
 * Everything on disk is big-endian.
 */
#ifndef TAU_ONDISK_H
#define TAU_ONDISK_H

#include <stdint.h>

/* include/linux/tau_journal.h:8-11 */
#define TAU_MAGIC_NUMBER	0xc03b3998U
#define TAU_DESCRIPTOR_BLOCK	1
#define TAU_COMMIT_BLOCK	2
#define TAU_REVOKE_BLOCK	3

/*
 * The tau superblock reuses jbd2's SUPERBLOCK_V2 type number -- observed as 4
 * on a real capture, at the LBA that fs/taujournal/journal.c:657 calls
 * j_blk_offset.  It is only a disambiguator here, never trusted on its own.
 */
#define TAU_SUPERBLOCK_BLOCKTYPE	4

/* include/linux/tau_journal.h:13,24-26 */
#define TAU_BLOCK_SIZE			4096
#define TAU_SEGMENT_SIZE_DEFAULT	(128ULL * 1024 * 1024)

/* include/linux/tau_journal.h:68 -- 4096 / sizeof(struct tau_segent) */
#define TAU_SEGMENT_ENT_MAX		(TAU_BLOCK_SIZE / 16)

/* s_segment_size is a __be32, so the kernel's u64 bounds are clamped here. */
#define TAU_SEGMENT_SIZE_MIN_U32	(1u * 1024 * 1024)
#define TAU_SEGMENT_SIZE_MAX_U32	(1024u * 1024 * 1024)

/*
 * How far past the superblock to look for segment-map blocks.  The real count
 * is seg_map_nr = DIV_ROUND_UP(segments, TAU_SEGMENT_ENT_MAX), which is not
 * recorded on disk; 64 map blocks addresses 16384 segments (2 TB at the 128 MB
 * default), far beyond any journal this suite formats.
 */
#define TAU_SEGMAP_SCAN_MAX		64

/* fs/taujournal/tau.h:204-208 */
#define TAU_TAG_ESCAPE		1
#define TAU_TAG_SAME_UUID	2
#define TAU_TAG_LAST		8

/*
 * NOTE: jbd2 uses this same magic (0xc03b3998) -- tau inherited it.  Block
 * type numbering also overlaps: jbd2 1=descriptor, 2=commit, 3=superblock_v1,
 * whereas tau 3=revoke.  A block cannot be attributed to one journal or the
 * other by magic alone; the dialect has to come from --config.
 */

/*
 * fs/taujournal/tau.h:161-168.  Descriptor header; tags follow immediately at
 * offset sizeof(tau_header_t) == 32 (fs/taujournal/commit.c:595).
 */
#define TAU_HDR_OFF_MAGIC		0
#define TAU_HDR_OFF_BLOCKTYPE		4
#define TAU_HDR_OFF_SEQUENCE		8
#define TAU_HDR_OFF_GENERATION		12
#define TAU_HDR_OFF_INODE_NUMBER	16
#define TAU_HDR_OFF_NEXT_SEGMENT	24	/* static_assert'd at 24 */
#define TAU_HDR_SIZE			32

/* fs/taujournal/tau.h:170-190.  Commit header shares the prefix above. */
#define TAU_COMMIT_OFF_EPOCH		32	/* static_assert'd at 32 */
#define TAU_COMMIT_OFF_SEC		48	/* static_assert'd at 48 */
#define TAU_COMMIT_OFF_NSEC		56

/* fs/taujournal/tau.h:192-199.  Revoke header: h_num_tags sits where the
 * descriptor keeps h_generation. */
#define TAU_REVOKE_OFF_NUM_TAGS		12
#define TAU_REVOKE_META_SIZE		32	/* sizeof(revoke_block_meta_t) */
#define TAU_REVOKE_TAG_SIZE		16	/* {t_lblocknr be64, t_pblocknr be64} */

/*
 * include/linux/tau_journal.h:75-79, __packed: {be32, be32, be16} == 10 bytes.
 * fs/taujournal/commit.c:319-320 splits the block number as
 *   t_blocknr      = block & 0xffffffff
 *   t_blocknr_high = (block >> 31) >> 1
 * so the physical block is (high << 32) | low.
 */
#define TAU_TAG_SIZE		10
#define TAU_TAG_OFF_BLOCKNR	0
#define TAU_TAG_OFF_HIGH	4
#define TAU_TAG_OFF_FLAGS	8

/*
 * include/linux/tau_journal.h:35-64.  Superblock lives at journal block 0
 * (master->j_blk_offset; fs/taujournal/journal.c:657).
 *
 * Offsets walked out field by field; the struct ends at 0x400, which is what
 * the trailing comment in the kernel header asserts, so the walk is anchored
 * at both ends.
 */
#define TAU_SB_OFF_BLOCKSIZE	12
#define TAU_SB_OFF_MAXLEN	16
#define TAU_SB_OFF_FIRST	20
#define TAU_SB_OFF_SEQUENCE	24
#define TAU_SB_OFF_START	28
#define TAU_SB_OFF_SEGMENT_SIZE	92	/* s_segment_size */
#define TAU_SB_SIZE		1024

static inline uint32_t be32_at(const uint8_t *p, size_t off)
{
	return ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16) |
	       ((uint32_t)p[off + 2] << 8) | (uint32_t)p[off + 3];
}

static inline uint64_t be64_at(const uint8_t *p, size_t off)
{
	return ((uint64_t)be32_at(p, off) << 32) | be32_at(p, off + 4);
}

static inline uint16_t be16_at(const uint8_t *p, size_t off)
{
	return (uint16_t)(((uint16_t)p[off] << 8) | p[off + 1]);
}

/* Is this 4 KiB block a tau (or jbd2 -- same magic) journal metadata block? */
static inline int tau_is_journal_block(const uint8_t *b, uint32_t *blocktype)
{
	if (be32_at(b, TAU_HDR_OFF_MAGIC) != TAU_MAGIC_NUMBER)
		return 0;
	if (blocktype)
		*blocktype = be32_at(b, TAU_HDR_OFF_BLOCKTYPE);
	return 1;
}

#endif /* TAU_ONDISK_H */
