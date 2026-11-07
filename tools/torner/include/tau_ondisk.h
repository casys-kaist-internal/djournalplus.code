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
#define TAU_COMMIT_OFF_FLAGS		40	/* h_flags, TAU_COMMIT_F_* */
#define TAU_COMMIT_F_ISIZE		0x2	/* h_isize valid: the size gate */
#define TAU_COMMIT_OFF_SEC		48	/* static_assert'd at 48 */
#define TAU_COMMIT_OFF_NSEC		56

/* fs/taujournal/tau.h:192-199.  Revoke header: h_num_tags sits where the
 * descriptor keeps h_generation. */
#define TAU_REVOKE_OFF_NUM_TAGS		12
#define TAU_REVOKE_META_SIZE		32	/* sizeof(revoke_block_meta_t) */
#define TAU_REVOKE_TAG_SIZE		16	/* {t_scope be64, t_pblocknr be64} (#397) */
#define TAU_REVOKE_OFF_FLAGS		16	/* h_flags, be64 (tau.h:306) */
#define TAU_REVOKE_F_SCOPED		0x1	/* tags carry t_scope */
#define TAU_REVOKE_F_COND		0x2	/* tags hold only if the host freed the block */

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

/*
 * include/linux/tau_journal.h:51,80 (e6f2cdb2, kernel #397).  s_maxlen is the
 * journal file's length in blocks: the superblock and the segment map, so the
 * map has s_maxlen - 1 blocks (fs/taujournal/journal.c:1053, seg_map_nr = len
 * - 1).  The segment map log (from #382) is a segment of its own; mkfs leaves
 * these 0 and the kernel fills them at mount.
 */
#define TAU_SB_OFF_MAPLOG_PBA	0x60	/* s_maplog_pba, be64 */
#define TAU_SB_OFF_MAPLOG_BASE	0x68	/* s_maplog_base, be64: the map holds the log up to it */
#define TAU_SB_OFF_MAPLOG_LEN	0x70	/* s_maplog_len, be32 */

/*
 * The segment map log, include/linux/tau_journal.h:97-119 (#397).  A CLAIM
 * block lists the segments one commit enters; a FREE block lists segments
 * freed (e_ino 0) or given back to the host (e_pba 0 as well).  A FREE block
 * goes out PREFLUSH|FUA and is waited for before the segment is handed out
 * again (fs/taujournal/journal.c, __tau_maplog_free), so in the log every
 * write to a segment by its next owner comes after the FREE that ended the
 * previous ownership.
 */
#define TAU_MAPLOG_BLOCK	6	/* h_blocktype */
#define TAU_MAPLOG_CLAIM	1
#define TAU_MAPLOG_FREE		2
#define TAU_MAPLOG_OFF_SEQ	8	/* h_seq, be64 */
#define TAU_MAPLOG_OFF_JGEN	16	/* h_jgen, be32: the mount that wrote it */
#define TAU_MAPLOG_OFF_KIND	20	/* h_kind, be16 */
#define TAU_MAPLOG_OFF_NR	22	/* h_nr, be16 */
#define TAU_MAPLOG_HDR_SIZE	32	/* sizeof(struct tau_maplog_head) */
#define TAU_MAPLOG_ENT_SIZE	24	/* {e_index be32, e_pad, e_pba be64, e_ino be64} */
#define TAU_MAPLOG_ENT_MAX	((TAU_BLOCK_SIZE - TAU_MAPLOG_HDR_SIZE) / TAU_MAPLOG_ENT_SIZE)

/*
 * fs/taujournal/tau.h:240 (#397): a descriptor's last 8 bytes are the file's
 * serial in this mount; the commit keeps it at 96 (tau.h:298).  Together with
 * the inode number and the per-file sequence it names one transaction.
 */
#define TAU_DESC_SERIAL_FROM_END	8
#define TAU_COMMIT_OFF_SERIAL		96

/*
 * fs/taujournal/tau.h:276-277,284 (#397): with TAU_COMMIT_F_MAPLOG the record
 * names its claims on the segment map log by h_seq: blocks h_maplog ..
 * h_maplog + h_maplog_nr - 1.  They are written plain with the descriptors
 * and count only if the record does (fs/taujournal/journal.c,
 * tau_maplog_claim).
 */
#define TAU_COMMIT_OFF_JGEN		44	/* h_jgen, be32: the mount's journal generation */
#define TAU_COMMIT_OFF_TAIL_TID		60	/* h_tail_tid, be32 */
#define TAU_COMMIT_OFF_TAIL_BLK		64	/* h_tail_blk, be64 */
#define TAU_COMMIT_F_TAIL		0x1	/* h_jgen / h_tail_* are valid */
#define TAU_COMMIT_OFF_MAPLOG		80	/* h_maplog, be64 */
#define TAU_COMMIT_OFF_MAPLOG_NR	88	/* h_maplog_nr, be32 */
#define TAU_COMMIT_F_MAPLOG		0x4

/* fs/taujournal/tau.h:327-329 (#397) */
#define TAU_TAG_NEW		0x10	/* converted by the host after the record */
#define TAU_TAG_HOME		0x20	/* written home: takes no journal block */

/*
 * The host journals whose commits gate a flush-less tau record.
 *
 * jbd2, include/linux/jbd2.h:112-135: a commit block is {h_magic, h_blocktype
 * 2, h_sequence}, the same magic and header as tau's.  tau-ext4's recovery
 * counts a record naming tid R iff tid_gt(j_commit_sequence, R), one past the
 * last committed tid (fs/ext4/super.c:5524): jbd2's commit block R is durable.
 *
 * XFS, fs/xfs/libxfs/xfs_log_format.h:26,163-168: a log record starts with
 * xlog_rec_header {h_magicno 0xFEEDbabe, h_cycle, h_version, h_len, h_lsn},
 * on a 512-byte boundary.  tau-xfs counts a record naming LSN R iff R is below
 * the recovered head (fs/xfs/xfs_log.c:3455): the log record at R is durable.
 */
#define JBD2_COMMIT_BLOCK_TYPE	2
#define XLOG_HEADER_MAGIC	0xFEEDBABEU
#define XLOG_OFF_CYCLE		4
#define XLOG_OFF_VERSION	8
#define XLOG_OFF_LEN		12
#define XLOG_OFF_LSN		16
#define XLOG_BBSIZE		512

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
